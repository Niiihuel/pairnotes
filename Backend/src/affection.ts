import {randomUUID} from 'node:crypto';
import {Caller, PairNotesService, digest, fail} from './service';
import {DocumentData, Transaction, Timestamp} from './database';

type Input = Record<string, unknown>;
const identifier = (value: unknown): string => {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value)) fail('invalid_id', 'invalid-argument');
  return value;
};
const integer = (value: unknown): number => {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1) fail('invalid_number', 'invalid-argument');
  return value;
};
const text = (value: unknown, maximum: number, empty = false): string => {
  if (typeof value !== 'string' || value.length > maximum || (!empty && !value.trim())) fail('invalid_text', 'invalid-argument');
  return value.trim();
};
const scope = (input: Input) => ({pairId: identifier(input.pairId), pairEpoch: integer(input.pairEpoch)});
const publicGesture = (value: DocumentData) => ({id: value.id, authorId: value.authorId, recipientId: value.recipientId,
  kind: value.kind, replyTo: value.replyTo ?? null, sentAt: value.sentAt.toMillis()});
const asset = (value: DocumentData | undefined) => value ? {id: value.id, sha256: value.sha256, duration: value.duration ?? null} : null;

/** Only PCM produced by the app is accepted; normalize to a metadata-free WAV. */
export function normalizeVoice(bytes: Buffer): {bytes: Buffer; duration: number} {
  if (bytes.length < 44 || bytes.length > 2_000_000 || bytes.toString('ascii', 0, 4) !== 'RIFF' ||
      bytes.toString('ascii', 8, 12) !== 'WAVE' || bytes.readUInt32LE(4) + 8 !== bytes.length) fail('invalid_audio', 'invalid-argument');
  let format: Buffer | undefined, data: Buffer | undefined, offset = 12;
  while (offset + 8 <= bytes.length) {
    const kind = bytes.toString('ascii', offset, offset + 4), count = bytes.readUInt32LE(offset + 4);
    offset += 8;
    if (offset + count > bytes.length) fail('invalid_audio', 'invalid-argument');
    if (kind === 'fmt ') {if (format) fail('invalid_audio', 'invalid-argument'); format = bytes.subarray(offset, offset + count);}
    if (kind === 'data') {if (data) fail('invalid_audio', 'invalid-argument'); data = bytes.subarray(offset, offset + count);}
    offset += count + count % 2;
  }
  if (offset !== bytes.length || !format || format.length < 16 || !data || !data.length || data.length % 2 ||
      format.readUInt16LE(0) !== 1 || format.readUInt16LE(2) !== 1 || format.readUInt32LE(4) !== 16000 ||
      format.readUInt32LE(8) !== 32000 || format.readUInt16LE(12) !== 2 || format.readUInt16LE(14) !== 16 ||
      data.length > 60 * 32000) fail('invalid_audio', 'invalid-argument');
  const header = Buffer.alloc(44);
  header.write('RIFF'); header.writeUInt32LE(36 + data.length, 4); header.write('WAVEfmt ', 8);
  header.writeUInt32LE(16, 16); format.copy(header, 20, 0, 16); header.write('data', 36); header.writeUInt32LE(data.length, 40);
  return {bytes: Buffer.concat([header, data]), duration: data.length / 32000};
}

export class AffectionFeatures {
  constructor(readonly service: PairNotesService) {}
  get db() {return this.service.db;}
  private event(tx: Transaction, pair: DocumentData, recipientId: string, actorId: string, type: string, id: string, due = this.service.now()) {
    tx.create(this.db.doc(`notificationEvents/${digest(`${pair.id}:${type}:${id}`)}`), {
      pairId: pair.id, pairEpoch: pair.pairEpoch, recipientId, actorId, type,
      ...(type === 'gesture' ? {gestureId: id} : {letterId: id}),
      status: 'pending', attempts: 0, nextAttemptAt: Timestamp.fromMillis(due)
    });
  }
  async latestGesture(tx: Transaction, uid: string, pair: DocumentData): Promise<DocumentData | null> {
    const view = (await tx.get(this.db.doc(`pairs/${pair.id}/views/${uid}`))).data();
    const value = view?.latestGestureId ? (await tx.get(this.db.doc(`pairs/${pair.id}/gestures/${view.latestGestureId}`))).data() : null;
    return value ? publicGesture(value) : null;
  }
  async sendGesture(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), id = identifier(input.gestureId);
    const kind = text(input.kind, 16), replyTo = input.replyTo == null ? null : identifier(input.replyTo);
    if (!['heart', 'hug', 'kiss'].includes(kind)) fail('invalid_gesture', 'invalid-argument');
    await this.service.rate(caller.uid, 'gesture', 12, 60_000);
    return this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const ref = this.db.doc(`pairs/${pairId}/gestures/${id}`), old = (await tx.get(ref)).data();
      if (old) {
        if (old.authorId !== caller.uid || old.kind !== kind || old.replyTo !== replyTo) fail('idempotency_conflict', 'already-exists');
        return {gesture: publicGesture(old)};
      }
      if (replyTo) {
        const previous = (await tx.get(this.db.doc(`pairs/${pairId}/gestures/${replyTo}`))).data();
        if (previous?.recipientId !== caller.uid) fail('gesture_unavailable', 'not-found');
      }
      const recipientId = pair.members.find((uid: string) => uid !== caller.uid);
      const sentAt = Timestamp.fromMillis(Math.max(this.service.now(), (pair.lastGestureMillis ?? 0) + 1));
      const gesture = {id, authorId: caller.uid, recipientId, kind, replyTo, sentAt};
      tx.create(ref, gesture); tx.update(this.db.doc(`pairs/${pairId}`), {lastGestureMillis: sentAt.toMillis()});
      for (const uid of pair.members) tx.set(this.db.doc(`pairs/${pairId}/views/${uid}`), {latestGestureId: id}, {merge: true});
      this.event(tx, pair, recipientId, caller.uid, 'gesture', id);
      return {gesture: publicGesture(gesture)};
    });
  }
  async reactions(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), noteId = identifier(input.noteId);
    return this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      if (!(await tx.get(this.db.doc(`pairs/${pairId}/notes/${noteId}`))).exists) fail('note_unavailable', 'not-found');
      const rows = await tx.get(this.db.collection(`pairs/${pairId}/notes/${noteId}/reactions`).limit(2));
      return {reactions: rows.docs.map(row => ({...row.data(), updatedAt: row.data()!.updatedAt.toMillis()}))};
    });
  }
  async setReaction(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), noteId = identifier(input.noteId);
    const kind = text(input.kind, 16, true), reply = text(input.reply, 280, true);
    if (!['', 'heart', 'hug', 'sparkles'].includes(kind)) fail('invalid_reaction', 'invalid-argument');
    await this.service.rate(caller.uid, 'reaction', 20, 60_000);
    await this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const note = (await tx.get(this.db.doc(`pairs/${pairId}/notes/${noteId}`))).data();
      if (!note || note.recipientId !== caller.uid) fail('not_note_recipient', 'permission-denied');
      const ref = this.db.doc(`pairs/${pairId}/notes/${noteId}/reactions/${caller.uid}`), old = (await tx.get(ref)).data();
      if (!kind && !reply) {tx.delete(ref); return;}
      if (old?.kind === kind && old?.reply === reply) return;
      tx.set(ref, {id: caller.uid, authorId: caller.uid, noteId, kind, reply, updatedAt: Timestamp.fromMillis(this.service.now())});
      tx.create(this.db.doc(`notificationEvents/${randomUUID()}`), {pairId, pairEpoch, recipientId: note.authorId, actorId: caller.uid,
        type: 'reaction', noteId, status: 'pending', attempts: 0, nextAttemptAt: Timestamp.fromMillis(this.service.now())});
    });
    return this.reactions(caller, input);
  }
  private publicLetter(value: DocumentData, uid: string): DocumentData {
    const canOpen = value.status === 'sealed' && value.opensAt <= this.service.now();
    const visible = uid === value.authorId || canOpen;
    return {id: value.id, authorId: value.authorId, recipientId: value.recipientId, status: value.status,
      opensAt: value.opensAt, createdAt: value.createdAt.toMillis(),
      sentAt: value.status === 'sealed' ? (value.sealedAt ?? value.createdAt).toMillis() : null,
      openedAt: value.openedAt?.toMillis() ?? null, canOpen,
      // Deliberately omit every content field before opening time, including attachment IDs.
      ...(visible ? {title: value.title, body: value.body, noteId: value.noteId, photo: asset(value.photo), drawing: asset(value.drawing), audio: asset(value.audio)} : {})};
  }
  private async authorizedLetter(tx: Transaction, caller: Caller, input: Input): Promise<DocumentData> {
    const {pairId, pairEpoch} = scope(input), id = identifier(input.letterId);
    await this.service.pair(tx, caller.uid, pairId, pairEpoch);
    const value = (await tx.get(this.db.doc(`pairs/${pairId}/letters/${id}`))).data();
    if (!value || (value.status === 'draft' && value.authorId !== caller.uid)) fail('letter_unavailable', 'not-found');
    return value;
  }
  async letters(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input);
    return this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const rows = await tx.get(this.db.collection(`pairs/${pairId}/letters`).orderBy('createdAt', 'desc').limit(200));
      return {letters: rows.docs.map(row => row.data()!).filter(value => value.status === 'sealed' || value.authorId === caller.uid)
        .map(value => this.publicLetter(value, caller.uid)), serverNow: this.service.now()};
    });
  }
  async letterHistory(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), maximum = input.limit === undefined ? 30 : input.limit;
    if (typeof maximum !== 'number' || !Number.isSafeInteger(maximum) || maximum < 1 || maximum > 50) fail('invalid_limit', 'invalid-argument');
    let cursor: {sentAt: number; letterId: string} | undefined;
    if (input.cursor !== undefined && input.cursor !== null) {
      const value = input.cursor;
      if (typeof value !== 'object' || Array.isArray(value)) fail('invalid_cursor', 'invalid-argument');
      const {sentAt, letterId} = value as Input;
      if (typeof sentAt !== 'number' || !Number.isSafeInteger(sentAt) || sentAt < 1) fail('invalid_cursor_time', 'invalid-argument');
      cursor = {sentAt, letterId: identifier(letterId)};
    }
    await this.db.runTransaction(tx => this.service.pair(tx, caller.uid, pairId, pairEpoch));
    const rows = await this.db.lettersPage(pairId, maximum + 1, cursor);
    // Legacy letters have no epoch field. Both checks authorize the containing pair's current generation.
    await this.db.runTransaction(tx => this.service.pair(tx, caller.uid, pairId, pairEpoch));
    const visible = rows.slice(0, maximum), last = visible.at(-1);
    return {letters: visible.map(value => this.publicLetter(value, caller.uid)), serverNow: this.service.now(),
      nextCursor: rows.length > maximum && last ? {sentAt: (last.sealedAt ?? last.createdAt).toMillis(), letterId: last.id} : null};
  }
  async saveLetterDraft(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), id = identifier(input.letterId);
    const title = text(input.title, 120), body = text(input.body, 6000, true), opensAt = integer(input.opensAt);
    const noteId = input.noteId == null ? null : identifier(input.noteId);
    if (opensAt > this.service.now() + 5 * 366 * 86_400_000) fail('invalid_opening_date', 'invalid-argument');
    await this.service.rate(caller.uid, 'letter', 30, 60_000);
    return this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const ref = this.db.doc(`pairs/${pairId}/letters/${id}`), old = (await tx.get(ref)).data();
      if (old && old.authorId !== caller.uid) fail('not_letter_author', 'permission-denied');
      if (old?.status === 'sealed') fail('letter_sealed', 'already-exists');
      if (noteId && !(await tx.get(this.db.doc(`pairs/${pairId}/notes/${noteId}`))).exists) fail('note_unavailable', 'not-found');
      const value = {id, authorId: caller.uid, recipientId: pair.members.find((uid: string) => uid !== caller.uid),
        status: 'draft', title, body, opensAt, noteId, photo: old?.photo ?? null, drawing: old?.drawing ?? null, audio: old?.audio ?? null,
        createdAt: old?.createdAt ?? Timestamp.fromMillis(this.service.now()), openedAt: null};
      tx.set(ref, value); return {letter: this.publicLetter(value, caller.uid)};
    });
  }
  async sealLetter(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input);
    if (input.immediate !== undefined && typeof input.immediate !== 'boolean') fail('invalid_immediate', 'invalid-argument');
    return this.db.runTransaction(async tx => {
      const value = await this.authorizedLetter(tx, caller, input);
      if (value.authorId !== caller.uid) fail('not_letter_author', 'permission-denied');
      if (value.status === 'sealed') return {letter: this.publicLetter(value, caller.uid)};
      const sealedAt = Timestamp.fromMillis(this.service.now());
      const opensAt = input.immediate === true ? sealedAt.toMillis() : value.opensAt;
      if (input.immediate !== true && opensAt <= sealedAt.toMillis()) fail('opening_date_passed', 'invalid-argument');
      if (!value.body && !value.photo && !value.drawing && !value.audio && !value.noteId) fail('empty_letter', 'invalid-argument');
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const sealed = {...value, status: 'sealed', opensAt, sealedAt};
      tx.set(this.db.doc(`pairs/${pairId}/letters/${value.id}`), sealed);
      this.event(tx, pair, value.recipientId, caller.uid, 'letter', value.id, opensAt);
      return {letter: this.publicLetter(sealed, caller.uid)};
    });
  }
  async openLetter(caller: Caller, input: Input): Promise<Input> {
    const {pairId} = scope(input);
    return this.db.runTransaction(async tx => {
      const value = await this.authorizedLetter(tx, caller, input);
      if (value.authorId !== caller.uid && (value.status !== 'sealed' || value.opensAt > this.service.now())) fail('letter_locked', 'permission-denied');
      if (value.recipientId === caller.uid && !value.openedAt) {
        value.openedAt = Timestamp.fromMillis(this.service.now());
        tx.update(this.db.doc(`pairs/${pairId}/letters/${value.id}`), {openedAt: value.openedAt});
      }
      return {letter: this.publicLetter(value, caller.uid)};
    });
  }
  async deleteLetterDraft(caller: Caller, input: Input): Promise<Input> {
    const {pairId} = scope(input);
    await this.db.runTransaction(async tx => {
      const value = await this.authorizedLetter(tx, caller, input);
      if (value.authorId !== caller.uid || value.status !== 'draft') fail('letter_sealed', 'permission-denied');
      for (const reference of [value.photo, value.drawing, value.audio]) if (reference) this.service.couple.retireImage(tx, reference.id);
      tx.delete(this.db.doc(`pairs/${pairId}/letters/${value.id}`));
    });
    return {};
  }
  async letterAsset(caller: Caller, input: Input, role: 'photo' | 'drawing' | 'audio', bytes?: Buffer, contentType?: string): Promise<Buffer | Input> {
    const {pairId} = scope(input);
    const read = () => this.db.runTransaction(tx => this.authorizedLetter(tx, caller, input));
    const old = await read();
    if (bytes) {
      if (old.authorId !== caller.uid || old.status !== 'draft') fail('letter_sealed', 'permission-denied');
      await this.service.rate(caller.uid, 'letter_asset', 12, 60_000);
      const normalized = role !== 'audio'
        ? {bytes: await this.service.couple.normalizeImage(bytes, contentType ?? '', false), duration: undefined}
        : normalizeVoice(bytes);
      if (role === 'audio' && contentType !== 'audio/wav') fail('invalid_audio', 'invalid-argument');
      const staged = await this.service.couple.stageImage(caller.uid, normalized.bytes, role !== 'audio' ? 'image/png' : 'audio/wav');
      return this.db.runTransaction(async tx => {
        const current = await this.authorizedLetter(tx, caller, input);
        if (current.authorId !== caller.uid || current.status !== 'draft') fail('letter_sealed', 'permission-denied');
        await this.service.couple.attachImage(tx, staged);
        if (current[role]) this.service.couple.retireImage(tx, current[role].id);
        const value = {...current, [role]: {...staged, duration: normalized.duration ?? null}};
        tx.set(this.db.doc(`pairs/${pairId}/letters/${current.id}`), value);
        return {letter: this.publicLetter(value, caller.uid)};
      }).catch(async error => {await this.service.couple.abandonImage(staged); throw error;});
    }
    if (old.authorId !== caller.uid && (old.status !== 'sealed' || old.opensAt > this.service.now())) fail('letter_locked', 'permission-denied');
    if (!old[role]) fail('asset_unavailable', 'not-found');
    if (input.assetId !== old[role].id) fail('asset_changed', 'aborted');
    const [data] = await this.service.bucket.file(old[role].path).download();
    const fresh = await read();
    if (fresh[role]?.id !== old[role].id) fail('asset_changed', 'aborted');
    if (fresh.authorId !== caller.uid && (fresh.status !== 'sealed' || fresh.opensAt > this.service.now())) fail('letter_locked', 'permission-denied');
    if (digest(data) !== fresh[role].sha256) fail('asset_integrity_mismatch');
    return data;
  }
  async removeLetterAsset(caller: Caller, input: Input): Promise<Input> {
    const {pairId} = scope(input), role = input.role;
    if (role !== 'photo' && role !== 'drawing' && role !== 'audio') fail('invalid_role', 'invalid-argument');
    return this.db.runTransaction(async tx => {
      const value = await this.authorizedLetter(tx, caller, input);
      if (value.authorId !== caller.uid || value.status !== 'draft') fail('letter_sealed', 'permission-denied');
      if (value[role]) this.service.couple.retireImage(tx, value[role].id);
      value[role] = null; tx.set(this.db.doc(`pairs/${pairId}/letters/${value.id}`), value);
      return {letter: this.publicLetter(value, caller.uid)};
    });
  }
}
