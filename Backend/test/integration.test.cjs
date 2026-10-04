const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID, randomBytes} = require('node:crypto');
const {S3Client, CreateBucketCommand, PutObjectCommand} = require('@aws-sdk/client-s3');
const sharp = require('sharp');
const {Database, Timestamp} = require('../lib/database');
const {AssetStore} = require('../lib/assets');
const {PairNotesService, digest, fail} = require('../lib/service');
const {createHTTPApp, decodeCallable} = require('../lib/http');
const {dispatchNotification} = require('../lib/notifications');

let db, s3, service, server, endpoint;
const bucket = `pairnotes-test-${randomUUID()}`;
// Only an injected test double for identity. Business operations use real HTTP, SQL and S3.
const identities = new Map();
const auth = {authenticate: async token => identities.get(token) ?? fail('authentication_required', 'unauthenticated'),
  challenge: async () => fail('test_only'), exchange: async () => fail('test_only'), refresh: async () => fail('test_only'), session: async () => fail('test_only'), signout: async () => fail('test_only')};
async function request(path, user, body, method = 'POST', headers = {}) {
  const result = await fetch(`${endpoint}${path}`, {method, headers: {...(user ? {authorization: `Bearer ${user.token}`} : {}),
    ...(Buffer.isBuffer(body) ? {} : {'content-type': 'application/json'}), ...headers}, body: body === undefined ? undefined : Buffer.isBuffer(body) ? body : JSON.stringify(body)});
  return result;
}
async function call(name, user, data = {}) {
  const response = await request(`/${name}`, user, {data});
  const result = await response.json();
  if (result.error || result.reason) throw new Error(result.error?.details?.reason ?? result.reason);
  assert.equal(response.status, 200); return result.result;
}
async function user() {
  const result = {uid: randomUUID(), token: randomBytes(32).toString('base64url')};
  identities.set(result.token, {uid: result.uid, authTime: Math.floor(Date.now() / 1000)});
  await call('upsertProfile', result, {displayName: 'Persona ficticia'}); return result;
}
async function paired() {
  const a = await user(), b = await user(), invite = await call('createInvite', a);
  return {a, b, pair: (await call('acceptInvite', b, {token: invite.token})).pair};
}
async function prepare(a, pair) {
  const source = Buffer.from(`Fictional opaque source ${randomUUID()}`);
  const png = await sharp({create: {width: 16, height: 16, channels: 4, background: '#b345ff'}}).png().toBuffer();
  const bytes = {source, final: png, widget: png, thumbnail: png};
  const payload = {pairId: pair.id, pairEpoch: pair.pairEpoch, idempotencyKey: randomUUID(), noteId: randomUUID(), revision: 1, revisionHash: digest(source),
    assets: Object.entries(bytes).map(([role, data]) => ({role, sha256: digest(data), byteCount: data.length, contentType: role === 'source' ? 'application/octet-stream' : 'image/png'}))};
  return {payload, bytes, session: await call('createUploadSession', a, payload)};
}
async function upload(a, fixture, selected = Object.keys(fixture.bytes)) {
  for (const role of selected) {
    const asset = fixture.payload.assets.find(value => value.role === role);
    const response = await request(`/upload?sessionId=${fixture.session.sessionId}&role=${role}`, a, fixture.bytes[role], 'PUT',
      {'content-type': asset.contentType, 'x-content-sha256': asset.sha256});
    const result = await response.json(); assert.equal(response.status, 200, JSON.stringify(result));
  }
}
const finalize = (a, pair, fixture) => call('finalizeNote', a, {sessionId: fixture.session.sessionId, pairId: pair.id, pairEpoch: pair.pairEpoch});
const pairInput = pair => ({pairId: pair.id, pairEpoch: pair.pairEpoch});
const eventRef = (pair, noteId) => db.doc(`notificationEvents/${digest(`${pair.id}:${noteId}`)}`);
before(async () => {
  assert.ok(process.env.DATABASE_URL, 'Set DATABASE_URL to the isolated PostgreSQL test container');
  assert.ok(['localhost', '127.0.0.1', 'postgres'].includes(new URL(process.env.DATABASE_URL).hostname), 'Tests refuse a remote database');
  assert.ok(['localhost', '127.0.0.1', 'minio'].includes(new URL(process.env.TEST_S3_ENDPOINT ?? 'http://127.0.0.1:59000').hostname), 'Tests refuse remote S3');
  db = new Database(process.env.DATABASE_URL); await db.migrate();
  s3 = new S3Client({region: 'us-east-1', endpoint: process.env.TEST_S3_ENDPOINT ?? 'http://127.0.0.1:59000', forcePathStyle: true,
    credentials: {accessKeyId: 'pairnotes-local', secretAccessKey: 'pairnotes-local-only'}});
  await s3.send(new CreateBucketCommand({Bucket: bucket}));
  service = new PairNotesService(db, new AssetStore(s3, bucket));
  server = createHTTPApp({service, auth}).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve)); endpoint = `http://127.0.0.1:${server.address().port}`;
});
after(async () => {if (server) await new Promise(resolve => server.close(resolve)); if (db) await db.terminate(); s3?.destroy();});

test('HTTP rejects missing/forged credentials and does not accept UID impersonation', async () => {
  await assert.rejects(call('upsertProfile', null, {displayName: 'x'}), /authentication_required/);
  await assert.rejects(call('upsertProfile', {token: 'fake'}, {displayName: 'x'}), /authentication_required/);
  const a = await user(), b = await user();
  const {profile} = await call('upsertProfile', a, {uid: b.uid, displayName: 'Ficción A'});
  assert.equal(profile.uid, a.uid); assert.equal((await db.doc(`users/${b.uid}`).get()).data().displayName, 'Persona ficticia');
  assert.equal((await request('/healthz', null, undefined, 'GET')).headers.get('cache-control'), 'private, no-store');
});
test('invite token is 256-bit, stored hashed, self/revoked/expired/replaced invites fail', async () => {
  const a = await user(), b = await user();
  const first = await call('createInvite', a);
  assert.equal(Buffer.from(first.token, 'base64url').length, 32);
  assert.equal((await db.doc(`pairInvites/${digest(first.token)}`).get()).data().token, undefined);
  await assert.rejects(call('acceptInvite', a, {token: first.token}), /self_invite/);
  await call('revokeInvite', a); await assert.rejects(call('acceptInvite', b, {token: first.token}), /invite_unavailable/);
  const second = await call('createInvite', a);
  await db.doc(`pairInvites/${digest(second.token)}`).update({expiresAt: Timestamp.fromMillis(Date.now() - 1)});
  await assert.rejects(call('acceptInvite', b, {token: second.token}), /invite_unavailable/);
  const third = await call('createInvite', a); await call('createInvite', a);
  await assert.rejects(call('acceptInvite', b, {token: third.token}), /invite_unavailable/);
});
test('concurrent acceptance consumes once, makes exactly two members, prevents second pair and third user', async () => {
  const a = await user(), b = await user(), c = await user(), invite = await call('createInvite', a);
  const results = await Promise.allSettled([call('acceptInvite', b, {token: invite.token}), call('acceptInvite', c, {token: invite.token})]);
  assert.equal(results.filter(value => value.status === 'fulfilled').length, 1);
  const pair = results.find(value => value.status === 'fulfilled').value.pair;
  assert.equal(pair.members.length, 2);
  await assert.rejects(call('acceptInvite', c, {token: invite.token}), /invite_unavailable/);
  await assert.rejects(call('createInvite', a), /already_paired/);
  const outsider = pair.members.includes(c.uid) ? b : c;
  await assert.rejects(call('timeline', outsider, pairInput(pair)), /not_pair_member/);
  const d = await user(), otherInvite = await call('createInvite', d);
  await assert.rejects(call('acceptInvite', a, {token: otherInvite.token}), /already_paired/);
});
test('failed invite attempts are counted and limited', async () => {
  const a = await user();
  for (let i = 0; i < 10; i++) await assert.rejects(call('acceptInvite', a, {token: 'a'.repeat(43)}), /invite_unavailable/);
  await assert.rejects(call('acceptInvite', a, {token: 'a'.repeat(43)}), /rate_limited/);
});
test('foreign, missing, expired and corrupt uploads cannot publish or queue a notification', async () => {
  const {a, b, pair} = await paired(), fixture = await prepare(a, pair);
  await assert.rejects(finalize(b, pair, fixture), /not_upload_owner/);
  const forbidden = await request(`/upload?sessionId=${fixture.session.sessionId}&role=source`, b, fixture.bytes.source, 'PUT', {'content-type': 'application/octet-stream', 'x-content-sha256': fixture.payload.revisionHash});
  assert.equal(forbidden.status, 403);
  await upload(a, fixture, ['source']);
  await assert.rejects(finalize(a, pair, fixture), /assets_incomplete/);
  assert.equal((await eventRef(pair, fixture.payload.noteId).get()).exists, false);
  await db.doc(`uploadSessions/${fixture.session.sessionId}`).update({expiresAt: Timestamp.fromMillis(Date.now() - 1)});
  await assert.rejects(finalize(a, pair, fixture), /upload_expired/);
});
test('S3 writes are create-only; upload retries are idempotent; asset hashes/size are checked', async () => {
  const {a, pair} = await paired(), fixture = await prepare(a, pair);
  await upload(a, fixture); await upload(a, fixture);
  const wrong = await request(`/upload?sessionId=${fixture.session.sessionId}&role=source`, a, Buffer.from('wrong'), 'PUT', {'content-type': 'application/octet-stream', 'x-content-sha256': fixture.payload.revisionHash});
  assert.equal(wrong.status, 400);
  await assert.rejects(s3.send(new PutObjectCommand({Bucket: bucket, Key: fixture.session.paths.source, Body: Buffer.from('replacement'), IfNoneMatch: '*'})), error => error.$metadata.httpStatusCode === 412);
  const {note} = await finalize(a, pair, fixture);
  const unauthorized = await fetch(`${process.env.TEST_S3_ENDPOINT ?? 'http://127.0.0.1:59000'}/${bucket}/${note.paths.widget}`);
  assert.equal(unauthorized.status, 403);
});
test('finalization enforces decoded image validity and source integrity even if storage is corrupted', async () => {
  const {a, pair} = await paired(), fixture = await prepare(a, pair);
  await upload(a, fixture);
  await s3.send(new PutObjectCommand({Bucket: bucket, Key: fixture.session.paths.source, Body: Buffer.alloc(fixture.bytes.source.length), ContentType: 'application/octet-stream'}));
  await assert.rejects(finalize(a, pair, fixture), /asset_integrity_mismatch/);
  assert.equal((await eventRef(pair, fixture.payload.noteId).get()).exists, false);
  const bad = await prepare(a, pair); await upload(a, bad);
  const bytes = Buffer.from('not PNG');
  const data = (await db.doc(`uploadSessions/${bad.session.sessionId}`).get()).data();
  data.assets.final.sha256 = digest(bytes); data.assets.final.byteCount = bytes.length;
  await db.doc(`uploadSessions/${bad.session.sessionId}`).set(data);
  await s3.send(new PutObjectCommand({Bucket: bucket, Key: bad.session.paths.final, Body: bytes, ContentType: 'image/png'}));
  await assert.rejects(finalize(a, pair, bad), /invalid_image/);
});
test('concurrent finalize and idempotency replay produce one immutable note and one event', async () => {
  const {a, pair} = await paired(), fixture = await prepare(a, pair);
  assert.equal((await call('createUploadSession', a, fixture.payload)).sessionId, fixture.session.sessionId);
  assert.equal((await call('createUploadSession', a, {...fixture.payload, assets: [...fixture.payload.assets].reverse()})).sessionId, fixture.session.sessionId);
  await assert.rejects(call('createUploadSession', a, {...fixture.payload, revision: 2}), /idempotency_conflict/);
  await assert.rejects(call('createUploadSession', a, {...fixture.payload, idempotencyKey: randomUUID()}), /note_id_exists/);
  await upload(a, fixture);
  const [one, two] = await Promise.all([finalize(a, pair, fixture), finalize(a, pair, fixture)]);
  assert.deepEqual(one, two); assert.deepEqual(await finalize(a, pair, fixture), one);
  assert.equal((await call('timeline', a, pairInput(pair))).notes.length, 1);
  assert.equal((await db.collection('notificationEvents').where('pairId', '==', pair.id).get()).size, 1);
});
test('authorized timeline cursor is stable; third user and anonymous image access fail; latest received ignores sent notes', async () => {
  const {a, b, pair} = await paired(), outsider = await user(), notes = [];
  for (const author of [a, b, a]) {const f = await prepare(author, pair); await upload(author, f); notes.push((await finalize(author, pair, f)).note);}
  const page1 = await call('timeline', b, {...pairInput(pair), limit: 2});
  const page2 = await call('timeline', b, {...pairInput(pair), limit: 2, cursor: page1.nextCursor});
  assert.deepEqual([...page1.notes, ...page2.notes].map(n => n.id), notes.map(n => n.id).reverse());
  assert.equal(page2.nextCursor, null);
  assert.equal((await call('latestReceivedNote', a, pairInput(pair))).note.id, notes[1].id);
  assert.equal((await call('latestReceivedNote', b, pairInput(pair))).note.id, notes[2].id);
  await assert.rejects(call('timeline', outsider, pairInput(pair)), /not_pair_member/);
  await assert.rejects(call('note', outsider, {...pairInput(pair), noteId: notes[0].id}), /not_pair_member/);
  for (const denied of [outsider, null]) assert.ok([401, 403].includes((await request(`/image?path=${notes[0].paths.widget}`, denied, undefined, 'GET')).status));
  const response = await request(`/image?path=${notes[0].paths.widget}`, b, undefined, 'GET');
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'private, no-store');
});
test('notifications occur after commit, contain generic copy only and concurrent workers lease once', async () => {
  const {a, b, pair} = await paired();
  await call('registerDevice', b, {deviceId: 'phone', apnsToken: 'ab'.repeat(32), widgetPushToken: 'cd'.repeat(32), apnsEnvironment: 'development'});
  const fixture = await prepare(a, pair), sends = [];
  const transport = {app: async (token, payload) => {assert.equal((await db.doc(`pairs/${pair.id}/notes/${fixture.payload.noteId}`).get()).exists, true); sends.push({channel: 'app', payload});}, widget: async () => sends.push({channel: 'widget'})};
  await dispatchNotification(db, eventRef(pair, fixture.payload.noteId).id, transport); assert.equal(sends.length, 0);
  await upload(a, fixture); await finalize(a, pair, fixture);
  await Promise.all([dispatchNotification(db, eventRef(pair, fixture.payload.noteId).id, transport), dispatchNotification(db, eventRef(pair, fixture.payload.noteId).id, transport)]);
  assert.equal(sends.length, 2);
  assert.deepEqual(sends[0].payload.aps.alert, {title: 'PairNotes', body: 'Tenés un dibujo nuevo'});
  assert.deepEqual(Object.keys(sends[0].payload).sort(), ['aps', 'noteId', 'pairEpoch', 'pairId']);
  await dispatchNotification(db, eventRef(pair, fixture.payload.noteId).id, transport); assert.equal(sends.length, 2);
});
test('failed push channel retries independently; acknowledged widget channel is not resent', async () => {
  const {a, b, pair} = await paired();
  await call('registerDevice', b, {deviceId: 'phone', apnsToken: 'ab'.repeat(32), widgetPushToken: 'cd'.repeat(32), apnsEnvironment: 'development'});
  const f = await prepare(a, pair); await upload(a, f); await finalize(a, pair, f);
  let apps = 0, widgets = 0;
  const transport = {app: async () => {apps++; if (apps === 1) throw Error('temporary');}, widget: async () => {widgets++;}};
  await assert.rejects(dispatchNotification(db, eventRef(pair, f.payload.noteId).id, transport), /notification_channel_failed/);
  await eventRef(pair, f.payload.noteId).update({nextAttemptAt: Timestamp.now()});
  await dispatchNotification(db, eventRef(pair, f.payload.noteId).id, transport);
  assert.equal(apps, 2); assert.equal(widgets, 1);
});
test('widget credentials return last received only, rotate, expire, unregister, never expose paths or mark viewed', async () => {
  const {a, b, pair} = await paired();
  await call('registerDevice', b, {deviceId: 'widget-phone', apnsEnvironment: 'development'});
  const session = await call('issueWidgetSession', b, {deviceId: 'widget-phone'}), userToken = {token: session.token};
  const f = await prepare(a, pair); await upload(a, f); const {note} = await finalize(a, pair, f);
  const snap = await (await request('/widgetSnapshot', userToken, undefined, 'GET')).json();
  assert.equal(snap.note.id, note.id); assert.equal(snap.note.paths, undefined);
  assert.ok(snap.validUntil <= session.expiresAt && snap.validUntil <= Date.now() + 15 * 60_000);
  const response = await request(`/widgetImage?noteId=${note.id}`, userToken, undefined, 'GET');
  assert.equal(digest(Buffer.from(await response.arrayBuffer())), snap.note.imageSHA256);
  assert.equal((await request('/widgetImage?noteId=old', userToken, undefined, 'GET')).status, 409);
  assert.equal((await request(`/image?path=${note.paths.source}`, userToken, undefined, 'GET')).status, 401);
  await assert.rejects(call('timeline', userToken, pairInput(pair)), /authentication_required/);
  assert.equal((await db.doc(`pairs/${pair.id}/views/${b.uid}`).get()).data().viewedAt, undefined);
  await request('/widgetPushRegistration', userToken, {enabled: true, token: 'ef'.repeat(32), uid: a.uid, deviceId: 'other'});
  assert.equal((await db.doc(`users/${b.uid}/devices/widget-phone`).get()).data().widgetPushToken, 'ef'.repeat(32));
  const rotated = await call('issueWidgetSession', b, {deviceId: 'widget-phone'});
  assert.equal((await request('/widgetSnapshot', userToken, undefined, 'GET')).status, 401);
  await db.doc(`widgetSessions/${digest(rotated.token)}`).update({expiresAt: Timestamp.fromMillis(Date.now() - 1)});
  assert.equal((await request('/widgetSnapshot', {token: rotated.token}, undefined, 'GET')).status, 401);
  const last = await call('issueWidgetSession', b, {deviceId: 'widget-phone'}); await call('unregisterDevice', b, {deviceId: 'widget-phone'});
  assert.equal((await request('/widgetSnapshot', {token: last.token}, undefined, 'GET')).status, 401);
  await assert.rejects(call('markNoteViewed', a, {...pairInput(pair), noteId: note.id}), /not_note_recipient/);
  await call('markNoteViewed', b, {...pairInput(pair), noteId: note.id});
  assert.ok((await db.doc(`pairs/${pair.id}/views/${b.uid}`).get()).data().viewedAt);
});
test('closing pair requires recent identity and invalidates epochs, history, assets, pending publication and push', async () => {
  const {a, b, pair} = await paired(), f = await prepare(a, pair); await upload(a, f); const {note} = await finalize(a, pair, f);
  const pending = await prepare(a, pair); await upload(a, pending);
  await call('registerDevice', b, {deviceId: 'phone'}); const credential = await call('issueWidgetSession', b, {deviceId: 'phone'});
  await assert.rejects(call('timeline', a, {...pairInput(pair), pairEpoch: 99}), /stale_pair_epoch/);
  await assert.rejects(service.closePair({uid: a.uid, authTime: 0}, pairInput(pair)), /recent_login_required/);
  await call('closePair', a, pairInput(pair));
  assert.equal((await db.doc(`pairs/${pair.id}`).get()).data().pairEpoch, 2);
  assert.equal((await call('getPairState', b)).pair, null);
  await assert.rejects(finalize(a, pair, pending), /not_pair_member/);
  await assert.rejects(call('timeline', a, pairInput(pair)), /not_pair_member/);
  assert.equal((await request(`/image?path=${note.paths.widget}`, b, undefined, 'GET')).status, 403);
  assert.equal((await request('/widgetSnapshot', {token: credential.token}, undefined, 'GET')).status, 403);
  await dispatchNotification(db, eventRef(pair, note.id).id, {app: async () => assert.fail('closed pair push'), widget: async () => assert.fail('closed pair widget')});
  assert.equal((await eventRef(pair, note.id).get()).data().status, 'cancelled');
});
test('typed integer wire values decode without unsafe precision or prototype keys', () => {
  assert.deepEqual(decodeCallable({pairEpoch: {'@type': 'type.googleapis.com/google.protobuf.UInt64Value', value: '1'}}), {pairEpoch: 1});
  assert.throws(() => decodeCallable({'@type': 'type.googleapis.com/google.protobuf.UInt64Value', value: '9007199254740993'}), /unsafe_integer/);
});
test('an expired upload can be explicitly renewed with the same idempotency key, never a duplicate note', async () => {
  const {a, pair} = await paired(), fixture = await prepare(a, pair);
  await upload(a, fixture, ['source']);
  await db.doc(`uploadSessions/${fixture.session.sessionId}`).update({expiresAt: Timestamp.fromMillis(Date.now() - 1)});
  await assert.rejects(finalize(a, pair, fixture), /upload_expired/);
  const retry = await call('createUploadSession', a, fixture.payload);
  assert.equal(retry.sessionId, fixture.session.sessionId);
  await upload(a, fixture); await finalize(a, pair, fixture);
  assert.equal((await call('timeline', a, pairInput(pair))).notes.length, 1);
});
test('garbage collection removes orphan/temp assets, preserves published assets, and supports renewal after cleanup', async () => {
  const {a, pair} = await paired(), published = await prepare(a, pair), orphan = await prepare(a, pair);
  await upload(a, published); const {note} = await finalize(a, pair, published);
  await upload(a, orphan); await service.freeze((await db.doc(`uploadSessions/${orphan.session.sessionId}`).get()).data());
  for (const f of [published, orphan]) await db.doc(`uploadSessions/${f.session.sessionId}`).update({expiresAt: Timestamp.fromMillis(Date.now() - 2 * 3600_000)});
  await service.cleanupExpiredUploads();
  assert.equal((await service.bucket.file(published.session.paths.source).exists())[0], false);
  assert.equal((await service.bucket.file(note.paths.widget).exists())[0], true);
  assert.equal((await service.bucket.file(`pairs/${pair.id}/${pair.pairEpoch}/${orphan.payload.noteId}/widget`).exists())[0], false);
  await call('createUploadSession', a, orphan.payload); await upload(a, orphan); await finalize(a, pair, orphan);
  assert.equal((await call('timeline', a, pairInput(pair))).notes.length, 2);
});
test('credential pruning preserves refresh reuse evidence until the absolute family deadline', async () => {
  const id = randomUUID(), now = Date.now();
  await db.doc(`authChallenges/${id}`).create({expiresAt: Timestamp.fromMillis(now - 1)});
  await db.doc(`authSessions/${id}`).create({expiresAt: Timestamp.fromMillis(now - 1), refreshExpiresAt: Timestamp.fromMillis(now + 60_000)});
  await db.doc(`authRefresh/${id}`).create({consumedAt: Timestamp.fromMillis(now - 1), expiresAt: Timestamp.fromMillis(now + 60_000)});
  await db.pruneExpiredCredentials(now);
  assert.equal((await db.doc(`authChallenges/${id}`).get()).exists, false);
  assert.equal((await db.doc(`authSessions/${id}`).get()).exists, true);
  assert.equal((await db.doc(`authRefresh/${id}`).get()).exists, true);
  await db.pruneExpiredCredentials(now + 60_001);
  assert.equal((await db.doc(`authSessions/${id}`).get()).exists, false);
  assert.equal((await db.doc(`authRefresh/${id}`).get()).exists, false);
});
test('switching accounts on one installation transfers push ownership and revokes the old widget even after offline logout', async () => {
  const {a, b, pair} = await paired(), nextAccount = await user(), deviceId = randomUUID();
  const previousSession = randomUUID(), nextSession = randomUUID();
  identities.get(b.token).sessionId = previousSession; identities.get(nextAccount.token).sessionId = nextSession;
  await db.doc(`installationSessions/${digest(deviceId)}`).set({uid: b.uid, sessionId: previousSession, deviceId});
  const appToken = randomBytes(32).toString('hex'), widgetToken = randomBytes(32).toString('hex');
  await call('registerDevice', b, {deviceId, apnsToken: appToken, widgetPushToken: widgetToken, apnsEnvironment: 'development'});
  const old = await call('issueWidgetSession', b, {deviceId});
  // No signout request reaches the server. A new account owns the same local installation.
  await db.doc(`installationSessions/${digest(deviceId)}`).set({uid: nextAccount.uid, sessionId: nextSession, deviceId});
  await call('registerDevice', nextAccount, {deviceId, apnsToken: appToken, widgetPushToken: widgetToken, apnsEnvironment: 'development'});
  await assert.rejects(call('registerDevice', b, {deviceId, apnsToken: appToken, apnsEnvironment: 'development'}), /installation_session_changed/);
  assert.equal((await db.doc(`users/${b.uid}/devices/${deviceId}`).get()).exists, false);
  assert.equal((await request('/widgetSnapshot', {token: old.token}, undefined, 'GET')).status, 401);
  const f = await prepare(a, pair); await upload(a, f); await finalize(a, pair, f);
  await dispatchNotification(db, eventRef(pair, f.payload.noteId).id, {app: async () => assert.fail('old account notification'), widget: async () => assert.fail('old account widget')});
  // Token ownership also transfers if a fresh installation ID was generated.
  const replacement = randomUUID();
  await call('registerDevice', b, {deviceId: replacement, apnsToken: appToken, apnsEnvironment: 'development'});
  assert.equal((await db.doc(`users/${nextAccount.uid}/devices/${deviceId}`).get()).exists, false);
});
