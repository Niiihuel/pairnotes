const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID, randomBytes} = require('node:crypto');
const {S3Client, CreateBucketCommand} = require('@aws-sdk/client-s3');
const sharp = require('sharp');
const {Database, Timestamp} = require('../lib/database');
const {AssetStore} = require('../lib/assets');
const {PairNotesService, digest, fail} = require('../lib/service');
const {createHTTPApp} = require('../lib/http');
let db, service, s3, server, endpoint, now = Date.now();
const identities = new Map(), bucket = `pairnotes-wishes-${randomUUID()}`;
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
function input(pair, changes = {}) {
  return {...scope(pair), id: randomUUID(), requestId: randomUUID(), expectedRevision: 0,
    title: 'Un antojo compartido', category: 'other', notes: '', priceAmount: null, currencyCode: null, fulfilled: false, ...changes};
}
function edit(pair, wish, changes = {}) {return input(pair, {...wish, expectedRevision: wish.revision, ...changes});}
async function picture(color = '#db7093') {
  return sharp({create: {width: 480, height: 320, channels: 3, background: color}})
    .withMetadata({orientation: 6, exif: {IFD0: {Artist: 'Fictional metadata'}}}).jpeg().toBuffer();
}
function photoPath(pair, id, extra = {}) {return '/wishPhoto?' + new URLSearchParams({...scope(pair), id, ...extra});}
async function photo(user, pair, wish, bytes, requestId = randomUUID()) {
  const response = await request(photoPath(pair, wish.id, {expectedRevision: wish.revision, requestId}), user, bytes, 'PUT', 'image/jpeg');
  const body = await response.json(); if (!response.ok) throw Error(body.reason); return body.wish;
}
function assertPublic(value) {
  for (const [key, child] of Object.entries(value ?? {})) {
    assert.ok(!['path', 'paths', 'sourceSHA256', 'signature', 'deleted'].includes(key), `Private field ${key}`);
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

test('wishes preserve per-item currencies and exact decimals, both members edit and category-specific details clear', async () => {
  const {a, b, pair} = await paired();
  const beforeEvents = (await db.collection('notificationEvents').where('pairId', '==', pair.id).get()).size;
  const free = (await call('saveWish', a, input(pair))).wish;
  assert.equal(free.priceAmount, null); assert.equal(free.currencyCode, null);
  for (const currencyCode of ['MXN', 'ARS', 'USD', 'BRL', 'EUR', 'JPY']) {
    const created = (await call('saveWish', a, input(pair, {category: 'travel', priceAmount: '9999999999.1234', currencyCode,
      savedAmount: '42.5000', targetDate: '2028-02-29', location: 'Un destino', linkURL: 'https://example.test/viaje'}))).wish;
    assert.equal(created.priceAmount, '9999999999.1234'); assert.equal(created.savedAmount, '42.5');
    assert.equal(created.currencyCode, currencyCode); assert.equal(created.targetDate, '2028-02-29');
    assert.equal(created.pairId, pair.id); assert.equal(created.pairEpoch, pair.pairEpoch);
    const updated = (await call('saveWish', b, edit(pair, created, {fulfilled: true, category: 'gifts', recipient: 'Dany', occasion: 'Cumpleaños'}))).wish;
    assert.equal(updated.authorId, a.uid); assert.equal(updated.revision, 2); assert.equal(updated.savedAmount, null);
    assert.equal(updated.recipient, 'Dany'); assert.equal(updated.occasion, 'Cumpleaños');
    assert.ok(updated.updatedAt > created.updatedAt); assert.equal(updated.createdAt, created.createdAt); assertPublic(updated);
  }
  const list = await call('wishes', b, scope(pair));
  assert.equal(list.wishes.length, 7); assert.equal(list.limit, 200);
  assert.deepEqual(list, await call('wishes', a, scope(pair)));
  assert.equal((await db.collection('notificationEvents').where('pairId', '==', pair.id).get()).size, beforeEvents);
});

test('wish validation rejects partial prices, precision loss, unsupported currencies, unsafe links and invalid calendar dates', async () => {
  const {a, pair} = await paired();
  for (const change of [
    {title: ''}, {title: 'x'.repeat(121)}, {notes: 'x'.repeat(1001)}, {category: 'unknown'}, {fulfilled: 'false'},
    {id: '../escape'}, {requestId: 'invalid'}, {expectedRevision: -1}, {expectedRevision: 0.5},
    {priceAmount: '1'}, {currencyCode: 'USD'}, {priceAmount: 1, currencyCode: 'USD'},
    ...['-1', '01', '.5', '1e2', 'NaN', '10000000000', '1.12345'].map(priceAmount => ({priceAmount, currencyCode: 'USD'})),
    ...['usd', 'ZZZ', '', ' BTC'].map(currencyCode => ({priceAmount: '1', currencyCode})),
    ...['javascript:alert(1)', 'file:///tmp/a', 'https://user:password@example.test', 'not a link'].map(linkURL => ({linkURL})),
    ...['2026-02-29', '2026-04-31', '0000-01-01', '2026-1-1', '2026-01-01T00:00:00Z'].map(targetDate => ({targetDate})),
    {category: 'travel', savedAmount: '1'}, {category: 'food', foodKind: ['recipe']},
    {category: 'food', foodKind: 'recipe', ingredients: 'x'.repeat(6001)},
    {category: 'food', foodKind: 'recipe', instructions: 'x'.repeat(10001)}, {location: 'x'.repeat(241)}
  ]) {
    const response = await request('/saveWish', a, {data: input(pair, change)});
    assert.equal(response.status, 400, JSON.stringify(change).slice(0, 120));
  }
  const saved = (await call('saveWish', a, input(pair, {category: 'travel', priceAmount: '10.0000', savedAmount: '20', currencyCode: 'BRL'}))).wish;
  assert.equal(saved.priceAmount, '10'); assert.equal(saved.savedAmount, '20', 'Savings can exceed the target without currency conversion');
  assert.equal((await call('wishes', a, scope(pair))).wishes.length, 1);
});

test('wish recipe UTF-8 body accepts documented limits and changing food kind removes hidden recipe fields', async () => {
  const {a, b, pair} = await paired();
  const recipe = (await call('saveWish', a, input(pair, {category: 'food', foodKind: 'recipe',
    ingredients: 'é'.repeat(6000), instructions: '🍲'.repeat(5000)}))).wish;
  assert.equal(recipe.ingredients.length, 6000); assert.equal(recipe.instructions.length, 10000);
  const restaurant = (await call('saveWish', b, edit(pair, recipe, {foodKind: 'restaurant', location: 'Un restaurante', targetDate: '2026-12-31'}))).wish;
  assert.equal(restaurant.ingredients, ''); assert.equal(restaurant.instructions, '');
  assert.equal(restaurant.foodKind, 'restaurant'); assert.equal(restaurant.targetDate, '2026-12-31');
});

test('wish mutation retries are idempotent, concurrent edits conflict and old retries never overwrite newer changes', async () => {
  const {a, b, pair} = await paired(), firstInput = input(pair);
  const [one, repeated] = await Promise.all([call('saveWish', a, firstInput), call('saveWish', a, firstInput)]);
  assert.deepEqual(one, repeated); assert.equal(one.wish.revision, 1);
  await assert.rejects(call('saveWish', a, {...firstInput, title: 'Different'}), /idempotency_conflict/);
  await assert.rejects(call('saveWish', b, firstInput), /idempotency_conflict/);
  const edits = [edit(pair, one.wish, {title: 'First editor'}), edit(pair, one.wish, {title: 'Second editor'})];
  const results = await Promise.allSettled([call('saveWish', a, edits[0]), call('saveWish', b, edits[1])]);
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  assert.match(results.find(result => result.status === 'rejected').reason.message, /wish_revision_conflict/);
  const latest = (await call('getWish', a, {...scope(pair), id: one.wish.id})).wish;
  assert.equal(latest.revision, 2);
  assert.deepEqual((await call('saveWish', a, firstInput)).wish, latest);
  const remove = {...scope(pair), id: latest.id, requestId: randomUUID(), expectedRevision: latest.revision};
  assert.deepEqual(await call('deleteWish', b, remove), {}); assert.deepEqual(await call('deleteWish', b, remove), {});
  await assert.rejects(call('getWish', a, {...scope(pair), id: latest.id}), /wish_unavailable/);
  await assert.rejects(call('saveWish', a, firstInput), /wish_unavailable/);
  await assert.rejects(call('saveWish', a, {...firstInput, requestId: randomUUID()}), /wish_revision_conflict/);
  assert.equal((await call('wishes', a, scope(pair))).wishes.length, 0);
});

test('wish photos normalize metadata, stay private, honor revisions and retry without duplicate attachment', async () => {
  const {a, b, outsider, pair} = await paired(), original = (await call('saveWish', a, input(pair))).wish;
  const bytes = await picture(), requestId = randomUUID();
  const [uploaded, retried] = await Promise.all([photo(a, pair, original, bytes, requestId), photo(a, pair, original, bytes, requestId)]);
  assert.deepEqual(uploaded, retried); assert.equal(uploaded.revision, 2); assertPublic(uploaded);
  const getPath = photoPath(pair, original.id, {photoId: uploaded.photo.id});
  const response = await request(getPath, b, undefined, 'GET');
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'private, no-store');
  const png = Buffer.from(await response.arrayBuffer()), metadata = await sharp(png).metadata();
  assert.equal(metadata.format, 'png'); assert.equal(metadata.exif, undefined); assert.equal(metadata.orientation, undefined);
  assert.equal(metadata.width, 320); assert.equal(metadata.height, 480); assert.equal(digest(png), uploaded.photo.sha256);
  assert.equal((await request(getPath, outsider, undefined, 'GET')).status, 403);
  assert.equal((await request(getPath, undefined, undefined, 'GET')).status, 401);
  await assert.rejects(photo(a, pair, original, bytes), /wish_revision_conflict/);
  await assert.rejects(photo(a, pair, original, await picture('#000000'), requestId), /idempotency_conflict/);
  const removed = (await call('deleteWishPhoto', b, {...scope(pair), id: uploaded.id, requestId: randomUUID(), expectedRevision: uploaded.revision})).wish;
  assert.equal(removed.photo, null); assert.equal(removed.revision, 3);
  assert.equal((await request(getPath, a, undefined, 'GET')).status, 404);
  assert.deepEqual(await photo(a, pair, original, bytes, requestId), removed, 'Old successful upload retry must not restore a deleted photo');
  assert.equal((await db.doc(`privateImages/${uploaded.photo.id}`).get()).data().status, 'obsolete');
});

test('wish photo upload reauthorizes after S3 and closing the pair retires all wish photos and contents', async () => {
  const {a, b, pair} = await paired();
  const wish = await photo(a, pair, (await call('saveWish', a, input(pair))).wish, await picture());
  const original = service.couple.stageImage.bind(service.couple);
  service.couple.stageImage = async (...args) => {
    const staged = await original(...args);
    await call('closePair', b, scope(pair));
    return staged;
  };
  try {await assert.rejects(photo(a, pair, wish, await picture('#000000')), /not_pair_member/);}
  finally {service.couple.stageImage = original;}
  assert.equal((await db.collection(`pairs/${pair.id}/wishes`).get()).size, 0);
  assert.equal((await db.collection(`pairs/${pair.id}/wishRequests`).get()).size, 0);
  const images = (await db.collection('privateImages').where('ownerId', '==', a.uid).get()).docs.map(row => row.data());
  assert.equal(images.length, 2); assert.ok(images.every(image => image.status === 'obsolete'));
  now += 2 * 3600_000;
  for (let attempt = 0; attempt < 5; attempt++) await service.couple.cleanup();
  for (const image of images) assert.equal((await service.bucket.file(image.path).exists())[0], false);
  await assert.rejects(call('wishes', a, scope(pair)), /not_pair_member/);
});

test('wish photo download rechecks membership after private object IO', async () => {
  const {a, b, pair} = await paired();
  const wish = await photo(a, pair, (await call('saveWish', a, input(pair))).wish, await picture());
  const file = service.bucket.file.bind(service.bucket);
  service.bucket.file = path => {
    const value = file(path), download = value.download.bind(value);
    value.download = async () => {const bytes = await download(); await call('closePair', b, scope(pair)); return bytes;};
    return value;
  };
  try {assert.equal((await request(photoPath(pair, wish.id, {photoId: wish.photo.id}), a, undefined, 'GET')).status, 403);}
  finally {service.bucket.file = file;}
});

test('wishes require full app authentication and current pair epoch for every operation', async () => {
  const {a, b, outsider, pair} = await paired(), wish = (await call('saveWish', a, input(pair))).wish;
  const deviceId = randomUUID(); await call('registerDevice', b, {deviceId});
  const widget = await call('issueWidgetSession', b, {deviceId});
  for (const [name, data] of [['wishes', scope(pair)], ['getWish', {...scope(pair), id: wish.id}],
    ['saveWish', edit(pair, wish)], ['deleteWish', {...scope(pair), id: wish.id, requestId: randomUUID(), expectedRevision: wish.revision}],
    ['deleteWishPhoto', {...scope(pair), id: wish.id, requestId: randomUUID(), expectedRevision: wish.revision}]]) {
    assert.equal((await request('/' + name, undefined, {data})).status, 401);
    assert.equal((await request('/' + name, widget, {data})).status, 401);
    assert.equal((await request('/' + name, outsider, {data})).status, 403);
    assert.equal((await request('/' + name, a, {data: {...data, pairEpoch: pair.pairEpoch + 1}})).status, 403);
  }
});

test('wishlist is bounded at 200 active entries while deleting a wish permits one new entry', async () => {
  const {a, pair} = await paired(), wish = (await call('saveWish', a, input(pair))).wish;
  const source = (await db.doc(`pairs/${pair.id}/wishes/${wish.id}`).get()).data();
  await db.runTransaction(async tx => {
    for (let n = 1; n < 200; n++) {const id = randomUUID(); tx.create(db.doc(`pairs/${pair.id}/wishes/${id}`), {...source, id});}
  });
  assert.equal((await call('wishes', a, scope(pair))).wishes.length, 200);
  await assert.rejects(call('saveWish', a, input(pair)), /wish_limit/);
  await call('deleteWish', a, {...scope(pair), id: wish.id, requestId: randomUUID(), expectedRevision: wish.revision});
  await call('saveWish', a, input(pair));
  assert.equal((await call('wishes', a, scope(pair))).wishes.length, 200);
  assert.equal((await db.collection(`pairs/${pair.id}/wishes`).limit(201).get()).size, 201, 'Deleted tombstone stays excluded from the active limit');
});


test('wish metadata rate limit bounds request receipts and allows identical retry after its window', async () => {
  const {a, pair} = await paired(), payload = input(pair);
  const first = await call('saveWish', a, payload);
  for (let n = 1; n < 60; n++) assert.deepEqual(await call('saveWish', a, payload), first);
  for (const name of ['saveWish', 'deleteWish', 'deleteWishPhoto']) {
    const mutation = name === 'saveWish' ? edit(pair, first.wish) :
      {...scope(pair), id: first.wish.id, expectedRevision: first.wish.revision, requestId: randomUUID()};
    assert.equal((await request('/' + name, a, {data: mutation})).status, 429);
  }
  assert.equal((await db.collection(`pairs/${pair.id}/wishRequests`).get()).size, 1);
  now += 60_001;
  assert.deepEqual(await call('saveWish', a, payload), first);
  assert.equal((await call('saveWish', a, edit(pair, first.wish, {title: 'Después'}))).wish.revision, 2);
});

test('wish photo cannot attach over a concurrent metadata edit and changed photo cannot finish an old download', async () => {
  const {a, b, pair} = await paired(), wish = (await call('saveWish', a, input(pair))).wish;
  const stage = service.couple.stageImage.bind(service.couple);
  let latest;
  service.couple.stageImage = async (...args) => {
    const image = await stage(...args);
    latest = (await call('saveWish', b, edit(pair, wish, {title: 'Cambio concurrente'}))).wish;
    return image;
  };
  try {await assert.rejects(photo(a, pair, wish, await picture()), /wish_revision_conflict/);}
  finally {service.couple.stageImage = stage;}
  assert.equal(latest.photo, null);
  assert.equal((await db.collection('privateImages').where('ownerId', '==', a.uid).get()).docs[0].data().status, 'obsolete');
  latest = await photo(a, pair, latest, await picture());
  const originalID = latest.photo.id, file = service.bucket.file.bind(service.bucket);
  let replaced = false;
  service.bucket.file = path => {
    const value = file(path), download = value.download.bind(value);
    value.download = async () => {
      const bytes = await download();
      if (!replaced) {replaced = true; latest = await photo(b, pair, latest, await picture('#000000'));}
      return bytes;
    };
    return value;
  };
  try {assert.equal((await request(photoPath(pair, wish.id, {photoId: originalID}), a, undefined, 'GET')).status, 409);}
  finally {service.bucket.file = file;}
  assert.notEqual(latest.photo.id, originalID);
});
