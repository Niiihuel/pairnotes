const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const {createHash, randomUUID} = require('node:crypto');
const {Database, Timestamp} = require('../lib/database.js');
const {AuthService, OIDCIdentityTokenVerifier} = require('../lib/auth.js');

if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL must point to an isolated PostgreSQL test database');
const db = new Database(process.env.DATABASE_URL);
const sha256 = value => createHash('sha256').update(value).digest('hex');
before(async () => {await db.migrate();});
after(async () => {await db.terminate();});

// Fictional provider assertions exercise the transactional session boundary.
// Separate tests below use real RSA signatures and the production JOSE verifier.
function fixture() {
  let clock = Date.now();
  const assertions = new Map();
  const verifier = {async verify(provider, token, nonceHash) {
    const entry = assertions.get(token);
    if (!entry || entry.provider !== provider || entry.nonceHash !== nonceHash) throw new Error('invalid fictional assertion');
    return entry.identity;
  }};
  const auth = new AuthService(db, verifier, () => clock);
  async function request({provider = 'google', subject = randomUUID(), challenge, authTime, name = 'Persona ficticia'} = {}) {
    challenge ??= await auth.challenge({provider});
    const idToken = `fictional-provider-assertion-${randomUUID()}`;
    assertions.set(idToken, {provider, nonceHash: sha256(challenge.nonce), identity: {
      sub: subject, issuedAt: Math.floor(clock / 1000), authTime: authTime ?? Math.floor(clock / 1000),
      displayName: name,
      email: 'same-fictional-email@example.test',
    }});
    return {input: {provider, idToken, challengeId: challenge.challengeId}, challenge, subject};
  }
  return {auth, assertions, request, advance: amount => {clock += amount;}, now: () => clock};
}

test('challenge contains unpredictable nonce and stores only its hash', async () => {
  const {auth} = fixture();
  const first = await auth.challenge({provider: 'apple'});
  const second = await auth.challenge({provider: 'apple'});
  assert.match(first.nonce, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(first.nonce, second.nonce);
  const stored = (await db.doc(`authChallenges/${first.challengeId}`).get()).data();
  assert.equal(stored.nonceHash, sha256(first.nonce));
  assert.equal(stored.nonce, undefined);
});

test('expired and provider-mismatched challenges cannot create sessions', async () => {
  const f = fixture(), request = await f.request();
  await assert.rejects(f.auth.exchange({...request.input, provider: 'apple'}), /invalid_challenge/);
  f.advance(5 * 60_000);
  await assert.rejects(f.auth.exchange(request.input), /invalid_challenge/);
});

test('nonce mismatch and forged provider assertion fail before consuming challenge', async () => {
  const f = fixture(), request = await f.request();
  f.assertions.get(request.input.idToken).nonceHash = 'wrong-nonce';
  await assert.rejects(f.auth.exchange(request.input));
  const stored = (await db.doc(`authChallenges/${request.challenge.challengeId}`).get()).data();
  assert.equal(stored.consumedAt, undefined);
});

test('parallel exchanges consume a challenge exactly once', async () => {
  const f = fixture(), request = await f.request();
  const attempts = await Promise.allSettled([f.auth.exchange(request.input), f.auth.exchange(request.input)]);
  assert.equal(attempts.filter(value => value.status === 'fulfilled').length, 1);
  assert.equal(attempts.filter(value => value.status === 'rejected').length, 1);
  await assert.rejects(f.auth.exchange(request.input), /invalid_challenge/);
});

test('same provider subject keeps UID while matching email or different provider cannot merge accounts', async () => {
  const f = fixture(), subject = randomUUID();
  const first = await f.auth.exchange((await f.request({subject})).input);
  const same = await f.auth.exchange((await f.request({subject})).input);
  const other = await f.auth.exchange((await f.request()).input);
  const apple = await f.auth.exchange((await f.request({provider: 'apple', subject})).input);
  assert.equal(first.identity.uid, same.identity.uid);
  assert.notEqual(first.identity.uid, other.identity.uid);
  assert.notEqual(first.identity.uid, apple.identity.uid);
});

test('parallel first logins for one subject create one internal UID', async () => {
  const f = fixture(), subject = randomUUID();
  const a = await f.request({subject}), b = await f.request({subject});
  const sessions = await Promise.all([f.auth.exchange(a.input), f.auth.exchange(b.input)]);
  assert.equal(sessions[0].identity.uid, sessions[1].identity.uid);
  assert.notEqual(sessions[0].accessToken, sessions[1].accessToken);
});

test('database session rows never contain access, refresh or original provider tokens', async () => {
  const f = fixture(), request = await f.request(), session = await f.auth.exchange(request.input);
  const authenticated = await f.auth.authenticate(session.accessToken);
  const rows = await db.pool.query('SELECT value FROM documents WHERE path = ANY($1)', [[
    `authSessions/${authenticated.sessionId}`, `authAccess/${sha256(session.accessToken)}`, `authRefresh/${sha256(session.refreshToken)}`,
  ]]);
  const serialized = JSON.stringify(rows.rows);
  for (const raw of [session.accessToken, session.refreshToken, request.input.idToken]) assert.equal(serialized.includes(raw), false);
  assert.equal(authenticated.uid, session.identity.uid);
});

test('access expiration allows refresh without making authentication recent again', async () => {
  const f = fixture(), request = await f.request(), original = await f.auth.exchange(request.input);
  const before = await f.auth.authenticate(original.accessToken);
  f.advance(16 * 60_000);
  await assert.rejects(f.auth.authenticate(original.accessToken));
  const renewed = await f.auth.refresh({refreshToken: original.refreshToken});
  const after = await f.auth.authenticate(renewed.accessToken);
  assert.equal(after.uid, before.uid);
  assert.equal(after.authTime, before.authTime);
  assert.notEqual(renewed.accessToken, original.accessToken);
  assert.notEqual(renewed.refreshToken, original.refreshToken);
});

test('refresh token replay commits revocation of its entire rotated family', async () => {
  const f = fixture(), original = await f.auth.exchange((await f.request()).input);
  const renewed = await f.auth.refresh({refreshToken: original.refreshToken});
  await assert.rejects(f.auth.authenticate(original.accessToken));
  await assert.rejects(f.auth.refresh({refreshToken: original.refreshToken}), /refresh_token_reused/);
  await assert.rejects(f.auth.authenticate(renewed.accessToken));
  await assert.rejects(f.auth.refresh({refreshToken: renewed.refreshToken}));
});

test('concurrent refresh cannot mint two surviving sessions from one token', async () => {
  const f = fixture(), original = await f.auth.exchange((await f.request()).input);
  const attempts = await Promise.allSettled([
    f.auth.refresh({refreshToken: original.refreshToken}), f.auth.refresh({refreshToken: original.refreshToken}),
  ]);
  const successful = attempts.filter(value => value.status === 'fulfilled');
  assert.equal(successful.length, 1);
  assert.equal(attempts.filter(value => value.status === 'rejected').length, 1);
  await assert.rejects(f.auth.authenticate(successful[0].value.accessToken));
});

test('refresh family has absolute expiration after thirty days', async () => {
  const f = fixture(), original = await f.auth.exchange((await f.request()).input);
  f.advance(29 * 24 * 60 * 60_000);
  const renewed = await f.auth.refresh({refreshToken: original.refreshToken});
  f.advance(24 * 60 * 60_000);
  await assert.rejects(f.auth.refresh({refreshToken: renewed.refreshToken}));
});

test('reauthentication must prove the same account and rotates old session secrets', async () => {
  const f = fixture(), subject = randomUUID(), first = await f.auth.exchange((await f.request({subject})).input);
  await assert.rejects(f.auth.exchange((await f.request()).input, first.accessToken), /identity_mismatch/);
  assert.equal((await f.auth.authenticate(first.accessToken)).uid, first.identity.uid);
  f.advance(60_000);
  const reauthenticated = await f.auth.exchange((await f.request({subject})).input, first.accessToken);
  assert.equal(reauthenticated.identity.uid, first.identity.uid);
  await assert.rejects(f.auth.authenticate(first.accessToken));
  await assert.rejects(f.auth.refresh({refreshToken: first.refreshToken}));
  assert.equal((await f.auth.authenticate(reauthenticated.accessToken)).authTime, Math.floor(f.now() / 1000));
});

test('signout revokes access, refresh and the selected device registration', async () => {
  const f = fixture(), session = await f.auth.exchange((await f.request()).input), deviceId = randomUUID();
  const path = `users/${session.identity.uid}/devices/${deviceId}`;
  await db.doc(path).create({apnsToken: 'fictional-device-token', widgetSessionHash: 'fictional-widget'});
  await f.auth.signout(session.accessToken, {deviceId});
  assert.equal((await db.doc(path).get()).exists, false);
  await assert.rejects(f.auth.authenticate(session.accessToken));
  await assert.rejects(f.auth.refresh({refreshToken: session.refreshToken}));
});

test('disabled accounts cannot authenticate or refresh', async () => {
  const f = fixture(), session = await f.auth.exchange((await f.request()).input);
  await db.doc(`users/${session.identity.uid}`).update({disabled: true});
  await assert.rejects(f.auth.authenticate(session.accessToken), /account_unavailable/);
  await assert.rejects(f.auth.refresh({refreshToken: session.refreshToken}), /account_unavailable/);
});

test('refresh reuse revokes the device registration bound at login', async () => {
  const f = fixture(), request = await f.request(), deviceId = randomUUID();
  const session = await f.auth.exchange({...request.input, deviceId});
  const path = `users/${session.identity.uid}/devices/${deviceId}`;
  await db.doc(path).create({apnsToken: 'fictional-device-token', widgetSessionHash: 'fictional-widget'});
  await f.auth.refresh({refreshToken: session.refreshToken});
  await assert.rejects(f.auth.refresh({refreshToken: session.refreshToken}), /refresh_token_reused/);
  assert.equal((await db.doc(path).get()).exists, false);
});

test('new account login atomically takes installation ownership and revokes the previous family', async () => {
  const f = fixture(), deviceId = randomUUID();
  const first = await f.auth.exchange({...((await f.request()).input), deviceId});
  const oldIdentity = await f.auth.authenticate(first.accessToken);
  await db.doc(`users/${first.identity.uid}/devices/${deviceId}`).create({active: true, widgetSessionHash: 'fictional-widget'});
  const second = await f.auth.exchange({...((await f.request()).input), deviceId});
  assert.notEqual(first.identity.uid, second.identity.uid);
  await assert.rejects(f.auth.authenticate(first.accessToken));
  await assert.rejects(f.auth.refresh({refreshToken: first.refreshToken}));
  assert.equal((await db.doc(`users/${first.identity.uid}/devices/${deviceId}`).get()).exists, false);
  const secondIdentity = await f.auth.authenticate(second.accessToken);
  const binding = (await db.doc(`installationSessions/${sha256(deviceId)}`).get()).data();
  assert.equal(binding.uid, second.identity.uid);
  assert.equal(binding.sessionId, secondIdentity.sessionId);
  assert.notEqual(binding.sessionId, oldIdentity.sessionId);
});

test('same-account login rotates installation session without deleting its active widget registration', async () => {
  const f = fixture(), deviceId = randomUUID(), subject = randomUUID();
  const first = await f.auth.exchange({...((await f.request({subject})).input), deviceId});
  const devicePath = `users/${first.identity.uid}/devices/${deviceId}`;
  await db.doc(devicePath).create({active: true, widgetSessionHash: 'fictional-widget'});
  const second = await f.auth.exchange({...((await f.request({subject})).input), deviceId});
  assert.equal(second.identity.uid, first.identity.uid);
  await assert.rejects(f.auth.authenticate(first.accessToken));
  await assert.rejects(f.auth.refresh({refreshToken: first.refreshToken}));
  assert.equal((await db.doc(devicePath).get()).data().widgetSessionHash, 'fictional-widget');
});

test('normal login preserves old auth_time while sensitive reauthentication requires fresh proof', async () => {
  const f = fixture(), subject = randomUUID(), authTime = Math.floor(f.now() / 1000) - 3600;
  const request = await f.request({subject, authTime});
  const session = await f.auth.exchange(request.input);
  assert.equal((await f.auth.authenticate(session.accessToken)).authTime, authTime);
  const reauthentication = await f.request({subject, authTime});
  await assert.rejects(f.auth.exchange(reauthentication.input, session.accessToken), /recent_login_required/);
});

test('production OIDC verifier checks signatures, issuer, audience, nonce, expiry and freshness', async t => {
  const {generateKeyPair, SignJWT} = await import('jose');
  const keys = await generateKeyPair('RS256'), attacker = await generateKeyPair('RS256');
  const now = Math.floor(Date.now() / 1000), nonce = sha256('fictional-nonce');
  const verifier = new OIDCIdentityTokenVerifier({googleClientIDs: ['fictional-google-client'], appleClientIDs: ['fictional.apple.bundle']},
    {google: keys.publicKey, apple: keys.publicKey});
  const standard = {sub: randomUUID(), iss: 'https://accounts.google.com', aud: 'fictional-google-client',
    iat: now, exp: now + 3600, nonce};
  async function signed(overrides = {}, key = keys.privateKey) {
    return new SignJWT({...standard, ...overrides}).setProtectedHeader({alg: 'RS256'}).sign(key);
  }
  await t.test('valid Google and Apple signed assertions pass', async () => {
    assert.equal((await verifier.verify('google', await signed(), nonce, now * 1000)).sub, standard.sub);
    const apple = await signed({iss: 'https://appleid.apple.com', aud: 'fictional.apple.bundle'});
    assert.equal((await verifier.verify('apple', apple, nonce, now * 1000)).sub, standard.sub);
  });
  for (const [name, overrides] of Object.entries({
    'wrong issuer': {iss: 'https://attacker.example.test'}, 'wrong audience': {aud: 'unrelated-client'},
    'missing nonce': {nonce: undefined}, 'wrong nonce': {nonce: 'replayed-nonce'},
    'expired token': {exp: now - 120}, 'future issuance': {iat: now + 120},
    'stale issuance': {iat: now - 400}, 'future authentication': {auth_time: now + 120},
    'wrong authorized party': {azp: 'unrelated-client'}, 'multiple audiences without authorized party': {aud: ['fictional-google-client', 'other']},
  })) {
    await t.test(name, async () => {await assert.rejects(verifier.verify('google', await signed(overrides), nonce, now * 1000));});
  }
  await t.test('signature by unrelated key fails', async () => {
    await assert.rejects(verifier.verify('google', await signed({}, attacker.privateKey), nonce, now * 1000));
  });
  await t.test('unsigned assertion fails', async () => {
    const raw = `${Buffer.from('{"alg":"none"}').toString('base64url')}.${Buffer.from(JSON.stringify(standard)).toString('base64url')}.`;
    await assert.rejects(verifier.verify('google', raw, nonce, now * 1000));
  });
  await t.test('old auth_time is retained for later sensitive-operation checks', async () => {
    const result = await verifier.verify('google', await signed({auth_time: now - 3600}), nonce, now * 1000);
    assert.equal(result.authTime, now - 3600);
  });
});
