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
test('couple changes push both widgets without alerts and cancelled pairs suppress queued refreshes', async () => {
  const {a, b, pair} = await paired();
  for (const user of [a, b]) await call('registerDevice', user, {deviceId: randomUUID(),
    apnsToken: randomUUID().replaceAll('-', ''), widgetPushToken: randomUUID().replaceAll('-', ''), apnsEnvironment: 'development'});
  await call('updatePairDetails', a, {...scope(pair), startedOn: '2024-01-01'});
  const events = await db.collection('notificationEvents').where('pairId', '==', pair.id).get();
  assert.equal(events.docs.length, 2);
  let alerts = 0, widgets = 0;
  const transport = {app: async () => {alerts++;}, widget: async () => {widgets++;}};
  for (const event of events.docs) {
    assert.equal(event.data().type, 'widget');
    await event.ref.update({nextAttemptAt: Timestamp.fromMillis(Date.now() - 1)});
    await dispatchNotification(db, event.id, transport);
    await dispatchNotification(db, event.id, transport);
  }
  assert.equal(alerts, 0); assert.equal(widgets, 2);
  await call('updatePairDetails', a, {...scope(pair), startedOn: '2024-02-01'});
  await db.doc(`pairs/${pair.id}`).update({status: 'closed'});
  const pending = await db.collection('notificationEvents').where('pairId', '==', pair.id).where('status', '==', 'pending').get();
  for (const event of pending.docs) {
    await event.ref.update({nextAttemptAt: Timestamp.fromMillis(Date.now() - 1)});
    await dispatchNotification(db, event.id, transport);
    assert.equal((await event.ref.get()).data().status, 'cancelled');
  }
  assert.equal(widgets, 2);
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
  assert.equal(widgetSnapshot.validUntil, now + 24 * 60 * 60_000);
  assert.equal(widgetSnapshot.distance.updatedAt, firstTime); assertNoPrivateKeys(widgetSnapshot);
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


test('shared personalization syncs to partner and widgets, rejects stale edits and invalid scope', async () => {
  const {a, b, outsider, pair} = await paired();
  const input = {...scope(pair), revision: 0, theme: 'lavender', phrase: 'Nuestro rincón',
    nicknames: {[a.uid]: 'Sol', [b.uid]: 'Luna'}, coverMemoryId: null,
    homeOrder: ['drawing', 'story', 'message', 'distance']};
  const result = await call('updatePersonalization', a, input);
  assert.equal(result.personalization.revision, 1);
  assert.deepEqual((await call('getCoupleSpace', b, scope(pair))).personalization, result.personalization);
  const credential = await widget(b);
  assert.deepEqual((await service.widgetSnapshot(credential.token)).personalization, result.personalization);
  await assert.rejects(call('updatePersonalization', b, {...input, phrase: 'stale'}), /personalization_changed/);
  await assert.rejects(call('updatePersonalization', outsider, {...input, revision: 1}), /not_pair_member/);
  await assert.rejects(call('updatePersonalization', a, {...input, pairEpoch: 99, revision: 1}), /stale_pair_epoch/);
  for (const changes of [{theme: 'unknown'}, {phrase: 'x'.repeat(161)}, {homeOrder: ['story', 'story', 'message', 'distance']},
    {revision: 1.5}, {nicknames: {[outsider.uid]: 'No'}}, {nicknames: {[a.uid]: 'x'.repeat(41)}}]) {
    await assert.rejects(call('updatePersonalization', a, {...input, revision: 1, ...changes}), /invalid_/);
  }
});

test('cover is an authorized album photo and scrapbook styles survive legacy edits', async () => {
  const {a, b, pair} = await paired();
  const decoration = {layout: 'postcard', sticker: 'flower'};
  const item = await memory(a, pair, {decoration});
  const input = {...scope(pair), revision: 0, theme: 'cream', phrase: '', nicknames: {}, coverMemoryId: item.id,
    homeOrder: ['story', 'message', 'drawing', 'distance']};
  await assert.rejects(call('updatePersonalization', a, input), /cover_unavailable/);
  assert.equal((await request(photoPath(pair, item), a, await picture(), 'PUT', 'image/jpeg')).status, 200);
  await call('updatePersonalization', a, input);
  const edited = await memory(b, pair, {memoryId: item.id, title: 'Una página nueva'});
  assert.deepEqual(edited.decoration, decoration);
  assert.equal((await call('getCoupleSpace', b, scope(pair))).personalization.coverMemoryId, item.id);
  for (const invalid of [null, {layout: 'bad', sticker: ''}, {layout: 'journal', sticker: 'bad'}]) {
    await assert.rejects(memory(a, pair, {decoration: invalid}), /invalid_decoration/);
  }
  assertNoPrivateKeys(await call('getCoupleSpace', b, scope(pair)));
});

test('undo restores exact memory and photo for either member, then expires without leaking assets', async () => {
  const {a, b, outsider, pair} = await paired();
  const item = await memory(a, pair, {body: 'Palabras', decoration: {layout: 'journal', sticker: 'heart'}});
  const uploaded = await request(photoPath(pair, item), a, await picture(), 'PUT', 'image/jpeg');
  assert.equal(uploaded.status, 200);
  const original = (await call('memories', a, scope(pair))).memories[0];
  const deletion = {...scope(pair), memoryId: item.id};
  await call('deleteMemory', a, deletion);
  assert.equal((await call('memories', b, scope(pair))).memories.length, 0);
  assert.equal((await request(photoPath(pair, item), b, undefined, 'GET')).status, 404);
  await assert.rejects(call('restoreMemory', outsider, deletion), /not_pair_member/);
  assert.deepEqual((await call('restoreMemory', b, deletion)).memory, original);
  assert.equal((await request(photoPath(pair, item), b, undefined, 'GET')).status, 200);
  await call('deleteMemory', a, deletion);
  now += 60_001;
  await assert.rejects(call('restoreMemory', a, deletion), /undo_expired/);
  await service.couple.cleanup();
  assert.equal((await db.doc(`privateImages/${original.photo.id}`).get()).data().status, 'obsolete');
  now += 3_600_001; await service.couple.cleanup();
  assert.equal((await db.doc(`privateImages/${original.photo.id}`).get()).data().status, 'deleted');
});

test('undo cannot overwrite a recreated page or reopen a closed pair', async () => {
  const {a, b, pair} = await paired(), item = await memory(a, pair);
  const input = {...scope(pair), memoryId: item.id};
  await call('deleteMemory', a, input);
  await memory(a, pair, {memoryId: item.id, title: 'Recreado'});
  await assert.rejects(call('restoreMemory', b, input), /memory_exists/);
  assert.equal((await call('memories', b, scope(pair))).memories[0].title, 'Recreado');
  await call('closePair', a, scope(pair));
  await assert.rejects(call('restoreMemory', b, input), /not_pair_member/);
});


function voiceFixture(seconds = 1) {
  const count = Math.round(seconds * 16000) * 2, bytes = Buffer.alloc(44 + count);
  bytes.write('RIFF'); bytes.writeUInt32LE(36 + count, 4); bytes.write('WAVEfmt ', 8); bytes.writeUInt32LE(16, 16);
  bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(16000, 24); bytes.writeUInt32LE(32000, 28);
  bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34); bytes.write('data', 36); bytes.writeUInt32LE(count, 40);
  return bytes;
}
async function letterDraft(a, pair, extra = {}) {
  return (await call('saveLetterDraft', a, {...scope(pair), letterId: randomUUID(), title: 'Sorpresa secreta',
    body: 'Estas palabras esperan', opensAt: now + 86400_000, noteId: null, ...extra})).letter;
}
const letterPath = (pair, letter, role, assetId = '') => `/letter${role === 'photo' ? 'Photo' : role === 'drawing' ? 'Drawing' : 'Audio'}?pairId=${pair.id}&pairEpoch=${pair.pairEpoch}&letterId=${letter.id}&assetId=${assetId}`;

test('gestures are idempotent, private, replyable and appear in widgets', async () => {
  const {a, b, outsider, pair} = await paired();
  const input = {...scope(pair), gestureId: randomUUID(), kind: 'hug', replyTo: null};
  const [first, retry] = await Promise.all([call('sendGesture', a, input), call('sendGesture', a, input)]);
  assert.deepEqual(first, retry);
  assert.deepEqual((await call('getCoupleSpace', b, scope(pair))).latestGesture, first.gesture);
  const credentials = await widget(b);
  assert.deepEqual((await service.widgetSnapshot(credentials.token)).latestGesture, first.gesture);
  const reply = await call('sendGesture', b, {...input, gestureId: randomUUID(), kind: 'kiss', replyTo: input.gestureId});
  assert.equal(reply.gesture.recipientId, a.uid);
  assert.equal(reply.gesture.replyTo, input.gestureId);
  await assert.rejects(call('sendGesture', a, {...input, kind: 'heart'}), /idempotency_conflict/);
  await assert.rejects(call('sendGesture', outsider, {...input, gestureId: randomUUID()}), /not_pair_member/);
  await assert.rejects(call('sendGesture', a, {...input, gestureId: randomUUID(), replyTo: input.gestureId}), /gesture_unavailable/);
  await assert.rejects(call('sendGesture', a, {...input, gestureId: randomUUID(), kind: 'bad'}), /invalid_gesture/);
  const events = await db.collection('notificationEvents').where('pairId', '==', pair.id).where('type', '==', 'gesture').get();
  assert.equal(events.size, 2);
});

test('drawing reactions authorize recipient, update without duplicate push and support removal', async () => {
  const {a, b, outsider, pair} = await paired(), noteId = randomUUID();
  await db.doc(`pairs/${pair.id}/notes/${noteId}`).create({id: noteId, authorId: a.uid, recipientId: b.uid});
  const input = {...scope(pair), noteId, kind: 'heart', reply: 'Me encantó'};
  const first = await call('setReaction', b, input);
  assert.deepEqual(await call('setReaction', b, input), first);
  assert.deepEqual(await call('reactions', a, {...scope(pair), noteId}), first);
  await assert.rejects(call('setReaction', a, input), /not_note_recipient/);
  await assert.rejects(call('reactions', outsider, input), /not_pair_member/);
  await assert.rejects(call('setReaction', b, {...input, reply: 'x'.repeat(281)}), /invalid_text/);
  assert.equal((await db.collection('notificationEvents').where('pairId', '==', pair.id).where('type', '==', 'reaction').get()).size, 1);
  await call('setReaction', b, {...input, kind: '', reply: ''});
  assert.deepEqual((await call('reactions', a, {...scope(pair), noteId})).reactions, []);
});

test('letters never expose content or asset IDs before server opening time, including direct asset routes', async () => {
  const {a, b, outsider, pair} = await paired(), draft = await letterDraft(a, pair);
  const base = {...scope(pair), letterId: draft.id};
  assert.deepEqual((await call('letters', b, scope(pair))).letters, []);
  await assert.rejects(call('openLetter', b, base), /letter_unavailable/);
  assert.equal((await request(letterPath(pair, draft, 'photo'), a, await picture(), 'PUT', 'image/jpeg')).status, 200);
  assert.equal((await request(letterPath(pair, draft, 'audio'), a, voiceFixture(), 'PUT', 'audio/wav')).status, 200);
  assert.equal((await request(letterPath(pair, draft, 'drawing'), a, await picture(), 'PUT', 'image/jpeg')).status, 200);
  const {letter: sealed} = await call('sealLetter', a, base);
  assert.equal(sealed.audio.duration, 1);
  assert.equal(sealed.canOpen, false);
  assert.deepEqual((await call('sealLetter', a, base)).letter, sealed);
  const locked = (await call('letters', b, {...scope(pair), now: now + 999999999})).letters[0];
  for (const field of ['title', 'body', 'photo', 'drawing', 'audio', 'noteId']) assert.ok(!(field in locked));
  await assert.rejects(call('openLetter', b, {...base, opensAt: 0}), /letter_locked/);
  await assert.rejects(call('openLetter', outsider, base), /not_pair_member/);
  assert.equal((await request(letterPath(pair, draft, 'photo', sealed.photo.id), b, undefined, 'GET')).status, 403);
  assert.equal((await request(letterPath(pair, draft, 'audio', sealed.audio.id), b, undefined, 'GET')).status, 403);
  if (sealed.drawing) assert.equal((await request(letterPath(pair, draft, 'drawing', sealed.drawing.id), b, undefined, 'GET')).status, 403);
  assert.equal((await request(letterPath(pair, draft, 'photo', sealed.photo.id), a, undefined, 'GET')).status, 200);
  const credentials = await widget(b);
  const snapshot = await service.widgetSnapshot(credentials.token);
  assert.ok(!JSON.stringify(snapshot).includes('Sorpresa secreta'));
  assert.equal((await fetch(endpoint + letterPath(pair, draft, 'audio', sealed.audio.id), {headers: {authorization: `Bearer ${credentials.token}`}})).status, 401);
  now = draft.opensAt;
  const {letter: opened} = await call('openLetter', b, base);
  assert.equal(opened.title, draft.title); assert.equal(opened.body, draft.body); assert.equal(opened.canOpen, true); assert.equal(opened.openedAt, now);
  assert.equal((await request(letterPath(pair, draft, 'audio', sealed.audio.id), b, undefined, 'GET')).status, 200);
  assert.equal((await request(letterPath(pair, draft, 'photo', sealed.photo.id), b, undefined, 'GET')).status, 200);
  assert.equal((await request(letterPath(pair, draft, 'drawing', sealed.drawing.id), b, undefined, 'GET')).status, 200);
  assertNoPrivateKeys(opened);
});

test('sealed letters are immutable, malformed or excessive audio fails and pair closure revokes attachments', async () => {
  const {a, b, pair} = await paired(), draft = await letterDraft(a, pair);
  const base = {...scope(pair), letterId: draft.id};
  assert.equal((await request(letterPath(pair, draft, 'audio'), a, Buffer.from('not audio'), 'PUT', 'audio/wav')).status, 400);
  assert.equal((await request(letterPath(pair, draft, 'audio'), a, voiceFixture(61), 'PUT', 'audio/wav')).status, 400);
  const stereo = voiceFixture(); stereo.writeUInt16LE(2, 22);
  assert.equal((await request(letterPath(pair, draft, 'audio'), a, stereo, 'PUT', 'audio/wav')).status, 400);
  assert.equal((await request(letterPath(pair, draft, 'audio'), b, voiceFixture(), 'PUT', 'audio/wav')).status, 404);
  await request(letterPath(pair, draft, 'audio'), a, voiceFixture(), 'PUT', 'audio/wav');
  const sealed = (await call('sealLetter', a, base)).letter;
  await assert.rejects(letterDraft(a, pair, {letterId: draft.id}), /letter_sealed/);
  await assert.rejects(call('deleteLetterDraft', a, base), /letter_sealed/);
  await assert.rejects(call('removeLetterAsset', a, {...base, role: 'audio'}), /letter_sealed/);
  assert.equal((await request(letterPath(pair, draft, 'audio'), a, voiceFixture(), 'PUT', 'audio/wav')).status, 403);
  await call('closePair', a, scope(pair));
  now = draft.opensAt + 1;
  await assert.rejects(call('openLetter', b, base), /not_pair_member/);
  assert.equal((await request(letterPath(pair, draft, 'audio', sealed.audio.id), b, undefined, 'GET')).status, 403);
  if (sealed.drawing) assert.equal((await request(letterPath(pair, draft, 'drawing', sealed.drawing.id), b, undefined, 'GET')).status, 403);
});

test('letter opening notification waits for server time, is generic and is not duplicated on seal retry', async () => {
  const {a, b, pair} = await paired();
  await call('registerDevice', b, {deviceId: randomUUID(), apnsToken: 'a'.repeat(64), apnsEnvironment: 'development'});
  const letter = await letterDraft(a, pair, {opensAt: now + 60000});
  const input = {...scope(pair), letterId: letter.id};
  await call('sealLetter', a, input); await call('sealLetter', a, input);
  const rows = await db.collection('notificationEvents').where('pairId', '==', pair.id).where('type', '==', 'letter').get();
  assert.equal(rows.size, 1);
  const payloads = [], transport = {app: async (_token, payload) => {payloads.push(payload);}, widget: async () => {}};
  await dispatchNotification(db, rows.docs[0].id, transport, () => now);
  assert.equal(payloads.length, 0);
  now = letter.opensAt;
  await dispatchNotification(db, rows.docs[0].id, transport, () => now);
  assert.equal(payloads.length, 1); assert.equal(payloads[0].type, 'letter'); assert.equal(payloads[0].letterId, letter.id);
  assert.ok(!JSON.stringify(payloads).includes(letter.body)); assert.ok(!JSON.stringify(payloads).includes(letter.title));
  await dispatchNotification(db, rows.docs[0].id, transport, () => now);
  assert.equal(payloads.length, 1);
});

test('letter draft ownership, validation and asset cleanup are enforced', async () => {
  const {a, b, outsider, pair} = await paired();
  await assert.rejects(letterDraft(a, pair, {title: ' '}), /invalid_text/);
  await assert.rejects(letterDraft(a, pair, {body: 'x'.repeat(6001)}), /invalid_text/);
  await assert.rejects(letterDraft(a, pair, {opensAt: now + 10 * 366 * 86400_000}), /invalid_opening_date/);
  await assert.rejects(letterDraft(a, pair, {noteId: randomUUID()}), /note_unavailable/);
  const draft = await letterDraft(a, pair, {body: '', opensAt: now + 60000}), base = {...scope(pair), letterId: draft.id};
  await assert.rejects(call('sealLetter', a, base), /empty_letter/);
  await assert.rejects(call('sealLetter', b, base), /letter_unavailable/);
  await assert.rejects(call('letters', outsider, scope(pair)), /not_pair_member/);
  await request(letterPath(pair, draft, 'audio'), a, voiceFixture(), 'PUT', 'audio/wav');
  const attached = (await call('openLetter', a, base)).letter.audio;
  await call('removeLetterAsset', a, {...base, role: 'audio'});
  assert.equal((await db.doc(`privateImages/${attached.id}`).get()).data().status, 'obsolete');
  await call('deleteLetterDraft', a, base);
  await assert.rejects(call('openLetter', a, base), /letter_unavailable/);
});
