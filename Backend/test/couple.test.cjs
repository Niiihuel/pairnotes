const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID, randomBytes} = require('node:crypto');
const {S3Client, CreateBucketCommand} = require('@aws-sdk/client-s3');
const sharp = require('sharp');
const {Database, Timestamp} = require('../lib/database');
const {AssetStore} = require('../lib/assets');
const {PairNotesService, digest, fail} = require('../lib/service');
const {createHTTPApp} = require('../lib/http');
const {dispatchNotification, LivePushTransport} = require('../lib/notifications');
let db, service, s3, server, endpoint, now = Date.now();
const identities = new Map(), bucket = `pairnotes-couple-${randomUUID()}`;
const auth = {authenticate: async value => identities.get(value) ?? fail('authentication_required', 'unauthenticated')};
const scope = pair => ({pairId: pair.id, pairEpoch: pair.pairEpoch});
async function request(path, user, body, method = 'POST', type = 'application/json') {
  return fetch(endpoint + path, {method, headers: {'content-type': type, ...(user ? {authorization: `Bearer ${user.token}`} : {})},
    body: body === undefined ? undefined : Buffer.isBuffer(body) ? body : JSON.stringify(body)});
}
async function call(name, user, data = {}) {
  const response = await request('/' + name, user, {data}), body = await response.json();
  if (!response.ok) throw Error(body.error?.details?.reason ?? body.reason);
  return body.result;
}
async function user() {
  const value = {uid: randomUUID(), token: randomBytes(32).toString('base64url')};
  identities.set(value.token, {uid: value.uid, authTime: Math.floor(now / 1000)});
  await call('upsertProfile', value, {displayName: 'Perfil ficticio'}); return value;
}
async function paired() {
  now = Date.now();
  const a = await user(), b = await user(), outsider = await user();
  const invitation = await call('createInvite', a), {pair} = await call('acceptInvite', b, {token: invitation.token});
  return {a, b, outsider, pair};
}
async function picture() {
  return sharp({create: {width: 480, height: 320, channels: 3, background: '#db7093'}})
    .withMetadata({orientation: 6, exif: {IFD0: {Artist: 'Fictional test metadata'}}}).jpeg().toBuffer();
}
async function memory(a, pair, values = {}) {
  return (await call('upsertMemory', a, {...scope(pair), memoryId: randomUUID(), title: 'Recuerdo ficticio', date: '2024-02-29',
    kind: 'memory', recursYearly: false, ...values})).memory;
}
const photoPath = (pair, item) => `/memoryPhoto?pairId=${pair.id}&pairEpoch=${pair.pairEpoch}&memoryId=${item.id}`;
async function widget(user) {
  const deviceId = randomUUID();
  await call('registerDevice', user, {deviceId});
  return {...await call('issueWidgetSession', user, {deviceId}), deviceId};
}
async function consent(user, pair, deviceId = randomUUID()) {
  await call('registerDevice', user, {deviceId});
  return {deviceId, ...(await call('setLocationConsent', user, {...scope(pair), enabled: true, deviceId})).location};
}
async function sample(user, pair, location, overrides = {}) {
  return call('updateLocation', user, {...scope(pair), deviceId: location.deviceId, consentVersion: location.consentVersion,
    sequence: 1, latitude: -31.4167, longitude: -64.1833, horizontalAccuracy: 50, capturedAt: now, ...overrides});
}
function assertNoPrivateKeys(value) {
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    assert.ok(!['latitude', 'longitude', 'path', 'paths', 'receivedAt'].includes(key), `private key ${key}`);
    assertNoPrivateKeys(child);
  }
}
before(async () => {
  assert.ok(['localhost', '127.0.0.1', 'postgres'].includes(new URL(process.env.DATABASE_URL).hostname));
  assert.ok(['localhost', '127.0.0.1', 'minio'].includes(new URL(process.env.TEST_S3_ENDPOINT).hostname));
  db = new Database(process.env.DATABASE_URL); await db.migrate();
  s3 = new S3Client({region: 'us-east-1', endpoint: process.env.TEST_S3_ENDPOINT, forcePathStyle: true,
    credentials: {accessKeyId: 'pairnotes-local', secretAccessKey: 'pairnotes-local-only'}});
  await s3.send(new CreateBucketCommand({Bucket: bucket}));
  service = new PairNotesService(db, new AssetStore(s3, bucket), () => now);
  server = createHTTPApp({service, auth}).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve)); endpoint = `http://127.0.0.1:${server.address().port}`;
});
after(async () => {if (server) await new Promise(resolve => server.close(resolve)); await db?.terminate(); s3?.destroy();});

test('couple date is date-only, nullable and rejects invalid/future dates, outsiders and stale epochs', async () => {
  const {a, b, outsider, pair} = await paired();
  assert.equal((await call('getCoupleSpace', a, scope(pair))).startedOn, null);
  await call('updatePairDetails', a, {...scope(pair), startedOn: '2024-02-29'});
  assert.equal((await call('getPairState', b)).pair.startedOn, '2024-02-29');
  for (const startedOn of ['2025-02-29', '2024-2-29', '2024-02-29T00:00:00Z', '9999-01-01', 1]) {
    await assert.rejects(call('updatePairDetails', a, {...scope(pair), startedOn}), /invalid_date|future_pair_date/);
  }
  await assert.rejects(call('updatePairDetails', outsider, {...scope(pair), startedOn: null}), /not_pair_member/);
  await assert.rejects(call('getCoupleSpace', a, {...scope(pair), pairEpoch: 99}), /stale_pair_epoch/);
  await call('updatePairDetails', b, {...scope(pair), startedOn: null});
  assert.equal((await call('getCoupleSpace', a, scope(pair))).startedOn, null);
});
test('couple date validation uses the explicit local calendar day without timezone drift', async () => {
  const {a, pair} = await paired(); now = Date.UTC(2026, 9, 4, 12);
  await call('updatePairDetails', a, {...scope(pair), startedOn: '2026-10-05', timeZone: 'Pacific/Kiritimati'});
  await assert.rejects(call('updatePairDetails', a, {...scope(pair), startedOn: '2026-10-05', timeZone: 'America/Argentina/Cordoba'}), /future_pair_date/);
  await assert.rejects(call('updatePairDetails', a, {...scope(pair), startedOn: '2026-10-04', timeZone: 'fictional/invalid'}), /invalid_time_zone/);
});
test('memories authorize both members, preserve authorship and validate date, recurrence and text', async () => {
  const {a, b, outsider, pair} = await paired(), item = await memory(a, pair, {kind: 'date', recursYearly: true});
  const edited = await memory(b, pair, {memoryId: item.id, title: 'Aniversario ficticio', body: 'Texto privado'});
  assert.equal(edited.authorId, a.uid);
  assert.equal((await call('memories', a, scope(pair))).memories.length, 1);
  for (const values of [{date: '2026-04-31'}, {title: ' '}, {title: 'x'.repeat(121)}, {body: 'x'.repeat(2001)}, {recursYearly: 'true'}, {kind: 'unknown'}]) {
    await assert.rejects(memory(a, pair, values), /invalid_/);
  }
  for (const operation of ['getCoupleSpace', 'memories', 'deleteMemory', 'deleteMemoryPhoto']) {
    await assert.rejects(call(operation, outsider, {...scope(pair), memoryId: item.id}), /not_pair_member/);
  }
  await assert.rejects(memory(outsider, pair), /not_pair_member/);
  await assert.rejects(memory(a, pair, {noteId: randomUUID()}), /note_unavailable/);
  await call('deleteMemory', b, {...scope(pair), memoryId: item.id});
  assert.deepEqual((await call('memories', a, scope(pair))).memories, []);
});
test('private memory photos decode, strip metadata, enforce membership, delete and do not grant widget access', async () => {
  const {a, b, outsider, pair} = await paired(), item = await memory(a, pair), jpeg = await picture();
  const response = await request(photoPath(pair, item), a, jpeg, 'PUT', 'image/jpeg');
  assert.equal(response.status, 200);
  const {memory: uploaded} = await response.json(); assertNoPrivateKeys(uploaded);
  const noteId = randomUUID();
  await db.doc(`pairs/${pair.id}/notes/${noteId}`).create({id: noteId, pairId: pair.id, pairEpoch: pair.pairEpoch});
  const linked = await memory(b, pair, {memoryId: item.id, noteId});
  assert.equal(linked.noteId, noteId); assert.deepEqual(linked.photo, uploaded.photo);
  const replaced = await (await request(photoPath(pair, item), a, jpeg, 'PUT', 'image/jpeg')).json();
  assert.equal(replaced.memory.noteId, noteId); assert.ok(replaced.memory.photo);
  const downloaded = await request(photoPath(pair, item), b, undefined, 'GET');
  assert.equal(downloaded.headers.get('cache-control'), 'private, no-store');
  const bytes = Buffer.from(await downloaded.arrayBuffer()), metadata = await sharp(bytes).metadata();
  assert.equal(digest(bytes), uploaded.photo.sha256); assert.equal(metadata.format, 'png');
  assert.equal(metadata.exif, undefined); assert.equal(metadata.orientation, undefined);
  assert.ok(metadata.width <= 1536 && metadata.height <= 1536);
  assert.equal((await request(photoPath(pair, item), outsider, undefined, 'GET')).status, 403);
  assert.equal((await request(photoPath(pair, item), outsider, jpeg, 'PUT', 'image/jpeg')).status, 403);
  const credential = await widget(b);
  assert.equal((await request(photoPath(pair, item), credential, undefined, 'GET')).status, 401);
  assert.equal((await request(photoPath(pair, item) + '&photoId=old', b, undefined, 'GET')).status, 409);
  const {memory: removed} = await call('deleteMemoryPhoto', a, {...scope(pair), memoryId: item.id});
  assert.equal(removed.photo, null);
  assert.equal(removed.noteId, noteId);
  assert.equal((await request(photoPath(pair, item), b, undefined, 'GET')).status, 404);
});
test('avatars remain private, normalize to PNG, rotate IDs, retain profile edits and reject corrupt images', async () => {
  const {a, b, outsider, pair} = await paired(), image = await picture();
  const response = await request('/profileAvatar', a, image, 'PUT', 'image/jpeg');
  const {profile} = await response.json(); assert.equal(response.status, 200); assert.equal(profile.uid, a.uid);
  assertNoPrivateKeys(profile);
  await call('upsertProfile', a, {displayName: 'Otro nombre ficticio'});
  assert.deepEqual((await call('getPairState', b)).pair.partner.avatar, profile.avatar);
  const downloaded = await request(`/profileAvatar?uid=${a.uid}&avatarId=${profile.avatar.id}`, b, undefined, 'GET');
  const bytes = Buffer.from(await downloaded.arrayBuffer()), metadata = await sharp(bytes).metadata();
  assert.equal(digest(bytes), profile.avatar.sha256); assert.ok(metadata.width <= 256 && metadata.height <= 256);
  assert.equal(metadata.exif, undefined); assert.equal(metadata.orientation, undefined);
  assert.equal((await request(`/profileAvatar?uid=${a.uid}`, outsider, undefined, 'GET')).status, 403);
  assert.equal((await request(`/profileAvatar?uid=${a.uid}`, null, undefined, 'GET')).status, 401);
  assert.equal((await request('/profileAvatar', a, Buffer.from('not an image'), 'PUT', 'image/png')).status, 400);
  const again = await (await request('/profileAvatar', a, image, 'PUT', 'image/jpeg')).json();
  assert.notEqual(again.profile.avatar.id, profile.avatar.id);
  assert.equal((await request(`/profileAvatar?uid=${a.uid}&avatarId=${profile.avatar.id}`, b, undefined, 'GET')).status, 409);
  const old = (await db.doc(`privateImages/${profile.avatar.id}`).get()).data();
  now += 2 * 3600_000; await service.couple.cleanup();
  assert.equal((await service.bucket.file(old.path).exists())[0], false);
  assert.equal((await request(`/profileAvatar?uid=${a.uid}`, a, undefined, 'GET')).status, 200);
  await call('deleteProfileAvatar', a);
  assert.equal((await call('getCoupleSpace', b, scope(pair))).profiles.find(value => value.uid === a.uid).avatar, null);
});
test('widget snapshot stays schema1, adds only scoped current avatars and latest received message', async () => {
  const {a, b, outsider, pair} = await paired(), credential = await widget(b);
  const {profile} = await (await request('/profileAvatar', a, await picture(), 'PUT', 'image/jpeg')).json();
  const sent = await call('sendMessage', a, {...scope(pair), messageId: randomUUID(), text: 'Mensaje ficticio privado'});
  await call('sendMessage', b, {...scope(pair), messageId: randomUUID(), text: 'Respuesta ficticia'});
  const snapshot = await (await request('/widgetSnapshot', credential, undefined, 'GET')).json();
  assert.equal(snapshot.schemaVersion, 1); assert.equal(snapshot.note, null);
  assert.equal(snapshot.latestMessage.id, sent.message.id); assert.equal(snapshot.profiles.length, 2);
  assert.equal(snapshot.startedOn, null); assertNoPrivateKeys(snapshot);
  const avatar = await request(`/widgetAvatar?uid=${a.uid}&avatarId=${profile.avatar.id}`, credential, undefined, 'GET');
  assert.equal(avatar.status, 200); assert.equal(digest(Buffer.from(await avatar.arrayBuffer())), profile.avatar.sha256);
  assert.equal((await request(`/widgetAvatar?uid=${outsider.uid}`, credential, undefined, 'GET')).status, 403);
  await assert.rejects(call('getCoupleSpace', credential, scope(pair)), /authentication_required/);
  await assert.rejects(call('messages', credential, scope(pair)), /authentication_required/);
  await call('closePair', a, scope(pair));
  assert.equal((await request(`/widgetAvatar?uid=${a.uid}`, credential, undefined, 'GET')).status, 403);
  assert.equal((await request(`/profileAvatar?uid=${a.uid}`, b, undefined, 'GET')).status, 403);
});
test('short messages are idempotent, page correctly, deny outsiders and produce generic APNs after commit', async () => {
  const {a, b, outsider, pair} = await paired(), messageId = randomUUID(), text = 'Sólo una ficción de prueba';
  await call('registerDevice', b, {deviceId: randomUUID(), apnsToken: 'ab'.repeat(32), widgetPushToken: 'cd'.repeat(32), apnsEnvironment: 'development'});
  const input = {...scope(pair), messageId, text};
  const sent = await Promise.all([call('sendMessage', a, input), call('sendMessage', a, input)]);
  assert.deepEqual(sent[0], sent[1]);
  await assert.rejects(call('sendMessage', b, input), /idempotency_conflict/);
  await assert.rejects(call('sendMessage', a, {...input, text: 'otro'}), /idempotency_conflict/);
  await assert.rejects(call('sendMessage', outsider, input), /not_pair_member/);
  for (const value of ['', ' ', 'x'.repeat(501), 42]) await assert.rejects(call('sendMessage', a, {...input, text: value}), /invalid_message/);
  await call('sendMessage', b, {...scope(pair), messageId: randomUUID(), text: 'Segunda ficción'});
  const page = await call('messages', b, {...scope(pair), limit: 1});
  const next = await call('messages', b, {...scope(pair), limit: 1, cursor: page.nextCursor});
  assert.equal(page.messages.length, 1); assert.equal(next.messages.length, 1);
  assert.notEqual(page.messages[0].id, next.messages[0].id); assert.equal(next.nextCursor, null);
  await assert.rejects(call('messages', outsider, scope(pair)), /not_pair_member/);
  const eventId = digest(`${pair.id}:message:${messageId}`), sends = [];
  await db.doc(`notificationEvents/${eventId}`).update({nextAttemptAt: Timestamp.fromMillis(Date.now() - 1)});
  await dispatchNotification(db, eventId, {app: async (_token, payload) => {sends.push(payload);}, widget: async () => sends.push('widget')});
  assert.equal(sends.length, 2); assert.equal(sends[0].messageId, messageId); assert.equal(sends[0].type, 'message');
  assert.equal(sends[0].aps.alert.body, 'Tenés un mensaje nuevo'); assert.equal(JSON.stringify(sends).includes(text), false);
  const transport = new LivePushTransport(() => undefined), deliveries = [];
  transport.send = async (...args) => deliveries.push(args);
  await transport.app('fictional-token', {...sends[0], messageId: 'm'.repeat(128)}, 'development');
  assert.equal(deliveries[0][4].length, 64);
});
test('location requires explicit consent, registered source and generation; caller cannot supply another UID', async () => {
  const {a, b, outsider, pair} = await paired();
  assert.equal((await call('getCoupleSpace', a, scope(pair))).location.consentVersion, 0);
  const deviceId = randomUUID(); await call('registerDevice', a, {deviceId});
  await assert.rejects(sample(a, pair, {deviceId, consentVersion: 1}), /location_consent_required/);
  await assert.rejects(call('setLocationConsent', a, {...scope(pair), enabled: true, deviceId: 'unknown'}), /location_device_unavailable/);
  await assert.rejects(call('setLocationConsent', outsider, {...scope(pair), enabled: true, deviceId}), /not_pair_member/);
  const location = await consent(a, pair, deviceId);
  await sample(a, pair, location, {uid: b.uid});
  assert.equal((await db.doc(`locationPrivate/${b.uid}`).get()).exists, false);
  assert.equal((await call('getCoupleSpace', b, scope(pair))).location.distance.status, 'disabled');
  await assert.rejects(sample(a, pair, {...location, deviceId: 'other'}), /location_consent_required/);
  await assert.rejects(sample(a, pair, {...location, consentVersion: location.consentVersion + 1}), /location_consent_required/);
});
test('location validates coordinate bounds, precision, chronology, future time and replay', async () => {
  const {a, pair} = await paired(), location = await consent(a, pair);
  for (const values of [{latitude: 91}, {latitude: -91}, {longitude: 181}, {horizontalAccuracy: -1}, {horizontalAccuracy: 5001},
    {capturedAt: now + 60_001}, {capturedAt: now - 30 * 60_000}, {sequence: 1.5}]) {
    await assert.rejects(sample(a, pair, location, values), /invalid_/);
  }
  await sample(a, pair, location);
  await assert.rejects(sample(a, pair, location), /stale_location_sample/);
  await assert.rejects(sample(a, pair, location, {sequence: 2, capturedAt: now - 1}), /stale_location_sample/);
  await sample(a, pair, location, {sequence: 2, capturedAt: now + 1});
  assert.equal((await db.collection('locationPrivate').where('pairId', '==', pair.id).get()).size, 1);
});
test('distance is derived, rounded and fresh by the older sample; stale samples expire even before cleanup', async () => {
  const {a, b, pair} = await paired(), la = await consent(a, pair), lb = await consent(b, pair), credential = await widget(b);
  assert.equal((await call('getCoupleSpace', a, scope(pair))).location.distance.status, 'waiting');
  await sample(a, pair, la, {latitude: 0, longitude: 0, horizontalAccuracy: 50});
  await sample(b, pair, lb, {latitude: 0, longitude: 1, horizontalAccuracy: 100});
  const firstTime = now, current = await call('getCoupleSpace', a, scope(pair));
  assert.equal(current.location.distance.status, 'available'); assert.equal(current.location.distance.meters, 111200);
  assert.equal(current.location.distance.accuracyMeters, 200); assertNoPrivateKeys(current);
  now += 16 * 60_000;
  await sample(a, pair, la, {sequence: 2, latitude: 0, longitude: 0});
  const stale = await call('getCoupleSpace', a, scope(pair));
  assert.equal(stale.location.distance.status, 'stale'); assert.equal(stale.location.distance.updatedAt, firstTime);
  const widgetSnapshot = await (await request('/widgetSnapshot', credential, undefined, 'GET')).json();
  assert.equal(widgetSnapshot.validUntil, firstTime + 30 * 60_000); assertNoPrivateKeys(widgetSnapshot);
  now = firstTime + 30 * 60_000 + 1;
  const expired = await call('getCoupleSpace', b, scope(pair));
  assert.equal(expired.location.distance.meters, null); assert.equal(expired.location.distance.updatedAt, firstTime);
  assert.equal(expired.location.distance.status, 'stale');
  assert.equal((await db.doc(`locationPrivate/${b.uid}`).get()).exists, true);
  await service.couple.cleanup();
  assert.equal((await db.doc(`locationPrivate/${b.uid}`).get()).exists, false);
});
test('pausing erases samples and distance, keeps separate partner consent and fences a delayed update after re-enable', async () => {
  const {a, b, pair} = await paired(), la = await consent(a, pair), lb = await consent(b, pair);
  await sample(a, pair, la); await sample(b, pair, lb);
  await call('setLocationConsent', a, {...scope(pair), enabled: false});
  for (const uid of [a.uid, b.uid]) assert.equal((await db.doc(`locationPrivate/${uid}`).get()).exists, false);
  assert.equal((await db.doc(`pairs/${pair.id}/distance/current`).get()).exists, false);
  const other = await call('getCoupleSpace', b, scope(pair));
  assert.equal(other.location.sharingEnabled, true); assert.equal(other.location.distance.status, 'disabled');
  const reenabled = await consent(a, pair, la.deviceId);
  assert.ok(reenabled.consentVersion > la.consentVersion);
  await assert.rejects(sample(a, pair, la, {sequence: 2}), /location_consent_required/);
  assert.equal((await call('getCoupleSpace', a, scope(pair))).location.distance.status, 'waiting');
});
test('unregistering or transferring a location device revokes sharing and deletes all samples', async () => {
  const {a, b, outsider, pair} = await paired(), la = await consent(a, pair), lb = await consent(b, pair);
  await sample(a, pair, la); await sample(b, pair, lb);
  await call('unregisterDevice', a, {deviceId: la.deviceId});
  assert.equal((await call('getCoupleSpace', a, scope(pair))).location.sharingEnabled, false);
  assert.equal((await db.doc(`locationPrivate/${a.uid}`).get()).exists, false);
  const next = await consent(a, pair, la.deviceId); await sample(a, pair, next);
  await call('registerDevice', outsider, {deviceId: la.deviceId});
  assert.equal((await db.doc(`locationPrivate/${a.uid}`).get()).exists, false);
  await assert.rejects(sample(a, pair, next, {sequence: 2}), /location_consent_required|location_device_unavailable/);
});
test('closing a pair erases location consents/coordinates and denies old messages, memories, photos and widget scope', async () => {
  const {a, b, pair} = await paired(), la = await consent(a, pair), lb = await consent(b, pair), credential = await widget(b);
  await sample(a, pair, la); await sample(b, pair, lb);
  const item = await memory(a, pair); await request(photoPath(pair, item), a, await picture(), 'PUT', 'image/jpeg');
  await call('sendMessage', a, {...scope(pair), messageId: randomUUID(), text: 'Ficción antes de cierre'});
  await call('closePair', a, scope(pair));
  for (const uid of [a.uid, b.uid]) {
    assert.equal((await db.doc(`locationPrivate/${uid}`).get()).exists, false);
    assert.equal((await db.doc(`pairs/${pair.id}/locationConsent/${uid}`).get()).exists, false);
  }
  assert.equal((await db.doc(`pairs/${pair.id}/distance/current`).get()).exists, false);
  await assert.rejects(call('messages', b, scope(pair)), /not_pair_member/);
  await assert.rejects(call('memories', b, scope(pair)), /not_pair_member/);
  assert.equal((await request(photoPath(pair, item), b, undefined, 'GET')).status, 403);
  assert.equal((await request('/widgetSnapshot', credential, undefined, 'GET')).status, 403);
});
