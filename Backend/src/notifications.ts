import {createPrivateKey, randomUUID, sign} from 'node:crypto';
import {connect} from 'node:http2';
import {Database, Timestamp} from './database';
import {digest} from './service';

export type NotificationPayload = {aps: {alert: {title: string; body: string}; sound: string}; pairId: string; pairEpoch: number}
  & ({noteId: string; type?: never; messageId?: never} | {type: 'message'; messageId: string; noteId?: never});
export interface PushTransport {
  app(token: string, payload: NotificationPayload, environment: 'development' | 'production'): Promise<void>;
  widget(token: string, environment: 'development' | 'production'): Promise<void>;
}
export type APNsConfiguration = {key: string; keyId: string; teamId: string; bundleId: string};
export class LivePushTransport implements PushTransport {
  constructor(readonly apns: () => APNsConfiguration | undefined) {}
  async app(token: string, payload: NotificationPayload, environment: 'development' | 'production'): Promise<void> {
    await this.send(token, 'alert', payload, environment, payload.noteId ?? digest(`message:${payload.messageId}`));
  }
  async widget(token: string, environment: 'development' | 'production'): Promise<void> {
    await this.send(token, 'widgets', {aps: {'content-changed': true}}, environment);
  }
  private async send(token: string, type: 'alert' | 'widgets', payload: object, environment: 'development' | 'production', collapseId?: string): Promise<void> {
    const config = this.apns();
    if (!config) throw new Error('apns_configuration_required');
    const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const unsigned = `${encode({alg: 'ES256', kid: config.keyId})}.${encode({iss: config.teamId, iat: Math.floor(Date.now() / 1000)})}`;
    const signature = sign('sha256', Buffer.from(unsigned), {key: createPrivateKey(config.key), dsaEncoding: 'ieee-p1363'}).toString('base64url');
    await new Promise<void>((resolve, reject) => {
      const connection = connect(environment === 'development' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com');
      let finished = false;
      const finish = (error?: Error) => {if (finished) return; finished = true; connection.destroy(); error ? reject(error) : resolve();};
      connection.on('error', error => finish(error));
      const request = connection.request({':method': 'POST', ':path': `/3/device/${token}`, authorization: `bearer ${unsigned}.${signature}`,
        'apns-push-type': type, 'apns-topic': `${config.bundleId}${type === 'widgets' ? '.push-type.widgets' : ''}`,
        'apns-expiration': '0', ...(collapseId ? {'apns-collapse-id': collapseId} : {})});
      request.setTimeout(15_000, () => finish(new Error('apns_timeout')));
      let status = 0;
      request.on('response', headers => {status = Number(headers[':status']);});
      request.on('data', () => {});
      request.on('error', error => finish(error));
      request.on('end', () => finish(status === 200 ? undefined : new Error(`apns_status_${status}`)));
      request.end(JSON.stringify(payload));
    });
  }
}

/** Leased outbox + per-channel acknowledgements. A crash after APNs accepted a message
 * and before SQL acknowledgement can duplicate it: delivery is at least once. */
export async function dispatchNotification(db: Database, eventId: string, transport: PushTransport): Promise<void> {
  const ref = db.doc(`notificationEvents/${eventId}`), now = Date.now(), leaseOwner = randomUUID();
  const event = await db.runTransaction(async tx => {
    const event = (await tx.get(ref)).data();
    if (!event || event.status === 'done' || event.status === 'cancelled' || event.nextAttemptAt.toMillis() > now) return null;
    const pair = (await tx.get(db.doc(`pairs/${event.pairId}`))).data();
    const note = (await tx.get(db.doc(event.type === 'message'
      ? `pairs/${event.pairId}/messages/${event.messageId}` : `pairs/${event.pairId}/notes/${event.noteId}`))).data();
    if (!pair || pair.status !== 'active' || pair.pairEpoch !== event.pairEpoch || !pair.members.includes(event.recipientId) || !note || note.recipientId !== event.recipientId) {
      tx.update(ref, {status: 'cancelled'}); return null;
    }
    tx.update(ref, {status: 'pending', leaseOwner, nextAttemptAt: Timestamp.fromMillis(now + 60_000), attempts: event.attempts + 1});
    return event;
  });
  if (!event) return;
  const updateIfOwned = async (values: Record<string, unknown>) => db.runTransaction(async tx => {
    if ((await tx.get(ref)).data()?.leaseOwner !== leaseOwner) throw new Error('notification_lease_lost');
    tx.update(ref, values);
  });
  try {
    const devices = await db.collection(`users/${event.recipientId}/devices`).where('active', '==', true).get();
    const payload: NotificationPayload = {aps: {alert: {title: 'PairNotes', body: event.type === 'message' ? 'Tenés un mensaje nuevo' : 'Tenés un dibujo nuevo'}, sound: 'default'},
      pairId: event.pairId, pairEpoch: event.pairEpoch,
      ...(event.type === 'message' ? {type: 'message' as const, messageId: event.messageId} : {noteId: event.noteId})};
    let failed = false;
    for (const device of devices.docs) {
      for (const channel of ['app', 'widget'] as const) {
        const field = channel === 'app' ? 'apnsToken' : 'widgetPushToken', value = device.data()![field];
        if (!value) continue;
        const delivery = ref.collection('deliveries').doc(digest(`${device.id}:${channel}:${value}`));
        if ((await delivery.get()).exists) continue;
        await updateIfOwned({nextAttemptAt: Timestamp.fromMillis(Date.now() + 60_000)});
        const [freshPair, freshDevice] = await Promise.all([db.doc(`pairs/${event.pairId}`).get(), device.ref.get()]);
        if (freshPair.data()?.status !== 'active' || freshPair.data()?.pairEpoch !== event.pairEpoch || !freshDevice.data()?.active || freshDevice.data()?.[field] !== value) continue;
        const environment = channel === 'widget' ? (freshDevice.data()!.widgetPushEnvironment ?? freshDevice.data()!.apnsEnvironment) : freshDevice.data()!.apnsEnvironment;
        if (!['development', 'production'].includes(environment)) {failed = true; continue;}
        try {
          if (channel === 'app') await transport.app(value, payload, environment); else await transport.widget(value, environment);
          await delivery.create({channel, sentAt: Timestamp.now()});
        } catch (error) {
          if ((error as Error).message === 'apns_status_410') {
            await db.runTransaction(async tx => {
              if ((await tx.get(device.ref)).data()?.[field] === value) tx.update(device.ref, {[field]: null});
            });
          } else failed = true;
        }
      }
    }
    if (failed) throw new Error('notification_channel_failed');
    await updateIfOwned({status: 'done', completedAt: Timestamp.now()});
  } catch (error) {
    await updateIfOwned({status: 'pending', nextAttemptAt: Timestamp.fromMillis(Date.now() + Math.min(3_600_000, 30_000 * 2 ** Math.min(event.attempts, 7)))});
    throw error;
  }
}
