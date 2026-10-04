import {S3Client} from '@aws-sdk/client-s3';
import {Database, Timestamp} from './database';
import {AssetStore} from './assets';
import {PairNotesService} from './service';
import {createHTTPApp} from './http';
import {dispatchNotification, LivePushTransport} from './notifications';
import {AuthService, OIDCIdentityTokenVerifier} from './auth';

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}
async function main(): Promise<void> {
  const db = new Database(required('DATABASE_URL'));
  await db.migrate();
  const s3 = new S3Client({region: required('REGION'), endpoint: required('ENDPOINT'),
    credentials: {accessKeyId: required('ACCESS_KEY_ID'), secretAccessKey: required('SECRET_ACCESS_KEY')},
    forcePathStyle: process.env.S3_FORCE_PATH_STYLE === 'true', maxAttempts: 3});
  const service = new PairNotesService(db, new AssetStore(s3, required('BUCKET')));
  const auth = new AuthService(db, new OIDCIdentityTokenVerifier({
    googleClientIDs: (process.env.GOOGLE_CLIENT_IDS ?? '').split(',').filter(Boolean),
    appleClientIDs: (process.env.APPLE_CLIENT_IDS ?? '').split(',').filter(Boolean)
  }));
  const transport = new LivePushTransport(() => {
    const key = process.env.PAIRNOTES_APNS_KEY, keyId = process.env.PAIRNOTES_APNS_KEY_ID, teamId = process.env.PAIRNOTES_APNS_TEAM_ID, bundleId = process.env.PAIRNOTES_APP_BUNDLE_ID;
    return key && keyId && teamId && bundleId ? {key, keyId, teamId, bundleId} : undefined;
  });
  let ready = true, stopping = false, polling = false, lastCleanup = 0;
  async function poll(): Promise<void> {
    if (stopping || polling) return;
    polling = true;
    try {
      const pending = await db.collection('notificationEvents').where('status', '==', 'pending')
        .where('nextAttemptAt', '<=', Timestamp.now()).orderBy('nextAttemptAt').limit(20).get();
      ready = true;
      for (let start = 0; start < pending.docs.length && !stopping; start += 4) {
        await Promise.allSettled(pending.docs.slice(start, start + 4).map(event => dispatchNotification(db, event.id, transport)));
      }
      if (Date.now() - lastCleanup > 60_000) {
        await service.cleanupExpiredUploads(); await db.pruneExpiredCredentials(Date.now()); lastCleanup = Date.now();
      }
    } catch {ready = false; console.error('notification_worker_unavailable');}
    finally {polling = false;}
  }
  const app = createHTTPApp({service, auth, ready: () => ready});
  const server = app.listen(Number(process.env.PORT ?? 8081), '0.0.0.0', () => {console.info('PairNotes HTTP server started');});
  server.requestTimeout = 120_000;
  const timer = setInterval(() => {void poll();}, 5000);
  void poll();
  function shutdown(): void {
    stopping = true; clearInterval(timer);
    server.close(() => {void db.terminate(); s3.destroy();});
  }
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}
void main().catch(() => {console.error('PairNotes startup failed; verify private configuration and database availability'); process.exitCode = 1;});
