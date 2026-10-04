import {createHash, randomBytes, randomUUID} from 'node:crypto';
import {Database, DocumentData, Timestamp, Transaction} from './database';
import {HttpsError} from './errors';

export type IdentityProvider = 'google' | 'apple';
export interface VerifiedIdentity {
  sub: string;
  issuedAt: number;
  authTime: number;
  displayName?: string;
}
export interface IdentityTokenVerifier {
  verify(provider: IdentityProvider, token: string, nonceHash: string, now: number): Promise<VerifiedIdentity>;
}
export type AuthConfiguration = {googleClientIDs: string[]; appleClientIDs: string[]};
const challengeLifetime = 5 * 60_000;
const accessLifetime = 15 * 60_000;
const refreshLifetime = 30 * 24 * 60 * 60_000;
const digest = (value: string): string => createHash('sha256').update(value).digest('hex');
const secret = (): string => randomBytes(32).toString('base64url');
function denied(reason = 'authentication_required'): never {throw new HttpsError('unauthenticated', reason);}
function providerValue(value: unknown): IdentityProvider {
  if (value !== 'google' && value !== 'apple') throw new HttpsError('invalid-argument', 'invalid_provider');
  return value;
}
function tokenValue(value: unknown): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(value)) denied();
  return value;
}
function deviceValue(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) {
    throw new HttpsError('invalid-argument', 'invalid_device_id');
  }
  return value;
}
function milliseconds(value: unknown): number {
  return value instanceof Timestamp ? value.toMillis() : NaN;
}
function current(record: DocumentData | undefined, now: number): record is DocumentData {
  return !!record && !record.revokedAt && milliseconds(record.expiresAt) > now;
}

/** The only production verifier. Provider keys and issuers are fixed, never supplied
 * by clients. Tests can use local JWKS by injecting a verifier into AuthService.
 */
export class OIDCIdentityTokenVerifier implements IdentityTokenVerifier {
  private readonly googleKeys = import('jose').then(jose => jose.createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs')));
  private readonly appleKeys = import('jose').then(jose => jose.createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys')));
  constructor(private readonly configuration: AuthConfiguration,
    private readonly verificationKeys?: {google: CryptoKey; apple: CryptoKey}) {}

  async verify(provider: IdentityProvider, token: string, nonceHash: string, now: number): Promise<VerifiedIdentity> {
    const audience = (provider === 'google' ? this.configuration.googleClientIDs : this.configuration.appleClientIDs)
      .filter(value => value.length > 0);
    if (audience.length === 0) throw new HttpsError('failed-precondition', 'provider_not_configured');
    const {jwtVerify} = await import('jose');
    try {
      const fixedKey = this.verificationKeys?.[provider];
      const key = fixedKey ? async () => fixedKey : await (provider === 'google' ? this.googleKeys : this.appleKeys);
      const {payload} = await jwtVerify(token, key, {
        issuer: provider === 'google' ? ['https://accounts.google.com', 'accounts.google.com'] : 'https://appleid.apple.com',
        audience, algorithms: ['RS256'], requiredClaims: ['sub', 'iat', 'exp', 'nonce'],
        currentDate: new Date(now), maxTokenAge: '5m', clockTolerance: 60,
      });
      if (payload.nonce !== nonceHash || typeof payload.sub !== 'string' || !payload.sub || payload.sub.length > 255 ||
          !Number.isSafeInteger(payload.iat) || typeof payload.iat !== 'number' || payload.iat > now / 1000 + 60) denied('invalid_identity_token');
      if ((Array.isArray(payload.aud) && payload.aud.length > 1 && typeof payload.azp !== 'string') ||
          (payload.azp !== undefined && (typeof payload.azp !== 'string' || !audience.includes(payload.azp)))) denied('invalid_identity_token');
      const authTime = payload.auth_time === undefined ? payload.iat : payload.auth_time;
      if (typeof authTime !== 'number' || !Number.isSafeInteger(authTime) || authTime <= 0 ||
          authTime > payload.iat + 60 || authTime > now / 1000 + 60) denied('invalid_identity_token');
      return {sub: payload.sub, issuedAt: payload.iat, authTime,
        ...(typeof payload.name === 'string' ? {displayName: payload.name.trim().slice(0, 60)} : {})};
    } catch (error) {
      if (error instanceof HttpsError) throw error;
      denied('invalid_identity_token');
    }
  }
}

export type AuthenticatedSession = {uid: string; authTime: number; sessionId: string; provider: IdentityProvider; expiresAt: number};
export type SessionResponse = {
  accessToken: string; refreshToken: string; expiresAt: number;
  identity: {uid: string; displayName: string}; provider: IdentityProvider;
};

/** App sessions are opaque random tokens. PostgreSQL stores hashes, not bearer
 * secrets. Refresh tokens rotate once; reuse commits family revocation before
 * returning an error, so the transaction cannot accidentally roll it back.
 */
export class AuthService {
  constructor(private readonly db: Database, private readonly verifier: IdentityTokenVerifier, private readonly now = Date.now) {}

  async challenge(input: Record<string, unknown>): Promise<{challengeId: string; nonce: string; expiresAt: number}> {
    const provider = providerValue(input.provider);
    const challengeId = randomUUID(), nonce = secret(), now = this.now(), expiresAt = now + challengeLifetime;
    await this.db.doc(`authChallenges/${challengeId}`).create({provider, nonceHash: digest(nonce),
      createdAt: Timestamp.fromMillis(now), expiresAt: Timestamp.fromMillis(expiresAt)});
    return {challengeId, nonce, expiresAt};
  }

  async exchange(input: Record<string, unknown>, existingAccessToken?: string): Promise<SessionResponse> {
    const provider = providerValue(input.provider);
    const deviceId = deviceValue(input.deviceId);
    if (typeof input.challengeId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input.challengeId) ||
        typeof input.idToken !== 'string' || input.idToken.length < 20 || input.idToken.length > 16_384) {
      throw new HttpsError('invalid-argument', 'invalid_authentication_request');
    }
    const challengeRef = this.db.doc(`authChallenges/${input.challengeId}`);
    const challenge = (await challengeRef.get()).data();
    if (!challenge || challenge.provider !== provider || challenge.consumedAt || milliseconds(challenge.expiresAt) <= this.now()) denied('invalid_challenge');
    const identity = await this.verifier.verify(provider, input.idToken, String(challenge.nonceHash), this.now());
    if (!identity.sub || identity.sub.length > 255 || !Number.isSafeInteger(identity.issuedAt) ||
        identity.issuedAt * 1000 < milliseconds(challenge.createdAt) - 60_000 ||
        identity.issuedAt * 1000 > this.now() + 60_000 || identity.issuedAt * 1000 < this.now() - 360_000 ||
        !Number.isSafeInteger(identity.authTime) || identity.authTime <= 0 ||
        identity.authTime > identity.issuedAt + 60 || identity.authTime > this.now() / 1000 + 60) denied('invalid_identity_token');
    const existingToken = existingAccessToken === undefined ? undefined : tokenValue(existingAccessToken);
    const subjectKey = digest(`${provider}:${identity.sub}`), assertionHash = digest(input.idToken);
    return this.db.runTransaction(async tx => {
      const now = this.now();
      const freshChallenge = (await tx.get(challengeRef)).data();
      if (!freshChallenge || freshChallenge.provider !== provider || freshChallenge.consumedAt || milliseconds(freshChallenge.expiresAt) <= now) denied('invalid_challenge');
      const assertionRef = this.db.doc(`authAssertions/${assertionHash}`);
      if ((await tx.get(assertionRef)).exists) denied('identity_token_replayed');
      const identityRef = this.db.doc(`authIdentities/${subjectKey}`);
      const mapped = (await tx.get(identityRef)).data();
      const existing = existingToken ? await this.authenticated(tx, existingToken, now) : undefined;
      if (existing && (!mapped || mapped.uid !== existing.uid)) denied('identity_mismatch');
      if (existing && identity.authTime < now / 1000 - 300) denied('recent_login_required');
      const uid: string = mapped?.uid ?? randomUUID();
      const userRef = this.db.doc(`users/${uid}`), user = (await tx.get(userRef)).data();
      if (mapped && (!user || user.disabled === true || user.deletedAt)) denied('account_unavailable');
      const displayName = user?.displayName ?? (identity.displayName?.trim().slice(0, 60) || 'Mi perfil');
      if (!mapped) {
        // No email or display-name matching: providers never merge implicitly.
        tx.create(identityRef, {uid, provider, createdAt: Timestamp.fromMillis(now)});
        tx.create(userRef, {displayName, createdAt: Timestamp.fromMillis(now)});
      }
      tx.update(challengeRef, {consumedAt: Timestamp.fromMillis(now)});
      tx.create(assertionRef, {expiresAt: Timestamp.fromMillis(now + 60 * 60_000)});
      let sessionDeviceId = deviceId;
      if (existing) {
        const old = (await tx.get(this.db.doc(`authSessions/${existing.sessionId}`))).data()!;
        sessionDeviceId ??= old.deviceId;
        this.revoke(tx, existing.sessionId, old, now, false);
      }
      return this.createSession(tx, {uid, displayName, provider, authTime: identity.authTime, deviceId: sessionDeviceId}, now);
    });
  }

  async authenticate(accessToken: string): Promise<AuthenticatedSession> {
    const token = tokenValue(accessToken);
    return this.db.runTransaction(tx => this.authenticated(tx, token, this.now()));
  }

  async session(accessToken: string): Promise<{identity: {uid: string; displayName: string}; provider: IdentityProvider; expiresAt: number}> {
    const identity = await this.authenticate(accessToken);
    const user = (await this.db.doc(`users/${identity.uid}`).get()).data();
    if (!user || user.disabled === true || user.deletedAt) denied('account_unavailable');
    return {identity: {uid: identity.uid, displayName: user.displayName ?? 'Mi perfil'},
      provider: identity.provider, expiresAt: identity.expiresAt};
  }

  async refresh(input: Record<string, unknown>): Promise<SessionResponse> {
    const token = tokenValue(input.refreshToken), hash = digest(token);
    const result = await this.db.runTransaction(async tx => {
      const now = this.now(), tokenRef = this.db.doc(`authRefresh/${hash}`), record = (await tx.get(tokenRef)).data();
      if (!record || typeof record.sessionId !== 'string') return {error: 'invalid_refresh_token'} as const;
      const sessionRef = this.db.doc(`authSessions/${record.sessionId}`), session = (await tx.get(sessionRef)).data();
      if (!session || session.revokedAt || milliseconds(session.refreshExpiresAt) <= now) return {error: 'invalid_refresh_token'} as const;
      if (record.consumedAt || session.refreshHash !== hash) {
        this.revoke(tx, record.sessionId, session, now);
        return {error: 'refresh_token_reused'} as const;
      }
      const user = (await tx.get(this.db.doc(`users/${session.uid}`))).data();
      if (!user || user.disabled === true || user.deletedAt) {
        this.revoke(tx, record.sessionId, session, now);
        return {error: 'account_unavailable'} as const;
      }
      const tokens = this.tokenPair(now, milliseconds(session.refreshExpiresAt));
      tx.update(tokenRef, {consumedAt: Timestamp.fromMillis(now)});
      tx.delete(this.db.doc(`authAccess/${session.accessHash}`));
      tx.create(this.db.doc(`authAccess/${tokens.accessHash}`), {sessionId: record.sessionId, expiresAt: Timestamp.fromMillis(tokens.expiresAt)});
      tx.create(this.db.doc(`authRefresh/${tokens.refreshHash}`), {sessionId: record.sessionId,
        expiresAt: session.refreshExpiresAt});
      tx.update(sessionRef, {accessHash: tokens.accessHash, refreshHash: tokens.refreshHash,
        expiresAt: Timestamp.fromMillis(tokens.expiresAt)});
      return {session: {accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt,
        identity: {uid: session.uid as string, displayName: String(user.displayName ?? 'Mi perfil')}, provider: session.provider as IdentityProvider}} as const;
    });
    if ('error' in result) denied(result.error);
    return result.session;
  }

  async signout(accessToken: string, input: Record<string, unknown>): Promise<Record<string, never>> {
    const token = tokenValue(accessToken);
    const deviceId = deviceValue(input.deviceId);
    await this.db.runTransaction(async tx => {
      const now = this.now(), identity = await this.authenticated(tx, token, now);
      const session = (await tx.get(this.db.doc(`authSessions/${identity.sessionId}`))).data()!;
      this.revoke(tx, identity.sessionId, session, now);
      if (deviceId) {
        tx.delete(this.db.doc(`users/${identity.uid}/devices/${deviceId}`));
        // Widget authorization also checks this device record, making every
        // credential for the removed device unusable immediately.
      }
    });
    return {};
  }

  private async authenticated(tx: Transaction, token: string, now: number): Promise<AuthenticatedSession> {
    const hash = digest(token), access = (await tx.get(this.db.doc(`authAccess/${hash}`))).data();
    if (!current(access, now) || typeof access.sessionId !== 'string') denied();
    const session = (await tx.get(this.db.doc(`authSessions/${access.sessionId}`))).data();
    if (!current(session, now) || session.accessHash !== hash || milliseconds(session.refreshExpiresAt) <= now) denied();
    const user = (await tx.get(this.db.doc(`users/${session.uid}`))).data();
    if (!user || user.disabled === true || user.deletedAt) denied('account_unavailable');
    return {uid: session.uid, authTime: session.authTime, sessionId: access.sessionId,
      provider: session.provider, expiresAt: milliseconds(session.expiresAt)};
  }

  private tokenPair(now: number, refreshExpiresAt: number) {
    const accessToken = secret(), refreshToken = secret();
    return {accessToken, refreshToken, accessHash: digest(accessToken), refreshHash: digest(refreshToken),
      expiresAt: Math.min(now + accessLifetime, refreshExpiresAt)};
  }

  private async createSession(tx: Transaction, identity: {uid: string; displayName: string; provider: IdentityProvider; authTime: number; deviceId?: string}, now: number): Promise<SessionResponse> {
    const id = randomUUID(), refreshExpiresAt = now + refreshLifetime, tokens = this.tokenPair(now, refreshExpiresAt);
    if (identity.deviceId) {
      const binding = this.db.doc(`installationSessions/${digest(identity.deviceId)}`);
      const previous = (await tx.get(binding)).data();
      if (previous) {
        const previousSession = (await tx.get(this.db.doc(`authSessions/${previous.sessionId}`))).data();
        if (previousSession) this.revoke(tx, previous.sessionId, previousSession, now, previous.uid !== identity.uid);
        if (previous.uid !== identity.uid) tx.delete(this.db.doc(`users/${previous.uid}/devices/${identity.deviceId}`));
      }
      // Registration checks this binding in its own transaction as well. An old
      // request authenticated before this login cannot reclaim the installation.
      tx.set(binding, {uid: identity.uid, deviceId: identity.deviceId, sessionId: id});
    }
    tx.create(this.db.doc(`authSessions/${id}`), {uid: identity.uid, provider: identity.provider, authTime: identity.authTime,
      accessHash: tokens.accessHash, refreshHash: tokens.refreshHash, deviceId: identity.deviceId, createdAt: Timestamp.fromMillis(now),
      expiresAt: Timestamp.fromMillis(tokens.expiresAt), refreshExpiresAt: Timestamp.fromMillis(refreshExpiresAt)});
    tx.create(this.db.doc(`authAccess/${tokens.accessHash}`), {sessionId: id, expiresAt: Timestamp.fromMillis(tokens.expiresAt)});
    tx.create(this.db.doc(`authRefresh/${tokens.refreshHash}`), {sessionId: id, expiresAt: Timestamp.fromMillis(refreshExpiresAt)});
    return {accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt,
      identity: {uid: identity.uid, displayName: identity.displayName}, provider: identity.provider};
  }

  private revoke(tx: Transaction, id: string, session: DocumentData, now: number, revokeDevice = true): void {
    tx.update(this.db.doc(`authSessions/${id}`), {revokedAt: Timestamp.fromMillis(now)});
    tx.delete(this.db.doc(`authAccess/${session.accessHash}`));
    if (revokeDevice && typeof session.deviceId === 'string') {
      tx.delete(this.db.doc(`users/${session.uid}/devices/${session.deviceId}`));
    }
  }
}
