const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID, randomBytes} = require('node:crypto');
const {Database, Timestamp} = require('../lib/database');
const {PairNotesService, fail} = require('../lib/service');
const {createHTTPApp} = require('../lib/http');
let db, service, server, endpoint, now = Date.now();
const identities = new Map();
const auth = {authenticate: async token => identities.get(token) ?? fail('authentication_required', 'unauthenticated')};
const scope = pair => ({pairId: pair.id, pairEpoch: pair.pairEpoch});
async function request(name, user, data) {
  return fetch(endpoint + '/' + name, {method: 'POST', headers: {'content-type': 'application/json',
    ...(user ? {authorization: `Bearer ${user.token}`} : {})}, body: JSON.stringify({data})});
}
async function call(name, user, data = {}) {
  const response = await request(name, user, data), body = await response.json();
  assert.equal(response.headers.get('cache-control'), 'private, no-store');
  if (!response.ok) throw Error(body.error?.details?.reason ?? body.reason);
  return body.result;
}
async function user() {
  const user = {uid: randomUUID(), token: randomBytes(32).toString('base64url')};
  identities.set(user.token, {uid: user.uid, authTime: Math.floor(now / 1000)});
  await call('upsertProfile', user, {displayName: 'Perfil sintético'});
  return user;
}
async function paired() {
  now = Date.now();
  const a = await user(), b = await user(), outsider = await user();
  const invitation = await call('createInvite', a), {pair} = await call('acceptInvite', b, {token: invitation.token});
  return {a, b, outsider, pair};
}
async function targets(a, b, pair) {
  const messageId = randomUUID();
  await call('sendMessage', a, {...scope(pair), messageId, text: 'Texto sintético privado'});
  const photoId = randomUUID(), noteId = randomUUID(), letterId = randomUUID(), audioId = randomUUID();
  // These fixtures require no object storage: reactions authorize metadata only.
  const base = {pairId: pair.id, pairEpoch: pair.pairEpoch, authorId: a.uid, recipientId: b.uid};
  await db.doc(`pairs/${pair.id}/photos/${photoId}`).create({...base, id: photoId, caption: 'Foto privada',
    photo: {id: randomUUID(), sha256: 'a'.repeat(64), path: 'private/not-read'}, sentAt: Timestamp.fromMillis(now), reaction: null});
  await db.doc(`pairs/${pair.id}/notes/${noteId}`).create({...base, id: noteId, publishedAt: Timestamp.fromMillis(now), title: 'Dibujo privado'});
  for (const [id, body, audio] of [[letterId, 'Carta privada', null], [audioId, '', {id: randomUUID(), path: 'private/not-read', sha256: 'b'.repeat(64), duration: 1}]]) {
    await call('saveLetterDraft', a, {...scope(pair), letterId: id, title: 'Mensaje', body, opensAt: now + 60_000});
    if (audio) await db.doc(`pairs/${pair.id}/letters/${id}`).update({audio});
    await call('sealLetter', a, {...scope(pair), letterId: id, immediate: true});
  }
  return [{targetType: 'message', targetId: messageId}, {targetType: 'photo', targetId: photoId},
    {targetType: 'drawing', targetId: noteId}, {targetType: 'letter', targetId: letterId}, {targetType: 'letter', targetId: audioId}];
}
const get = (user, pair, targets) => call('getChatReactions', user, {...scope(pair), targets});
const set = (user, pair, target, kind, extra = {}) => call('setChatReaction', user, {...scope(pair), ...target, kind, ...extra});
function assertPublic(value) {
  const json = JSON.stringify(value);
  for (const secret of ['caption', 'photo', 'path', 'body', 'title', 'audio', 'sourceSHA256', 'pairId', 'pairEpoch']) {
    assert.equal(new RegExp(`"${secret}"\\s*:`).test(json), false, `Private field ${secret} must not be returned`);
  }
}
before(async () => {
  assert.ok(['localhost', '127.0.0.1', 'postgres'].includes(new URL(process.env.DATABASE_URL).hostname));
  db = new Database(process.env.DATABASE_URL); await db.migrate();
  service = new PairNotesService(db, {}, () => now);
  server = createHTTPApp({service, auth}).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve)); endpoint = `http://127.0.0.1:${server.address().port}`;
});
after(async () => {if (server) await new Promise(resolve => server.close(resolve)); await db?.terminate();});

test('both actors react to all chat content, including audio, independently of legacy reactions and alerts', async () => {
  const {a, b, pair} = await paired(), items = await targets(a, b, pair);
  const events = (await db.collection('notificationEvents').where('pairId', '==', pair.id).get()).size;
  assert.deepEqual(await get(b, pair, items), {reactions: []});
  for (const item of items) {
    const own = await set(a, pair, item, 'heart', {authorId: b.uid});
    assert.equal(own.reaction.authorId, a.uid, 'The authenticated caller owns the reaction');
    assert.equal(own.reaction.targetType, item.targetType); assert.equal(own.reaction.targetId, item.targetId);
    const reply = await set(b, pair, item, 'thumbsUp');
    assert.equal(reply.reactions.length, 2); assert.equal(reply.reaction.authorId, b.uid);
    assertPublic(reply);
  }
  const batch = await get(a, pair, [...items, items[0]]);
  assert.equal(batch.reactions.length, 10); assertPublic(batch);
  assert.equal((await db.collection(`pairs/${pair.id}/chatReactions`).get()).size, 10);
  assert.equal((await db.doc(`pairs/${pair.id}/photos/${items[1].targetId}`).get()).data().reaction, null);
  assert.equal((await call('reactions', b, {...scope(pair), noteId: items[2].targetId})).reactions.length, 0);
  assert.equal((await db.collection('notificationEvents').where('pairId', '==', pair.id).get()).size, events);
});

test('same-kind concurrent retries preserve timestamps and replacing/removing only affects that actor', async () => {
  const {a, b, pair} = await paired(), [item] = await targets(a, b, pair);
  const [first, retried] = await Promise.all([set(b, pair, item, 'heart'), set(b, pair, item, 'heart')]);
  assert.deepEqual(first, retried);
  now += 1000;
  assert.deepEqual(await set(b, pair, item, 'heart'), first);
  await set(a, pair, item, 'surprised');
  const changed = await set(b, pair, item, 'laugh');
  assert.equal(changed.reaction.kind, 'laugh'); assert.ok(changed.reaction.updatedAt > first.reaction.updatedAt);
  assert.equal(changed.reactions.length, 2);
  const removed = await set(b, pair, item, null);
  assert.equal(removed.reaction, null); assert.equal(removed.reactions.length, 1); assert.equal(removed.reactions[0].authorId, a.uid);
  assert.deepEqual(await set(b, pair, item, null), removed);
  assert.deepEqual((await get(b, pair, [item])).reactions, removed.reactions);
});

test('future letters expose no reactions to the recipient until opening; drafts and missing targets are indistinguishable', async () => {
  const {a, b, pair} = await paired(), letterId = 'legacy-scheduled-letter', draftId = randomUUID();
  for (const id of [letterId, draftId]) await call('saveLetterDraft', a, {...scope(pair), letterId: id,
    title: 'Secreto', body: 'Contenido invisible', opensAt: now + 60_000});
  await call('sealLetter', a, {...scope(pair), letterId});
  const item = {targetType: 'letter', targetId: letterId}, draft = {...item, targetId: draftId}, missing = {...item, targetId: randomUUID()};
  await set(a, pair, item, 'fire');
  assert.equal((await get(a, pair, [item])).reactions.length, 1);
  assert.deepEqual(await get(b, pair, [item, draft, missing]), {reactions: []});
  assert.deepEqual(await get(a, pair, [draft]), {reactions: []});
  for (const target of [item, draft, missing]) await assert.rejects(set(b, pair, target, 'heart'), /target_unavailable/);
  await assert.rejects(set(a, pair, draft, 'heart'), /target_unavailable/);
  now += 60_000;
  assert.equal((await get(b, pair, [item])).reactions.length, 1);
  assert.equal((await set(b, pair, item, 'tear')).reactions.length, 2);
  assertPublic(await get(b, pair, [item]));
});

test('pair/epoch, content participants, wrong types and closed relationships isolate both reads and mutations', async () => {
  const {a, b, outsider, pair} = await paired(), items = await targets(a, b, pair), [item] = items;
  await set(a, pair, item, 'heart');
  for (const name of ['getChatReactions', 'setChatReaction']) {
    const input = {...scope(pair), ...item, kind: 'heart', targets: items};
    assert.equal((await request(name, null, input)).status, 401);
    await assert.rejects(call(name, outsider, input), /not_pair_member/);
    await assert.rejects(call(name, a, {...input, pairEpoch: 99}), /stale_pair_epoch/);
  }
  const other = await paired();
  assert.deepEqual(await get(other.a, other.pair, items), {reactions: []});
  await assert.rejects(set(other.a, other.pair, item, 'heart'), /target_unavailable/);
  await assert.rejects(set(b, pair, {...item, targetType: 'photo'}, 'heart'), /target_unavailable/);
  await db.doc(`pairs/${pair.id}/messages/${item.targetId}`).update({recipientId: outsider.uid});
  assert.deepEqual(await get(a, pair, [item]), {reactions: []});
  await assert.rejects(set(a, pair, item, 'fire'), /target_unavailable/);
  await db.doc(`pairs/${pair.id}/messages/${item.targetId}`).update({recipientId: b.uid});
  await set(a, pair, items[3], 'fire');
  await db.doc(`pairs/${pair.id}`).update({pairEpoch: 2});
  const newScope = {...pair, pairEpoch: 2};
  assert.deepEqual(await get(a, newScope, [item, items[3]]), {reactions: []}, 'Old target epochs and unscoped legacy letters are not visible');
  await assert.rejects(set(a, newScope, items[3], 'heart'), /target_unavailable/);
  await db.doc(`pairs/${pair.id}/messages/${item.targetId}`).update({pairEpoch: 2});
  assert.deepEqual(await get(a, newScope, [item]), {reactions: []}, 'Old reaction epochs are not reused');
  assert.equal((await set(a, newScope, item, 'laugh')).reaction.kind, 'laugh');
  await call('closePair', a, scope(newScope));
  await assert.rejects(get(b, newScope, [item]), /not_pair_member/);
  await assert.rejects(set(a, newScope, item, 'heart'), /not_pair_member/);
});

test('batch and enum validation are strict, and mutation limits preserve idempotent retries', async () => {
  const {a, b, pair} = await paired(), [item] = await targets(a, b, pair);
  const invalid = [null, {}, 'message', {targetType: 'audio', targetId: item.targetId}, {...item, targetId: '../secret'}, {...item, targetId: ''}];
  for (const value of invalid) await assert.rejects(get(a, pair, [value]), /invalid_/);
  for (const values of [null, {}, 'targets', Array(101).fill(item)]) await assert.rejects(get(a, pair, values), /invalid_targets/);
  assert.deepEqual(await get(a, pair, []), {reactions: []});
  const maximumBatch = [item, ...Array.from({length: 99}, () => ({...item, targetId: randomUUID()}))];
  assert.deepEqual(await get(a, pair, maximumBatch), {reactions: []}, 'A full bounded batch handles missing metadata without leakage');
  for (const kind of ['❤️', 'THUMBSUP', '', ' heart ', true, 0, {}, [], undefined]) {
    await assert.rejects(set(a, pair, item, kind), /invalid_reaction_kind/);
  }
  const kinds = ['heart', 'laugh', 'fire', 'tear', 'thumbsUp', 'surprised'];
  let last;
  for (let index = 0; index < 30; index++) last = await set(a, pair, item, kinds[index % kinds.length]);
  await assert.rejects(set(a, pair, item, 'heart'), /rate_limited/);
  assert.deepEqual(await set(a, pair, item, 'surprised'), last, 'A timed-out successful request remains retryable');
  now += 60_001;
  assert.equal((await set(a, pair, item, 'heart')).reaction.kind, 'heart');
  for (let index = 0; index < 60; index++) await get(a, pair, []);
  await assert.rejects(get(a, pair, []), /rate_limited/);
});

test('revocation queued before a pending mutation denies the write after the transaction lock releases', async () => {
  const {a, b, pair} = await paired(), [item] = await targets(a, b, pair);
  let release, acquired;
  const ready = new Promise(resolve => {acquired = resolve;});
  const held = db.runTransaction(async tx => {
    await service.pair(tx, a.uid, pair.id, pair.pairEpoch);
    acquired(); await new Promise(resolve => {release = resolve;});
    // Commit the revocation while the reaction request waits for the same lock.
    tx.update(db.doc(`pairs/${pair.id}`), {status: 'closed', pairEpoch: pair.pairEpoch + 1});
  });
  await ready;
  const pending = set(b, pair, item, 'heart');
  // Wait for PostgreSQL to observe the real HTTP mutation blocked on the
  // advisory lock, rather than relying on dispatch order or a fixed sleep.
  const deadline = Date.now() + 3000;
  let blocked = false;
  while (Date.now() < deadline) {
    const waiting = await db.pool.query('SELECT 1 FROM pg_locks WHERE locktype=$1 AND objid=$2 AND NOT granted LIMIT 1', ['advisory', 727001]);
    if (waiting.rowCount) {blocked = true; break;}
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  release(); await held;
  await assert.rejects(pending, /not_pair_member/);
  assert.ok(blocked, 'The reaction must be in flight before committing revocation');
  assert.equal((await db.collection(`pairs/${pair.id}/chatReactions`).get()).size, 0);
});
