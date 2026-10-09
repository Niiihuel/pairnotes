import {randomUUID} from 'node:crypto';
import {DocumentData, Timestamp, Transaction} from './database';
import {Caller, PairNotesService, digest, fail} from './service';

type Input = Record<string, unknown>;
const identifier = (value: unknown, name: string): string => {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value)) fail(`invalid_${name}`, 'invalid-argument');
  return value;
};
const photoID = (value: unknown): string => {
  const result = identifier(value, 'photo_id');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(result)) fail('invalid_photo_id', 'invalid-argument');
  return result.toLowerCase();
};
const scope = (input: Input) => {
  if (typeof input.pairEpoch !== 'number' || !Number.isSafeInteger(input.pairEpoch) || input.pairEpoch < 1) fail('invalid_pair_epoch', 'invalid-argument');
  return {pairId: identifier(input.pairId, 'pair_id'), pairEpoch: input.pairEpoch};
};
function publicReaction(value: DocumentData | undefined | null): DocumentData | null {
  return value ? {authorId: value.authorId, photoId: value.photoId, kind: value.kind, updatedAt: value.updatedAt.toMillis()} : null;
}
export function publicPhoto(value: DocumentData): DocumentData {
  return {id: value.id, authorId: value.authorId, recipientId: value.recipientId, caption: value.caption,
    photo: {id: value.photo.id, sha256: value.photo.sha256}, sentAt: value.sentAt.toMillis(), reaction: publicReaction(value.reaction)};
}

/** Direct photos have independent history; widgets can access only their latest received item. */
export class PhotoFeatures {
  constructor(readonly service: PairNotesService) {}
  get db() {return this.service.db;}

  async latest(tx: Transaction, uid: string, pair: DocumentData): Promise<DocumentData | null> {
    const view = (await tx.get(this.db.doc(`pairs/${pair.id}/views/${uid}`))).data();
    const value = view?.latestPhotoId ? (await tx.get(this.db.doc(`pairs/${pair.id}/photos/${view.latestPhotoId}`))).data() : null;
    return value?.recipientId === uid && value.pairEpoch === pair.pairEpoch ? publicPhoto(value) : null;
  }

  private async authorized(tx: Transaction, caller: Caller, input: Input): Promise<DocumentData> {
    const {pairId, pairEpoch} = scope(input), id = photoID(input.photoId);
    await this.service.pair(tx, caller.uid, pairId, pairEpoch);
    const value = (await tx.get(this.db.doc(`pairs/${pairId}/photos/${id}`))).data();
    if (!value || value.pairEpoch !== pairEpoch || ![value.authorId, value.recipientId].includes(caller.uid)) fail('photo_unavailable', 'not-found');
    if (input.assetId !== undefined && value.photo.id !== input.assetId) fail('photo_changed', 'aborted');
    return value;
  }

  async getPhoto(caller: Caller, input: Input): Promise<Input> {
    return this.db.runTransaction(async tx => ({photo: publicPhoto(await this.authorized(tx, caller, input))}));
  }

  async history(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), maximum = input.limit === undefined ? 30 : input.limit;
    if (typeof maximum !== 'number' || !Number.isSafeInteger(maximum) || maximum < 1 || maximum > 50) fail('invalid_limit', 'invalid-argument');
    let cursor: {sentAt: number; photoId: string} | undefined;
    if (input.cursor !== undefined && input.cursor !== null) {
      const value = input.cursor;
      if (typeof value !== 'object' || Array.isArray(value)) fail('invalid_cursor', 'invalid-argument');
      const {sentAt, photoId} = value as Input;
      if (typeof sentAt !== 'number' || !Number.isSafeInteger(sentAt) || sentAt < 1) fail('invalid_cursor_time', 'invalid-argument');
      cursor = {sentAt, photoId: photoID(photoId)};
    }
    await this.db.runTransaction(tx => this.service.pair(tx, caller.uid, pairId, pairEpoch));
    const rows = await this.db.photosPage(pairId, pairEpoch, maximum + 1, cursor);
    // Revocation while the query is in flight must not return old pair content.
    await this.db.runTransaction(tx => this.service.pair(tx, caller.uid, pairId, pairEpoch));
    const visible = rows.slice(0, maximum), last = visible.at(-1);
    return {photos: visible.map(publicPhoto), nextCursor: rows.length > maximum && last
      ? {sentAt: last.sentAt.toMillis(), photoId: last.id} : null};
  }

  async send(caller: Caller, input: Input, bytes: Buffer, contentType: string): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), id = photoID(input.photoId);
    if (typeof input.caption !== 'string' || input.caption.length > 500) fail('invalid_caption', 'invalid-argument');
    const caption = input.caption.trim(), sourceSHA256 = digest(bytes);
    const matches = (old: DocumentData) => {
      if (old.authorId !== caller.uid || old.caption !== caption || old.sourceSHA256 !== sourceSHA256) fail('idempotency_conflict', 'already-exists');
      return {photo: publicPhoto(old)};
    };
    const previous = await this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const old = (await tx.get(this.db.doc(`pairs/${pairId}/photos/${id}`))).data();
      return old ? matches(old) : null;
    });
    if (previous) return previous;
    await this.service.rate(caller.uid, 'photo', 12, 60_000);
    const image = await this.service.couple.stageImage(caller.uid, await this.service.couple.normalizeImage(bytes, contentType, false));
    let attached = false;
    try {
      const result = await this.db.runTransaction(async tx => {
        const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
        const ref = this.db.doc(`pairs/${pairId}/photos/${id}`), old = (await tx.get(ref)).data();
        if (old) return matches(old);
        const recipientId = pair.members.find((uid: string) => uid !== caller.uid);
        const sentAt = Timestamp.fromMillis(Math.max(this.service.now(), (pair.lastPhotoMillis ?? 0) + 1));
        const value = {id, pairId, pairEpoch, authorId: caller.uid, recipientId, caption, photo: image, sourceSHA256, sentAt, reaction: null};
        await this.service.couple.attachImage(tx, image);
        tx.create(ref, value);
        tx.update(this.db.doc(`pairs/${pairId}`), {lastPhotoMillis: sentAt.toMillis()});
        tx.set(this.db.doc(`pairs/${pairId}/views/${recipientId}`), {latestPhotoId: id}, {merge: true});
        tx.create(this.db.doc(`notificationEvents/${digest(`${pairId}:photo:${id}`)}`), {
          pairId, pairEpoch, type: 'photo', photoId: id, recipientId, actorId: caller.uid, status: 'pending', attempts: 0, nextAttemptAt: sentAt
        });
        attached = true;
        return {photo: publicPhoto(value)};
      });
      if (!attached) await this.service.couple.abandonImage(image);
      return result;
    } catch (error) {await this.service.couple.abandonImage(image); throw error;}
  }

  async image(caller: Caller, input: Input): Promise<Buffer> {
    const before = await this.db.runTransaction(tx => this.authorized(tx, caller, input));
    const [bytes] = await this.service.bucket.file(before.photo.path).download();
    if (digest(bytes) !== before.photo.sha256) fail('asset_integrity_mismatch');
    const after = await this.db.runTransaction(tx => this.authorized(tx, caller, input));
    if (after.photo.id !== before.photo.id) fail('photo_changed', 'aborted');
    return bytes;
  }

  async setReaction(caller: Caller, input: Input, latestOnly = false, authorize?: (tx: Transaction) => Promise<void>): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), id = photoID(input.photoId);
    if (!['heart', 'laugh', 'fire', 'tear'].includes(String(input.kind))) fail('invalid_photo_reaction', 'invalid-argument');
    const assetId = identifier(input.assetId, 'asset_id');
    await this.service.rate(caller.uid, 'photo_reaction', 30, 60_000);
    return this.db.runTransaction(async tx => {
      await authorize?.(tx);
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const value = await this.authorized(tx, caller, {...input, assetId});
      if (value.recipientId !== caller.uid) fail('not_photo_recipient', 'permission-denied');
      if (latestOnly) {
        const latest = await this.latest(tx, caller.uid, pair);
        if (latest?.id !== id || latest.photo.id !== assetId) fail('latest_photo_changed', 'aborted');
      }
      if (value.reaction?.kind === input.kind) return {reaction: publicReaction(value.reaction), photo: publicPhoto(value)};
      const updatedAt = Timestamp.fromMillis(Math.max(this.service.now(), value.sentAt.toMillis(), (value.reaction?.updatedAt.toMillis() ?? 0) + 1));
      const reaction = {authorId: caller.uid, photoId: id, kind: input.kind, updatedAt};
      tx.update(this.db.doc(`pairs/${pairId}/photos/${id}`), {reaction});
      tx.create(this.db.doc(`notificationEvents/${randomUUID()}`), {
        pairId, pairEpoch, type: 'photo-reaction', photoId: id, recipientId: value.authorId, actorId: caller.uid,
        status: 'pending', attempts: 0, nextAttemptAt: updatedAt
      });
      // Refresh the reacting device's other widgets without an app alert.
      tx.create(this.db.doc(`notificationEvents/${randomUUID()}`), {
        pairId, pairEpoch, type: 'widget', recipientId: caller.uid,
        status: 'pending', attempts: 0, nextAttemptAt: updatedAt
      });
      return {reaction: publicReaction(reaction), photo: publicPhoto({...value, reaction})};
    });
  }
}
