const {test} = require('node:test');
const assert = require('node:assert/strict');
const {randomUUID} = require('node:crypto');
const sharp = require('sharp');
const {Database} = require('../lib/database');
const {PairNotesService, digest} = require('../lib/service');

test('cleanup and renewal fence an older finalization before publishing missing assets', async () => {
  assert.ok(process.env.DATABASE_URL, 'Use an isolated PostgreSQL test database');
  const url = new URL(process.env.DATABASE_URL);
  assert.ok(['localhost', '127.0.0.1', 'postgres'].includes(url.hostname), 'Tests refuse a remote database');
  const schema = 'finalization_review_' + randomUUID().replaceAll('-', '');
  const admin = new Database(url.toString());
  await admin.pool.query('CREATE SCHEMA ' + schema);
  url.searchParams.set('options', '-c search_path=' + schema);
  const db = new Database(url.toString());
  let unblock, reached;
  const reachedWrite = new Promise(resolve => {reached = resolve;});
  const blockedWrite = new Promise(resolve => {unblock = resolve;});
  const files = new Map();
  let pauseOnce = true, now = Date.now();
  // PostgreSQL transactions are real. An injected object-store barrier gives the
  // exact interleaving deterministically, without an hours-long network stall.
  const storage = {file(path) {return {
    exists: async () => [files.has(path)],
    getMetadata: async () => [files.get(path).metadata],
    download: async () => [files.get(path).bytes],
    delete: async () => {files.delete(path);},
    save: async (bytes, options) => {
      if (files.has(path)) throw Object.assign(new Error('asset_exists'), {code: 412});
      files.set(path, {bytes, metadata: {size: bytes.length, ...options.metadata}});
      if (pauseOnce && path.startsWith('pairs/') && path.endsWith('/source')) {
        pauseOnce = false;
        reached();
        await blockedWrite;
      }
    },
  };}};
  const service = new PairNotesService(db, storage, () => now);
  try {
    await db.migrate();
    const a = {uid: randomUUID(), authTime: Math.floor(now / 1000)};
    const b = {uid: randomUUID(), authTime: Math.floor(now / 1000)};
    await service.upsertProfile(a, {displayName: 'Persona ficticia A'});
    await service.upsertProfile(b, {displayName: 'Persona ficticia B'});
    const invitation = await service.createInvite(a);
    const {pair} = await service.acceptInvite(b, {token: invitation.token});
    const png = await sharp({create: {width: 16, height: 16, channels: 4, background: '#ffffff'}}).png().toBuffer();
    const bytes = {source: Buffer.from('Fictional opaque editable source'), final: png, widget: png, thumbnail: png};
    const payload = {pairId: pair.id, pairEpoch: 1, idempotencyKey: randomUUID(), noteId: randomUUID(),
      revision: 1, revisionHash: digest(bytes.source),
      assets: Object.entries(bytes).map(([role, value]) => ({role, sha256: digest(value), byteCount: value.length,
        contentType: role === 'source' ? 'application/octet-stream' : 'image/png'}))};
    const session = await service.createUploadSession(a, payload);
    const upload = async () => {
      for (const [role, value] of Object.entries(bytes)) {
        await service.upload(a, session.sessionId, role, value,
          role === 'source' ? 'application/octet-stream' : 'image/png', digest(value));
      }
    };
    await upload();
    const finalizeInput = {pairId: pair.id, pairEpoch: 1, sessionId: session.sessionId};
    const staleFinalization = service.finalizeNote(a, finalizeInput);
    await reachedWrite;
    now += 2 * 3600_000 + 1;
    await service.cleanupExpiredUploads();
    const renewed = await service.createUploadSession(a, payload);
    assert.equal(renewed.sessionId, session.sessionId);
    unblock();
    await assert.rejects(staleFinalization, /upload_generation_changed/);
    assert.equal((await db.doc(`pairs/${pair.id}/notes/${payload.noteId}`).get()).exists, false);
    assert.equal((await db.doc(`notificationEvents/${digest(`${pair.id}:${payload.noteId}`)}`).get()).exists, false);
    await upload();
    const {note} = await service.finalizeNote(a, finalizeInput);
    assert.equal(note.id, payload.noteId);
    for (const role of ['source', 'final', 'widget', 'thumbnail']) {
      assert.equal(files.has(note.paths[role]), true, `${role} must exist before publication`);
      assert.equal(digest(files.get(note.paths[role]).bytes), digest(bytes[role]));
    }
  } finally {
    unblock();
    await db.terminate();
    await admin.pool.query('DROP SCHEMA ' + schema + ' CASCADE');
    await admin.terminate();
  }
});
