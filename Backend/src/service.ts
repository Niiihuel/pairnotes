import {createHash, randomBytes, randomUUID} from 'node:crypto';
import {Database, Timestamp, Transaction, DocumentData, FieldValue} from './database';
import {AssetStore} from './assets';
import {HttpsError} from './errors';
import sharp from 'sharp';
import {AffectionFeatures} from './affection';
import {CoupleFeatures, publicProfile} from './couple';
import {revokeLocationDevice} from './location';
import {PhotoFeatures} from './photos';

export const roles = ['source', 'final', 'widget', 'thumbnail'] as const;
type Role = typeof roles[number];
type Input = Record<string, unknown>;
export type Caller = {uid: string; authTime: number; sessionId?: string};
export type Manifest = Record<Role, {sha256: string; byteCount: number; contentType: string}>;
export const digest = (value: string | Buffer) => createHash('sha256').update(value).digest('hex');
const token = () => randomBytes(32).toString('base64url');
export function fail(reason: string, code: ConstructorParameters<typeof HttpsError>[0] = 'failed-precondition'): never {
  throw new HttpsError(code, reason, {reason});
}
function string(value: unknown, name: string, max = 128): string {
  if (typeof value !== 'string' || value.length < 1 || value.length > max) fail(`invalid_${name}`, 'invalid-argument');
  return value;
}
function identifier(value: unknown, name: string): string {
  const result = string(value, name);
  if (!/^[a-zA-Z0-9_-]+$/.test(result)) fail(`invalid_${name}`, 'invalid-argument');
  return result;
}
function integer(value: unknown, name: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1) fail(`invalid_${name}`, 'invalid-argument');
  return value;
}
function sha(value: unknown): string {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) fail('invalid_hash', 'invalid-argument');
  return value;
}
export function publicNote(note: DocumentData): DocumentData {
  return {...note, publishedAt: (note.publishedAt as Timestamp).toMillis()};
}

/** Each HTTP operation independently authorizes its caller and relationship generation. */
export class PairNotesService {
  readonly affection = new AffectionFeatures(this);
  readonly couple = new CoupleFeatures(this);
  readonly photos = new PhotoFeatures(this);
  constructor(readonly db: Database, readonly bucket: AssetStore, readonly now: () => number = Date.now) {}
  async sendGesture(caller: Caller, input: Input) {return this.affection.sendGesture(caller, input);}
  async reactions(caller: Caller, input: Input) {return this.affection.reactions(caller, input);}
  async setReaction(caller: Caller, input: Input) {return this.affection.setReaction(caller, input);}
  async getPhoto(caller: Caller, input: Input) {return this.photos.getPhoto(caller, input);}
  async setPhotoReaction(caller: Caller, input: Input) {return this.photos.setReaction(caller, input);}
  async letters(caller: Caller, input: Input) {return this.affection.letters(caller, input);}
  async saveLetterDraft(caller: Caller, input: Input) {return this.affection.saveLetterDraft(caller, input);}
  async sealLetter(caller: Caller, input: Input) {return this.affection.sealLetter(caller, input);}
  async openLetter(caller: Caller, input: Input) {return this.affection.openLetter(caller, input);}
  async deleteLetterDraft(caller: Caller, input: Input) {return this.affection.deleteLetterDraft(caller, input);}
  async removeLetterAsset(caller: Caller, input: Input) {return this.affection.removeLetterAsset(caller, input);}
  async getCoupleSpace(caller: Caller, input: Input) {return this.couple.getCoupleSpace(caller, input);}
  async updatePersonalization(caller: Caller, input: Input) {return this.couple.updatePersonalization(caller, input);}
  async restoreMemory(caller: Caller, input: Input) {return this.couple.restoreMemory(caller, input);}
  async updatePairDetails(caller: Caller, input: Input) {return this.couple.updatePairDetails(caller, input);}
  async upsertMemory(caller: Caller, input: Input) {return this.couple.upsertMemory(caller, input);}
  async memories(caller: Caller, input: Input) {return this.couple.memories(caller, input);}
  async deleteMemory(caller: Caller, input: Input) {return this.couple.deleteMemory(caller, input);}
  async deleteMemoryPhoto(caller: Caller, input: Input) {return this.couple.deleteMemoryPhoto(caller, input);}
  async deleteProfileAvatar(caller: Caller) {return this.couple.deleteProfileAvatar(caller);}
  async sendMessage(caller: Caller, input: Input) {return this.couple.sendMessage(caller, input);}
  async messages(caller: Caller, input: Input) {return this.couple.messages(caller, input);}
  async setLocationConsent(caller: Caller, input: Input) {return this.couple.setLocationConsent(caller, input);}
  async updateLocation(caller: Caller, input: Input) {return this.couple.updateLocation(caller, input);}
  async rate(uid: string, action: string, limit: number, period: number): Promise<void> {
    const ref = this.db.doc(`rateLimits/${digest(`${uid}:${action}`)}`);
    await this.db.runTransaction(async tx => {
      const old = (await tx.get(ref)).data();
      const now = this.now();
      const count = old && old.until.toMillis() > now ? old.count as number : 0;
      if (count >= limit) fail('rate_limited', 'resource-exhausted');
      tx.set(ref, {count: count + 1, until: Timestamp.fromMillis(count ? old!.until.toMillis() : now + period)});
    });
  }
  async pair(tx: Transaction, uid: string, id: string, epoch?: number): Promise<DocumentData> {
    const value = (await tx.get(this.db.doc(`pairs/${id}`))).data();
    if (!value || value.status !== 'active' || !value.members.includes(uid)) fail('not_pair_member', 'permission-denied');
    if (epoch !== undefined && value.pairEpoch !== epoch) fail('stale_pair_epoch', 'permission-denied');
    return value;
  }
  async pairResponse(uid: string, id: string): Promise<DocumentData> {
    return this.db.runTransaction(async tx => {
      const pair = await this.pair(tx, uid, id);
      const partnerId = (pair.members as string[]).find(member => member !== uid)!;
      const profile = (await tx.get(this.db.doc(`pairs/${id}/profiles/${partnerId}`))).data();
      return {id, members: pair.members, pairEpoch: pair.pairEpoch, status: 'active', startedOn: pair.startedOn ?? null,
        partner: publicProfile({uid: partnerId, ...profile, displayName: profile?.displayName ?? 'Tu pareja'})};
    });
  }
  async upsertProfile(caller: Caller, input: Input): Promise<Input> {
    const displayName = string(input.displayName, 'display_name', 80).trim();
    if (!displayName) fail('invalid_display_name', 'invalid-argument');
    await this.rate(caller.uid, 'profile', 20, 60_000);
    const profile = await this.db.runTransaction(async tx => {
      const ref = this.db.doc(`users/${caller.uid}`);
      const old = (await tx.get(ref)).data();
      const pair = old?.activePairId ? await this.pair(tx, caller.uid, old.activePairId) : null;
      tx.set(ref, {uid: caller.uid, displayName, activePairId: old?.activePairId ?? null}, {merge: true});
      if (pair) tx.set(this.db.doc(`pairs/${old!.activePairId}/profiles/${caller.uid}`), {uid: caller.uid, displayName, avatar: old?.avatar ?? null});
      return publicProfile({...old, uid: caller.uid, displayName});
    });
    return {profile};
  }
  async getPairState(caller: Caller): Promise<Input> {
    const value = (await this.db.doc(`users/${caller.uid}`).get()).data();
    return {profile: publicProfile({...value, uid: caller.uid}), pair: value?.activePairId ? await this.pairResponse(caller.uid, value.activePairId) : null};
  }
  async createInvite(caller: Caller): Promise<Input> {
    await this.rate(caller.uid, 'invite_create', 5, 60_000);
    const secret = token(), hash = digest(secret), expiresAt = this.now() + 15 * 60_000;
    await this.db.runTransaction(async tx => {
      const ref = this.db.doc(`users/${caller.uid}`), user = (await tx.get(ref)).data();
      if (!user?.displayName) fail('profile_required');
      if (user.activePairId) fail('already_paired');
      if (user.inviteHash) tx.update(this.db.doc(`pairInvites/${user.inviteHash}`), {status: 'revoked'});
      tx.create(this.db.doc(`pairInvites/${hash}`), {ownerId: caller.uid, status: 'pending', expiresAt: Timestamp.fromMillis(expiresAt)});
      tx.update(ref, {inviteHash: hash});
    });
    return {token: secret, expiresAt};
  }
  async revokeInvite(caller: Caller): Promise<Input> {
    await this.db.runTransaction(async tx => {
      const ref = this.db.doc(`users/${caller.uid}`), user = (await tx.get(ref)).data();
      if (user?.inviteHash) {
        tx.update(this.db.doc(`pairInvites/${user.inviteHash}`), {status: 'revoked'});
        tx.update(ref, {inviteHash: null});
      }
    });
    return {};
  }
  async acceptInvite(caller: Caller, input: Input): Promise<Input> {
    await this.rate(caller.uid, 'invite_accept', 10, 15 * 60_000);
    const secret = string(input.token, 'token', 64);
    if (!/^[a-zA-Z0-9_-]{43}$/.test(secret)) fail('invite_unavailable');
    const id = randomUUID();
    await this.db.runTransaction(async tx => {
      const inviteRef = this.db.doc(`pairInvites/${digest(secret)}`), invite = (await tx.get(inviteRef)).data();
      if (!invite || invite.status !== 'pending' || invite.expiresAt.toMillis() <= this.now()) fail('invite_unavailable');
      if (invite.ownerId === caller.uid) fail('self_invite');
      const ownerRef = this.db.doc(`users/${invite.ownerId}`), userRef = this.db.doc(`users/${caller.uid}`);
      const [ownerSnap, userSnap] = await tx.getAll(ownerRef, userRef);
      const owner = ownerSnap!.data(), user = userSnap!.data();
      if (!owner?.displayName || !user?.displayName) fail('profile_required');
      if (owner.activePairId || user.activePairId) fail('already_paired');
      tx.create(this.db.doc(`pairs/${id}`), {id, members: [invite.ownerId, caller.uid], pairEpoch: 1, status: 'active', lastPublishedMillis: 0});
      tx.create(this.db.doc(`pairs/${id}/profiles/${invite.ownerId}`), {uid: invite.ownerId, displayName: owner.displayName, avatar: owner.avatar ?? null});
      tx.create(this.db.doc(`pairs/${id}/profiles/${caller.uid}`), {uid: caller.uid, displayName: user.displayName, avatar: user.avatar ?? null});
      tx.update(inviteRef, {status: 'consumed', consumedBy: caller.uid});
      if (user.inviteHash) tx.update(this.db.doc(`pairInvites/${user.inviteHash}`), {status: 'revoked'});
      tx.update(ownerRef, {activePairId: id, inviteHash: null});
      tx.update(userRef, {activePairId: id, inviteHash: null});
    });
    return {pair: await this.pairResponse(caller.uid, id)};
  }
  async closePair(caller: Caller, input: Input): Promise<Input> {
    if (!Number.isFinite(caller.authTime) || this.now() / 1000 - caller.authTime > 300 || caller.authTime > this.now() / 1000 + 60) fail('recent_login_required', 'unauthenticated');
    const id = identifier(input.pairId, 'pair_id'), epoch = integer(input.pairEpoch, 'pair_epoch');
    await this.db.runTransaction(async tx => {
      const pair = await this.pair(tx, caller.uid, id, epoch);
      tx.update(this.db.doc(`pairs/${id}`), {status: 'closed', pairEpoch: epoch + 1, closedAt: Timestamp.fromMillis(this.now())});
      for (const uid of pair.members as string[]) {
        tx.update(this.db.doc(`users/${uid}`), {activePairId: null});
        tx.delete(this.db.doc(`pairs/${id}/views/${uid}`));
        tx.delete(this.db.doc(`locationPrivate/${uid}`));
        tx.delete(this.db.doc(`pairs/${id}/locationConsent/${uid}`));
      }
      tx.delete(this.db.doc(`pairs/${id}/distance/current`));
    });
    return {};
  }
  manifest(raw: unknown): Manifest {
    if (!Array.isArray(raw) || raw.length !== 4) fail('invalid_assets', 'invalid-argument');
    const result = {} as Manifest;
    for (const asset of raw as Input[]) {
      if (!asset || typeof asset !== 'object' || !roles.includes(asset.role as Role) || result[asset.role as Role]) fail('invalid_assets', 'invalid-argument');
      const role = asset.role as Role;
      const byteCount = integer(asset.byteCount, 'byte_count');
      if (byteCount > (role === 'source' ? 20 * 1024 * 1024 : role === 'final' ? 12 * 1024 * 1024 : 4 * 1024 * 1024)) fail('asset_too_large', 'invalid-argument');
      const contentType = role === 'source' ? 'application/octet-stream' : 'image/png';
      if (asset.contentType !== contentType) fail('invalid_content_type', 'invalid-argument');
      result[role] = {sha256: sha(asset.sha256), byteCount, contentType};
    }
    return Object.fromEntries(roles.map(role => [role, result[role]])) as Manifest;
  }
  async createUploadSession(caller: Caller, input: Input): Promise<Input> {
    await this.rate(caller.uid, 'upload', 30, 60_000);
    const pairId = identifier(input.pairId, 'pair_id'), pairEpoch = integer(input.pairEpoch, 'pair_epoch');
    const key = identifier(input.idempotencyKey, 'idempotency_key'), noteId = identifier(input.noteId, 'note_id');
    const revision = integer(input.revision, 'revision'), revisionHash = sha(input.revisionHash), assets = this.manifest(input.assets);
    if (assets.source.sha256 !== revisionHash) fail('source_revision_mismatch', 'invalid-argument');
    const sessionId = digest(`${caller.uid}:${key}`);
    const signature = digest(JSON.stringify({pairId, pairEpoch, noteId, revision, revisionHash, assets}));
    return this.db.runTransaction(async tx => {
      await this.pair(tx, caller.uid, pairId, pairEpoch);
      const ref = this.db.doc(`uploadSessions/${sessionId}`), existing = (await tx.get(ref)).data();
      if (existing) {
        if (existing.signature !== signature) fail('idempotency_conflict', 'already-exists');
        if (existing.status !== 'published' && existing.expiresAt.toMillis() <= this.now()) {
          // Explicit retry reauthorizes the same immutable manifest and generation. Cleanup
          // holds this same SQL transaction lock while deleting, so renewal cannot race it.
          tx.update(ref, {status: 'uploading', generation: (existing.generation ?? 0) + 1, cleanupDone: false, expiresAt: Timestamp.fromMillis(this.now() + 3600_000)});
        }
        return {sessionId, noteId, paths: existing.tempPaths, published: existing.status === 'published'};
      }
      const note = await tx.get(this.db.doc(`pairs/${pairId}/notes/${noteId}`));
      if (note.exists) fail('note_id_exists', 'already-exists');
      const reservation = this.db.doc(`noteReservations/${digest(`${pairId}:${noteId}`)}`);
      if ((await tx.get(reservation)).exists) fail('note_id_exists', 'already-exists');
      const tempPaths = Object.fromEntries(roles.map(role => [role, `tmp/${caller.uid}/${sessionId}/${role}`]));
      const finalPaths = Object.fromEntries(roles.map(role => [role, `pairs/${pairId}/${pairEpoch}/${noteId}/${role}`]));
      tx.create(ref, {ownerId: caller.uid, pairId, pairEpoch, noteId, revision, revisionHash, assets, signature, tempPaths, finalPaths,
        status: 'uploading', generation: 1, cleanupDone: false, expiresAt: Timestamp.fromMillis(this.now() + 3600_000)});
      tx.create(reservation, {sessionId});
      return {sessionId, noteId, paths: tempPaths, published: false};
    });
  }
  async freeze(session: DocumentData): Promise<void> {
    // Read/verify all four objects before any published metadata exists. No download URLs/tokens.
    const verified = new Map<Role, Buffer>();
    for (const role of roles) {
      const expected = (session.assets as Manifest)[role];
      const file = this.bucket.file(session.tempPaths[role]);
      const [exists] = await file.exists();
      if (!exists) fail('assets_incomplete');
      const [metadata] = await file.getMetadata();
      if (Number(metadata.size) !== expected.byteCount || metadata.contentType !== expected.contentType) fail('asset_metadata_mismatch');
      const [bytes] = await file.download();
      if (bytes.length !== expected.byteCount || digest(bytes) !== expected.sha256) fail('asset_integrity_mismatch');
      if (role !== 'source') {
        try {
          const img = sharp(bytes, {limitInputPixels: 4096 * 4096, failOn: 'warning'});
          const info = await img.metadata();
          const maxSide = role === 'final' ? 2048 : role === 'widget' ? 1024 : 480;
          if (info.format !== 'png' || !info.width || !info.height || info.width !== info.height || info.width > maxSide || (info.pages ?? 1) > 1) fail('invalid_image');
          await img.raw().toBuffer(); // Decode pixels: headers alone cannot validate a truncated image.
        } catch { fail('invalid_image'); }
      }
      verified.set(role, bytes);
    }
    for (const role of roles) {
      const target = this.bucket.file(session.finalPaths[role]);
      try {
        await target.save(verified.get(role)!, {resumable: false, preconditionOpts: {ifGenerationMatch: 0}, metadata: {
          contentType: session.assets[role].contentType, cacheControl: 'private, no-store', metadata: {sha256: session.assets[role].sha256}
        }});
      } catch (error) {
        if ((error as {code?: number}).code !== 412) throw error;
        const [bytes] = await target.download();
        if (digest(bytes) !== session.assets[role].sha256) fail('note_id_exists', 'already-exists');
      }
    }
  }
  async upload(caller: Caller, sessionId: string, role: string, bytes: Buffer, contentType: string, expectedHash: string): Promise<Input> {
    identifier(sessionId, 'session_id');
    if (!roles.includes(role as Role)) fail('invalid_role', 'invalid-argument');
    const session = await this.db.runTransaction(async tx => {
      const value = (await tx.get(this.db.doc(`uploadSessions/${sessionId}`))).data();
      if (!value || value.ownerId !== caller.uid) fail('not_upload_owner', 'permission-denied');
      await this.pair(tx, caller.uid, value.pairId, value.pairEpoch);
      if (value.status !== 'uploading' || value.expiresAt.toMillis() <= this.now()) fail('upload_expired');
      return value;
    });
    const asset = session.assets[role];
    if (bytes.length !== asset.byteCount || contentType !== asset.contentType || expectedHash !== asset.sha256 || digest(bytes) !== asset.sha256) fail('asset_integrity_mismatch', 'invalid-argument');
    const file = this.bucket.file(session.tempPaths[role]);
    try {await file.save(bytes, {metadata: {contentType, metadata: {sha256: expectedHash}}});}
    catch (error) {
      if ((error as {code?: number}).code !== 412) throw error;
      const [old] = await file.download();
      if (digest(old) !== expectedHash) fail('asset_integrity_mismatch');
    }
    return {uploaded: true};
  }
  async note(caller: Caller, input: Input): Promise<Input> {
    const pairId = identifier(input.pairId, 'pair_id'), pairEpoch = integer(input.pairEpoch, 'pair_epoch'), noteId = identifier(input.noteId, 'note_id');
    return this.db.runTransaction(async tx => {
      await this.pair(tx, caller.uid, pairId, pairEpoch);
      const value = (await tx.get(this.db.doc(`pairs/${pairId}/notes/${noteId}`))).data();
      if (!value) fail('note_unavailable', 'not-found');
      return {note: publicNote(value)};
    });
  }
  async latestReceivedNote(caller: Caller, input: Input): Promise<Input> {
    const pairId = identifier(input.pairId, 'pair_id'), pairEpoch = integer(input.pairEpoch, 'pair_epoch');
    return this.db.runTransaction(async tx => {
      await this.pair(tx, caller.uid, pairId, pairEpoch);
      const view = (await tx.get(this.db.doc(`pairs/${pairId}/views/${caller.uid}`))).data();
      const note = view?.latestNoteId ? (await tx.get(this.db.doc(`pairs/${pairId}/notes/${view.latestNoteId}`))).data() : undefined;
      return {note: note ? publicNote(note) : null};
    });
  }
  async timeline(caller: Caller, input: Input): Promise<Input> {
    const pairId = identifier(input.pairId, 'pair_id'), pairEpoch = integer(input.pairEpoch, 'pair_epoch');
    const maximum = input.limit === undefined ? 30 : integer(input.limit, 'limit');
    if (maximum > 50) fail('invalid_limit', 'invalid-argument');
    let cursor: {publishedAt: number; noteId: string} | undefined;
    if (input.cursor) {
      const value = input.cursor as Input;
      cursor = {publishedAt: integer(value.publishedAt, 'cursor_time'), noteId: identifier(value.noteId, 'cursor_note_id')};
    }
    await this.db.runTransaction(tx => this.pair(tx, caller.uid, pairId, pairEpoch));
    const rows = await this.db.notesPage(pairId, maximum + 1, cursor), visible = rows.slice(0, maximum), last = visible.at(-1);
    // Recheck after the read so closure concurrent with the page query fails closed.
    await this.db.runTransaction(tx => this.pair(tx, caller.uid, pairId, pairEpoch));
    return {notes: visible.map(publicNote), nextCursor: rows.length > maximum && last ? {publishedAt: last.publishedAt.toMillis(), noteId: last.id} : null};
  }
  async image(caller: Caller, path: string): Promise<Buffer> {
    const parts = path.split('/');
    if (parts.length !== 5 || parts[0] !== 'pairs' || !roles.includes(parts[4] as Role)) fail('invalid_asset_path', 'invalid-argument');
    const pairId = identifier(parts[1], 'pair_id'), pairEpoch = integer(Number(parts[2]), 'pair_epoch'), noteId = identifier(parts[3], 'note_id');
    const result = await this.note(caller, {pairId, pairEpoch, noteId});
    if ((result.note as DocumentData).paths[parts[4]!] !== path) fail('invalid_asset_path', 'permission-denied');
    const [bytes] = await this.bucket.file(path).download();
    await this.db.runTransaction(tx => this.pair(tx, caller.uid, pairId, pairEpoch));
    return bytes;
  }
  async cleanupExpiredUploads(): Promise<void> {
    // Extra hour beyond upload expiry bounds overlap with an in-flight, time-limited request.
    const cutoff = this.now() - 3600_000;
    const candidates = await this.db.collection('uploadSessions').where('cleanupDone', '==', false)
      .where('expiresAt', '<=', Timestamp.fromMillis(cutoff)).limit(20).get();
    for (const candidate of candidates.docs) {
      await this.db.runTransaction(async tx => {
        const value = (await tx.get(candidate.ref)).data();
        if (!value || value.cleanupDone || value.expiresAt.toMillis() > cutoff) return;
        const published = (await tx.get(this.db.doc(`pairs/${value.pairId}/notes/${value.noteId}`))).exists;
        if (!published) tx.update(candidate.ref, {status: 'expired', generation: (value.generation ?? 0) + 1});
        const paths = [...Object.values(value.tempPaths), ...(published ? [] : Object.values(value.finalPaths))] as string[];
        // Serialize deletion with explicit renewal. The small private app accepts this
        // bounded maintenance lock; scale-out needs per-session locks/queued GC instead.
        for (const path of paths) await this.bucket.file(path).delete();
        tx.update(candidate.ref, {cleanupDone: true});
      });
    }
  }
  async finalizeNote(caller: Caller, input: Input): Promise<Input> {
    const sessionId = identifier(input.sessionId, 'session_id'), pairId = identifier(input.pairId, 'pair_id'), pairEpoch = integer(input.pairEpoch, 'pair_epoch');
    const sessionRef = this.db.doc(`uploadSessions/${sessionId}`);
    const session = await this.db.runTransaction(async tx => {
      await this.pair(tx, caller.uid, pairId, pairEpoch);
      const value = (await tx.get(sessionRef)).data();
      if (!value || value.ownerId !== caller.uid || value.pairId !== pairId || value.pairEpoch !== pairEpoch) fail('not_upload_owner', 'permission-denied');
      if (value.status !== 'published' && value.expiresAt.toMillis() <= this.now()) fail('upload_expired');
      return value;
    });
    const noteRef = this.db.doc(`pairs/${pairId}/notes/${session.noteId}`);
    if (session.status === 'published') return {note: publicNote((await noteRef.get()).data()!)};
    await this.freeze(session);
    const note = await this.db.runTransaction(async tx => {
      const pair = await this.pair(tx, caller.uid, pairId, pairEpoch);
      const [fresh, existing] = await tx.getAll(sessionRef, noteRef);
      if (fresh!.data()?.status === 'published' && existing!.exists) return existing!.data()!;
      if (existing!.exists) fail('note_id_exists', 'already-exists');
      if (fresh!.data()!.generation !== session.generation) fail('upload_generation_changed', 'aborted');
      if (fresh!.data()!.expiresAt.toMillis() <= this.now()) fail('upload_expired');
      const recipientId = (pair.members as string[]).find(uid => uid !== caller.uid)!;
      const publishedAt = Timestamp.fromMillis(Math.max(this.now(), (pair.lastPublishedMillis as number) + 1));
      const value = {id: session.noteId, pairId, pairEpoch, authorId: caller.uid, recipientId, revision: session.revision,
        revisionHash: session.revisionHash, publishedAt, paths: session.finalPaths, widgetSHA256: session.assets.widget.sha256};
      tx.create(noteRef, value);
      tx.update(this.db.doc(`pairs/${pairId}`), {lastPublishedMillis: publishedAt.toMillis()});
      tx.update(sessionRef, {status: 'published'});
      tx.set(this.db.doc(`pairs/${pairId}/views/${recipientId}`), {latestNoteId: session.noteId, pairEpoch}, {merge: true});
      tx.create(this.db.doc(`notificationEvents/${digest(`${pairId}:${session.noteId}`)}`), {pairId, pairEpoch, noteId: session.noteId, recipientId, actorId: caller.uid,
        status: 'pending', attempts: 0, nextAttemptAt: publishedAt});
      return value;
    }).catch(async error => {
      if (error instanceof HttpsError && error.message === 'upload_generation_changed') {
        // A delayed old freeze may have written after GC. Schedule another cleanup;
        // the current session/metadata determine whether finals must be preserved.
        await sessionRef.update({cleanupDone: false});
      }
      throw error;
    });
    return {note: publicNote(note)};
  }
  async markNoteViewed(caller: Caller, input: Input): Promise<Input> {
    const pairId = identifier(input.pairId, 'pair_id'), pairEpoch = integer(input.pairEpoch, 'pair_epoch'), noteId = identifier(input.noteId, 'note_id');
    await this.db.runTransaction(async tx => {
      await this.pair(tx, caller.uid, pairId, pairEpoch);
      const note = (await tx.get(this.db.doc(`pairs/${pairId}/notes/${noteId}`))).data();
      if (!note || note.recipientId !== caller.uid) fail('not_note_recipient', 'permission-denied');
      tx.set(this.db.doc(`pairs/${pairId}/views/${caller.uid}`), {lastViewedNoteId: noteId, viewedAt: Timestamp.fromMillis(this.now())}, {merge: true});
    });
    return {};
  }
  async registerDevice(caller: Caller, input: Input): Promise<Input> {
    await this.rate(caller.uid, 'device', 30, 60_000);
    const deviceId = identifier(input.deviceId, 'device_id');
    const values: DocumentData = {deviceId, active: true};
    if (input.apnsToken !== undefined) {
      if (input.apnsToken === null) values.apnsToken = FieldValue.delete();
      else {
        const push = string(input.apnsToken, 'apns_token', 1024);
        if (!/^[0-9a-fA-F]+$/.test(push) || push.length % 2 !== 0) fail('invalid_apns_token', 'invalid-argument');
        values.apnsToken = push.toLowerCase();
      }
    }
    if (input.apnsEnvironment !== undefined) {
      if (!['development', 'production'].includes(String(input.apnsEnvironment))) fail('invalid_apns_environment', 'invalid-argument');
      values.apnsEnvironment = input.apnsEnvironment;
    }
    if (input.widgetPushEnvironment !== undefined) {
      if (!['development', 'production'].includes(String(input.widgetPushEnvironment))) fail('invalid_apns_environment', 'invalid-argument');
      values.widgetPushEnvironment = input.widgetPushEnvironment;
    }
    if (input.widgetPushToken !== undefined) {
      const push = string(input.widgetPushToken, 'widget_push_token', 1024);
      if (!/^[0-9a-fA-F]+$/.test(push) || push.length % 2 !== 0) fail('invalid_widget_push_token', 'invalid-argument');
      values.widgetPushToken = push.toLowerCase();
    }
    await this.db.runTransaction(async tx => {
      const userRef = this.db.doc(`users/${caller.uid}`);
      if (!(await tx.get(userRef)).exists) fail('profile_required');
      const binding = (await tx.get(this.db.doc(`installationSessions/${digest(deviceId)}`))).data();
      if (binding && (binding.uid !== caller.uid || binding.sessionId !== caller.sessionId)) fail('installation_session_changed', 'permission-denied');
      const devices = await tx.get(this.db.collection(`users/${caller.uid}/devices`).limit(11));
      if (!devices.docs.some(device => device.id === deviceId) && devices.size >= 10) fail('device_limit', 'resource-exhausted');
      const installation = this.db.doc(`deviceOwners/${digest(deviceId)}`), previous = (await tx.get(installation)).data();
      if (previous && previous.uid !== caller.uid) {
        await revokeLocationDevice(this.db, tx, previous.uid, previous.deviceId);
        tx.delete(this.db.doc(`users/${previous.uid}/devices/${previous.deviceId}`));
      }
      tx.set(installation, {uid: caller.uid, deviceId});
      const existing = devices.docs.find(device => device.id === deviceId)?.data() ?? {};
      const merged = {...existing, ...values};
      if (typeof merged.apnsToken === 'string') await this.claimPushToken(tx, caller.uid, deviceId, 'apnsToken', merged.apnsToken, merged.apnsEnvironment);
      if (typeof merged.widgetPushToken === 'string') await this.claimPushToken(tx, caller.uid, deviceId, 'widgetPushToken', merged.widgetPushToken, merged.widgetPushEnvironment ?? merged.apnsEnvironment);
      // Serialize concurrent registrations via the parent user as well as the query read.
      tx.update(userRef, {deviceUpdatedAt: Timestamp.fromMillis(this.now())});
      tx.set(this.db.doc(`users/${caller.uid}/devices/${deviceId}`), values, {merge: true});
    });
    return {};
  }
  private async claimPushToken(tx: Transaction, uid: string, deviceId: string, field: 'apnsToken' | 'widgetPushToken', pushToken: string, environment: unknown): Promise<void> {
    if (!['development', 'production'].includes(String(environment))) return;
    const ref = this.db.doc(`pushTokenOwners/${digest(`${field}:${environment}:${pushToken}`)}`), previous = (await tx.get(ref)).data();
    if (previous && (previous.uid !== uid || previous.deviceId !== deviceId)) {
      const oldRef = this.db.doc(`users/${previous.uid}/devices/${previous.deviceId}`), old = (await tx.get(oldRef)).data();
      const oldEnvironment = field === 'widgetPushToken' ? (old?.widgetPushEnvironment ?? old?.apnsEnvironment) : old?.apnsEnvironment;
      // Ownership rows for rotated tokens may be stale: never remove an unrelated new registration.
      if (old?.[field] === pushToken && oldEnvironment === environment) {
        await revokeLocationDevice(this.db, tx, previous.uid, previous.deviceId);
        tx.delete(oldRef);
      }
    }
    tx.set(ref, {uid, deviceId});
  }
  async unregisterDevice(caller: Caller, input: Input): Promise<Input> {
    const deviceId = identifier(input.deviceId, 'device_id');
    await this.db.runTransaction(async tx => {
      await revokeLocationDevice(this.db, tx, caller.uid, deviceId);
      tx.delete(this.db.doc(`users/${caller.uid}/devices/${deviceId}`));
    });
    return {};
  }
  async issueWidgetSession(caller: Caller, input: Input): Promise<Input> {
    const deviceId = identifier(input.deviceId, 'device_id'), secret = token(), hash = digest(secret), expiresAt = this.now() + 30 * 86_400_000;
    await this.rate(caller.uid, 'widget_session', 20, 60_000);
    await this.db.runTransaction(async tx => {
      const user = (await tx.get(this.db.doc(`users/${caller.uid}`))).data();
      if (!user?.activePairId) fail('not_paired');
      const pair = await this.pair(tx, caller.uid, user.activePairId);
      const deviceRef = this.db.doc(`users/${caller.uid}/devices/${deviceId}`), device = (await tx.get(deviceRef)).data();
      if (!device?.active) fail('device_unavailable');
      tx.set(this.db.doc(`widgetSessions/${hash}`), {uid: caller.uid, deviceId, pairId: user.activePairId, pairEpoch: pair.pairEpoch, expiresAt: Timestamp.fromMillis(expiresAt)});
      tx.update(deviceRef, {widgetSessionHash: hash});
    });
    return {token: secret, expiresAt};
  }
  private async widgetState(secret: string): Promise<DocumentData> {
    if (!/^[a-zA-Z0-9_-]{43}$/.test(secret)) fail('widget_session_unavailable', 'unauthenticated');
    return this.db.runTransaction(async tx => {
      const hash = digest(secret), session = (await tx.get(this.db.doc(`widgetSessions/${hash}`))).data();
      if (!session || session.expiresAt.toMillis() <= this.now()) fail('widget_session_unavailable', 'unauthenticated');
      const pair = await this.pair(tx, session.uid, session.pairId, session.pairEpoch);
      const device = (await tx.get(this.db.doc(`users/${session.uid}/devices/${session.deviceId}`))).data();
      if (!device?.active || device.widgetSessionHash !== hash) fail('widget_session_unavailable', 'unauthenticated');
      const view = (await tx.get(this.db.doc(`pairs/${session.pairId}/views/${session.uid}`))).data();
      const note = view?.latestNoteId ? (await tx.get(this.db.doc(`pairs/${session.pairId}/notes/${view.latestNoteId}`))).data() : null;
      const profile = note ? (await tx.get(this.db.doc(`pairs/${session.pairId}/profiles/${note.authorId}`))).data() : null;
      const space = await this.couple.space(tx, session.uid, pair);
      // Renew the device-scoped credential on successful use. Pair closure,
      // sign-out and device revocation are still checked on every request.
      const credentialExpiresAt = this.now() + 30 * 86_400_000;
      tx.update(this.db.doc(`widgetSessions/${hash}`), {expiresAt: Timestamp.fromMillis(credentialExpiresAt)});
      return {schemaVersion: 1, pairId: session.pairId, pairEpoch: session.pairEpoch, note: note ? publicNote(note) : null,
        authorDisplayName: profile?.displayName ?? null, imageSHA256: note?.widgetSHA256 ?? null, generatedAt: this.now(),
        credentialExpiresAt, validUntil: this.now() + 24 * 60 * 60_000, uid: session.uid, deviceId: session.deviceId,
        latestPhoto: space.latestPhoto, latestGesture: space.latestGesture, personalization: space.personalization, profiles: space.profiles, startedOn: space.startedOn, latestMessage: space.latestMessage, distance: space.location.distance};
    });
  }
  async widgetSnapshot(secret: string): Promise<DocumentData> {
    const state = await this.widgetState(secret), note = state.note;
    return {schemaVersion: 1, pairId: state.pairId, pairEpoch: state.pairEpoch, generatedAt: state.generatedAt, validUntil: state.validUntil, credentialExpiresAt: state.credentialExpiresAt,
      latestPhoto: state.latestPhoto, latestGesture: state.latestGesture, personalization: state.personalization, profiles: state.profiles, startedOn: state.startedOn, latestMessage: state.latestMessage, distance: state.distance,
      note: note ? {id: note.id, revision: note.revision, revisionHash: note.revisionHash, publishedAt: note.publishedAt,
        authorDisplayName: state.authorDisplayName, imageSHA256: state.imageSHA256} : null};
  }
  async widgetPushRegistration(secret: string, input: Input): Promise<Input> {
    if (typeof input.enabled !== 'boolean') fail('invalid_enabled', 'invalid-argument');
    const push = string(input.token, 'widget_push_token', 1024);
    if (!/^[0-9a-fA-F]+$/.test(push) || push.length % 2 !== 0) fail('invalid_widget_push_token', 'invalid-argument');
    if (input.environment !== undefined && !['development', 'production'].includes(String(input.environment))) fail('invalid_apns_environment', 'invalid-argument');
    const hash = digest(secret);
    await this.db.runTransaction(async tx => {
      const session = (await tx.get(this.db.doc(`widgetSessions/${hash}`))).data();
      if (!session || session.expiresAt.toMillis() <= this.now()) fail('widget_session_unavailable', 'unauthenticated');
      await this.pair(tx, session.uid, session.pairId, session.pairEpoch);
      const ref = this.db.doc(`users/${session.uid}/devices/${session.deviceId}`), device = (await tx.get(ref)).data();
      if (!device?.active || device.widgetSessionHash !== hash) fail('widget_session_unavailable', 'unauthenticated');
      // A stale removal callback must not remove a newer token.
      if (input.enabled) {
        await this.claimPushToken(tx, session.uid, session.deviceId, 'widgetPushToken', push.toLowerCase(), input.environment ?? device.widgetPushEnvironment ?? device.apnsEnvironment);
        tx.update(ref, {widgetPushToken: push.toLowerCase(), ...(input.environment ? {widgetPushEnvironment: input.environment} : {})});
      }
      else if (device.widgetPushToken === push.toLowerCase()) tx.update(ref, {widgetPushToken: null});
    });
    return {};
  }
  async widgetImage(secret: string, noteId: string): Promise<Buffer> {
    const snapshot = await this.widgetState(secret);
    if (!snapshot.note || snapshot.note.id !== noteId) fail('latest_note_changed', 'aborted');
    const [bytes] = await this.bucket.file(snapshot.note.paths.widget).download();
    if (digest(bytes) !== snapshot.imageSHA256) fail('asset_integrity_mismatch');
    const fresh = await this.widgetState(secret);
    if (!fresh.note || fresh.note.id !== noteId) fail('latest_note_changed', 'aborted');
    return bytes;
  }
  async widgetAvatar(secret: string, uid: string, avatarId?: string): Promise<Buffer> {
    const state = await this.widgetState(secret);
    if (!state.profiles.some((profile: DocumentData) => profile.uid === uid)) fail('not_pair_member', 'permission-denied');
    const bytes = await this.couple.avatar({uid: state.uid, authTime: 0}, uid, avatarId);
    const fresh = await this.widgetState(secret);
    if (fresh.pairId !== state.pairId || fresh.pairEpoch !== state.pairEpoch) fail('stale_pair_epoch', 'permission-denied');
    return bytes;
  }
  async widgetPhoto(secret: string, photoId: string, assetId: string): Promise<Buffer> {
    const state = await this.widgetState(secret);
    if (!state.latestPhoto || state.latestPhoto.id !== photoId || state.latestPhoto.photo.id !== assetId) fail('latest_photo_changed', 'aborted');
    const bytes = await this.photos.image({uid: state.uid, authTime: 0}, {pairId: state.pairId, pairEpoch: state.pairEpoch, photoId, assetId});
    const fresh = await this.widgetState(secret);
    if (fresh.pairId !== state.pairId || fresh.pairEpoch !== state.pairEpoch || fresh.latestPhoto?.id !== photoId || fresh.latestPhoto?.photo.id !== assetId) fail('latest_photo_changed', 'aborted');
    return bytes;
  }
  async widgetPhotoReaction(secret: string, input: Input): Promise<Input> {
    const state = await this.widgetState(secret);
    const hash = digest(secret);
    // Resolve the credential inside the same transaction as the mutation, so
    // rotation/revocation cannot race a previously authorized widget button.
    return this.photos.setReaction({uid: state.uid, authTime: 0}, {...input, pairId: state.pairId, pairEpoch: state.pairEpoch}, true, async tx => {
      const session = (await tx.get(this.db.doc(`widgetSessions/${hash}`))).data();
      if (!session || session.expiresAt.toMillis() <= this.now() || session.uid !== state.uid || session.pairId !== state.pairId || session.pairEpoch !== state.pairEpoch) fail('widget_session_unavailable', 'unauthenticated');
      const device = (await tx.get(this.db.doc(`users/${session.uid}/devices/${session.deviceId}`))).data();
      if (!device?.active || device.widgetSessionHash !== hash) fail('widget_session_unavailable', 'unauthenticated');
    });
  }
}
