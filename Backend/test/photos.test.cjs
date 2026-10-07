const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID, randomBytes} = require('node:crypto');
const {S3Client, CreateBucketCommand} = require('@aws-sdk/client-s3');
const sharp = require('sharp');
const {Database, Timestamp} = require('../lib/database');
const {AssetStore} = require('../lib/assets');
const {PairNotesService, digest, fail} = require('../lib/service');
const {createHTTPApp} = require('../lib/http');
const {dispatchNotification} = require('../lib/notifications');
let db, service, s3, server, endpoint, now = Date.now();
const identities = new Map(), bucket = `pairnotes-photos-${randomUUID()}`;
const auth = {authenticate: async token => identities.get(token) ?? fail('authentication_required', 'unauthenticated')};
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
  const invite = await call('createInvite', a), {pair} = await call('acceptInvite', b, {token: invite.token});
  return {a, b, outsider, pair};
}
async function picture(color = '#db7093') {
  return sharp({create: {width: 480, height: 320, channels: 3, background: color}})
    .withMetadata({orientation: 6, exif: {IFD0: {Artist: 'Fictional metadata'}}}).jpeg().toBuffer();
}
async function widget(user) {
  const deviceId = randomUUID(); await call('registerDevice', user, {deviceId});
  return {...await call('issueWidgetSession', user, {deviceId}), deviceId};
}
const photoPath = (pair, photoId, caption = '') => `/couplePhoto?pairId=${pair.id}&pairEpoch=${pair.pairEpoch}&photoId=${photoId}&caption=${encodeURIComponent(caption)}`;
async function send(user, pair, id, bytes, caption = '') {
  const response = await request(photoPath(pair, id, caption), user, bytes, 'PUT', 'image/jpeg');
  const body = await response.json(); if (!response.ok) throw Error(body.reason); return body.photo;
}
function assertPublic(value) {
  for (const [key, child] of Object.entries(value ?? {})) {
    assert.ok(!['path', 'paths', 'sourceSHA256', 'latitude', 'longitude'].includes(key), `Private field ${key}`);
    if (child && typeof child === 'object') assertPublic(child);
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

test('photo publication is idempotent under concurrency, private and independent of memories', async () => {
  const {a, b, outsider, pair} = await paired(), id = randomUUID(), bytes = await picture();
  const [first, second] = await Promise.all([send(a, pair, id, bytes, 'Para vos'), send(a, pair, id, bytes, 'Para vos')]);
  assert.deepEqual(first, second); assertPublic(first);
  assert.equal((await db.collection(`pairs/${pair.id}/photos`).get()).size, 1);
  assert.equal((await db.collection(`pairs/${pair.id}/memories`).get()).size, 0);
  assert.equal((await db.collection('notificationEvents').where('pairId', '==', pair.id).get()).size, 1);
  await assert.rejects(send(b, pair, id, bytes, 'Para vos'), /idempotency_conflict/);
  await assert.rejects(send(a, pair, id, bytes, 'Otro'), /idempotency_conflict/);
  await assert.rejects(send(a, pair, id, await picture('#000000'), 'Para vos'), /idempotency_conflict/);
  await assert.rejects(send(outsider, pair, randomUUID(), bytes), /not_pair_member/);
  await assert.rejects(send(a, {...pair, pairEpoch: 99}, randomUUID(), bytes), /stale_pair_epoch/);
  await assert.rejects(send(a, pair, randomUUID(), Buffer.from('invalid')), /invalid_image/);
  assert.equal((await call('getPhoto', b, {...scope(pair), photoId: id})).photo.id, id);
  await assert.rejects(call('getPhoto', outsider, {...scope(pair), photoId: id}), /not_pair_member/);
  const downloaded = await request(photoPath(pair, id) + `&assetId=${first.photo.id}`, b, undefined, 'GET');
  assert.equal(downloaded.status, 200); assert.equal(downloaded.headers.get('cache-control'), 'private, no-store');
  const png = Buffer.from(await downloaded.arrayBuffer()), metadata = await sharp(png).metadata();
  assert.equal(digest(png), first.photo.sha256); assert.equal(metadata.format, 'png');
  assert.equal(metadata.exif, undefined); assert.equal(metadata.orientation, undefined);
  assert.equal(metadata.width, 320); assert.equal(metadata.height, 480);
});

test('widget exposes only latest received photo, denies history and invalidates credentials and stale buttons', async () => {
  const {a, b, outsider, pair} = await paired(), credential = await widget(b), id = randomUUID();
  const first = await send(a, pair, id, await picture(), 'Texto privado de prueba');
  await send(b, pair, randomUUID(), await picture());
  const snapshot = await (await request('/widgetSnapshot', credential, undefined, 'GET')).json();
  assert.equal(snapshot.latestPhoto.id, id); assertPublic(snapshot);
  assert.equal((await call('getCoupleSpace', b, scope(pair))).latestPhoto.id, id);
  const imagePath = `/widgetPhoto?photoId=${id}&assetId=${first.photo.id}`;
  assert.equal((await request(imagePath, credential, undefined, 'GET')).status, 200);
  assert.equal((await request(imagePath, {token: outsider.token}, undefined, 'GET')).status, 401);
  assert.equal((await request(photoPath(pair, id), credential, undefined, 'GET')).status, 401);
  await assert.rejects(call('getPhoto', credential, {...scope(pair), photoId: id}), /authentication_required/);
  const input = {photoId: id, assetId: first.photo.id, kind: 'heart'};
  const reacted = await request('/widgetPhotoReaction', credential, input);
  assert.equal(reacted.status, 200); const reaction = await reacted.json();
  assert.equal(reaction.reaction.authorId, b.uid); assert.equal(reaction.photo.reaction.kind, 'heart');
  const events = (await db.collection('notificationEvents').where('pairId', '==', pair.id).get()).size;
  assert.equal((await request('/widgetPhotoReaction', credential, input)).status, 200);
  assert.equal((await db.collection('notificationEvents').where('pairId', '==', pair.id).get()).size, events);
  for (const kind of ['laugh', 'fire', 'tear']) {
    assert.equal((await request('/widgetPhotoReaction', credential, {...input, kind})).status, 200);
  }
  assert.equal((await request('/widgetPhotoReaction', credential, {...input, kind: 'unknown'})).status, 400);
  assert.equal((await request('/widgetPhotoReaction', credential, {...input, assetId: randomUUID()})).status, 409);
  await assert.rejects(call('setPhotoReaction', a, {...scope(pair), ...input}), /not_photo_recipient/);
  await send(a, pair, randomUUID(), await picture());
  assert.equal((await request(imagePath, credential, undefined, 'GET')).status, 409);
  assert.equal((await request('/widgetPhotoReaction', credential, input)).status, 409);
  // The app may still react to an older received photo through its full session.
  assert.equal((await call('setPhotoReaction', b, {...scope(pair), ...input})).reaction.kind, 'heart');
  const rotated = await call('issueWidgetSession', b, {deviceId: credential.deviceId});
  assert.equal((await request('/widgetPhotoReaction', credential, input)).status, 401);
  await call('closePair', a, scope(pair));
  assert.equal((await request('/widgetSnapshot', rotated, undefined, 'GET')).status, 403);
  assert.equal((await request(photoPath(pair, id), b, undefined, 'GET')).status, 403);
});

test('photo pushes are generic and photo reactions notify the sender after commit', async () => {
  const {a, b, pair} = await paired();
  for (const member of [a, b]) await call('registerDevice', member, {deviceId: randomUUID(), apnsToken: randomBytes(32).toString('hex'),
    widgetPushToken: randomBytes(32).toString('hex'), apnsEnvironment: 'development'});
  const photo = await send(a, pair, randomUUID(), await picture(), 'Private fictional caption');
  const eventId = digest(`${pair.id}:photo:${photo.id}`), deliveries = [];
  await db.doc(`notificationEvents/${eventId}`).update({nextAttemptAt: Timestamp.fromMillis(Date.now() - 1)});
  await dispatchNotification(db, eventId, {app: async (_token, payload) => deliveries.push(payload), widget: async () => deliveries.push('widget')});
  assert.equal(deliveries.length, 2); assert.equal(deliveries[0].type, 'photo'); assert.equal(deliveries[0].photoId, photo.id);
  assert.equal(deliveries[0].aps.alert.body, 'Tenés una foto nueva');
  assert.equal(JSON.stringify(deliveries).includes(photo.caption), false); assertPublic(deliveries[0]);
  await call('setPhotoReaction', b, {...scope(pair), photoId: photo.id, assetId: photo.photo.id, kind: 'tear'});
  const events = await db.collection('notificationEvents').where('pairId', '==', pair.id).where('type', '==', 'photo-reaction').get();
  assert.equal(events.size, 1); assert.equal(events.docs[0].data().recipientId, a.uid);
  await events.docs[0].ref.update({nextAttemptAt: Timestamp.fromMillis(Date.now() - 1)});
  await dispatchNotification(db, events.docs[0].id, {app: async (_token, payload) => deliveries.push(payload), widget: async () => {}});
  assert.equal(deliveries.at(-1).type, 'photo-reaction');
  assert.equal(deliveries.at(-1).aps.alert.body, 'Tu pareja reaccionó a tu foto');
});

test('widget credential rotation between snapshot authorization and reaction cannot commit a stale button', async () => {
  const {a, b, pair} = await paired(), credential = await widget(b);
  const photo = await send(a, pair, randomUUID(), await picture());
  const original = service.photos.setReaction.bind(service.photos);
  let rotated = false;
  service.photos.setReaction = async (...args) => {
    if (!rotated) {
      rotated = true;
      await call('issueWidgetSession', b, {deviceId: credential.deviceId});
    }
    return original(...args);
  };
  try {
    const response = await request('/widgetPhotoReaction', credential, {photoId: photo.id, assetId: photo.photo.id, kind: 'heart'});
    assert.equal(response.status, 401);
    assert.equal((await call('getPhoto', b, {...scope(pair), photoId: photo.id})).photo.reaction, null);
    assert.equal((await db.collection('notificationEvents').where('pairId', '==', pair.id).where('type', '==', 'photo-reaction').get()).size, 0);
  } finally {service.photos.setReaction = original;}
});
