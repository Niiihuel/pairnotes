import {randomUUID} from 'node:crypto';
import sharp from 'sharp';
import {DocumentData, Timestamp, Transaction} from './database';
import {Caller, PairNotesService, digest, fail} from './service';

type Input = Record<string, unknown>;
const freshness = 15 * 60_000, retention = 30 * 60_000;
const numeric = (value: unknown, minimum: number, maximum: number, name: string): number => {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) fail(`invalid_${name}`, 'invalid-argument');
  return value;
};
const id = (value: unknown, name: string): string => {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value)) fail(`invalid_${name}`, 'invalid-argument');
  return value;
};
const positive = (value: unknown, name: string): number => {
  const result = numeric(value, 1, Number.MAX_SAFE_INTEGER, name);
  if (!Number.isSafeInteger(result)) fail(`invalid_${name}`, 'invalid-argument');
  return result;
};
function text(value: unknown, name: string, maximum: number, empty = false): string {
  if (typeof value !== 'string' || value.length > maximum || (!empty && !value.trim())) fail(`invalid_${name}`, 'invalid-argument');
  return value.trim();
}
function dateOnly(value: unknown): string {
  if (typeof value !== 'string' || !/^(?!0000)[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) fail('invalid_date', 'invalid-argument');
  const date = new Date(`${value}T00:00:00Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== value) fail('invalid_date', 'invalid-argument');
  return value;
}
function pairInput(input: Input): {pairId: string; pairEpoch: number} {
  return {pairId: id(input.pairId, 'pair_id'), pairEpoch: positive(input.pairEpoch, 'pair_epoch')};
}
export function publicProfile(value: DocumentData): DocumentData {
  return {uid: value.uid, displayName: value.displayName ?? '', avatar: value.avatar ? {id: value.avatar.id, sha256: value.avatar.sha256} : null};
}
function publicMemory(value: DocumentData): DocumentData {
  return {id: value.id, pairId: value.pairId, pairEpoch: value.pairEpoch, authorId: value.authorId,
    title: value.title, date: value.date, kind: value.kind, recursYearly: value.recursYearly,
    decoration: value.decoration ?? null,
    body: value.body, noteId: value.noteId ?? null, photo: value.photo ? {id: value.photo.id, sha256: value.photo.sha256} : null,
    createdAt: value.createdAt.toMillis(), updatedAt: value.updatedAt.toMillis()};
}
function publicMessage(value: DocumentData): DocumentData {return {...value, sentAt: value.sentAt.toMillis()};}

/** Additive couple features; private coordinates and storage keys never cross the API. */
export class CoupleFeatures {
  constructor(readonly service: PairNotesService) {}
  get db() {return this.service.db;}
  private notifyWidgets(tx: Transaction, pair: DocumentData): void {
    for (const recipientId of pair.members as string[]) {
      tx.create(this.db.doc(`notificationEvents/${randomUUID()}`), {
        type: 'widget', pairId: pair.id, pairEpoch: pair.pairEpoch, recipientId,
        status: 'pending', attempts: 0, nextAttemptAt: Timestamp.fromMillis(this.service.now())
      });
    }
  }
  async space(tx: Transaction, uid: string, pair: DocumentData): Promise<DocumentData> {
    const profiles = await tx.getAll(...(pair.members as string[]).map(member => this.db.doc(`users/${member}`)));
    const view = (await tx.get(this.db.doc(`pairs/${pair.id}/views/${uid}`))).data();
    const latest = view?.latestMessageId ? (await tx.get(this.db.doc(`pairs/${pair.id}/messages/${view.latestMessageId}`))).data() : null;
    return {profiles: profiles.map(profile => publicProfile({...profile.data(), uid: profile.id})), startedOn: pair.startedOn ?? null,
      latestGesture: await this.service.affection.latestGesture(tx, uid, pair), personalization: pair.personalization ?? null, latestMessage: latest ? publicMessage(latest) : null, location: await this.location(tx, uid, pair)};
  }
  async getCoupleSpace(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input);
    return this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const memories = await tx.get(this.db.collection(`pairs/${pairId}/memories`).orderBy('date').limit(200));
      return {...await this.space(tx, caller.uid, pair), memories: memories.docs.map(item => publicMemory(item.data()!))};
    });
  }
  async updatePersonalization(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input);
    const theme = text(input.theme, 'theme', 20), phrase = text(input.phrase, 'phrase', 160, true);
    if (!['cream', 'rose', 'lavender', 'night'].includes(theme)) fail('invalid_theme', 'invalid-argument');
    if (!Array.isArray(input.homeOrder) || input.homeOrder.length !== 4 ||
        new Set(input.homeOrder).size !== 4 || !input.homeOrder.every(value => ['story', 'message', 'drawing', 'distance'].includes(value))) {
      fail('invalid_home_order', 'invalid-argument');
    }
    const homeOrder = input.homeOrder as string[];
    const coverMemoryId = input.coverMemoryId === null ? null : id(input.coverMemoryId, 'cover_memory_id');
    const revision = numeric(input.revision, 0, Number.MAX_SAFE_INTEGER - 1, 'revision');
    if (!Number.isSafeInteger(revision)) fail('invalid_revision', 'invalid-argument');
    if (!input.nicknames || typeof input.nicknames !== 'object' || Array.isArray(input.nicknames)) fail('invalid_nicknames', 'invalid-argument');
    await this.service.rate(caller.uid, 'personalization', 20, 60_000);
    return this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      if ((pair.personalization?.revision ?? 0) !== revision) fail('personalization_changed', 'aborted');
      const nicknames: Record<string, string> = {};
      for (const [uid, nickname] of Object.entries(input.nicknames as Input)) {
        if (!pair.members.includes(uid)) fail('invalid_nickname_member', 'invalid-argument');
        nicknames[uid] = text(nickname, 'nickname', 40, true);
      }
      if (coverMemoryId && !(await tx.get(this.db.doc(`pairs/${pairId}/memories/${coverMemoryId}`))).data()?.photo) {
        fail('cover_unavailable', 'not-found');
      }
      const personalization = {theme, phrase, nicknames, coverMemoryId, homeOrder, revision: revision + 1};
      tx.update(this.db.doc(`pairs/${pairId}`), {personalization});
      this.notifyWidgets(tx, pair);
      return {personalization};
    });
  }
  async updatePairDetails(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input);
    const startedOn = input.startedOn === null ? null : dateOnly(input.startedOn);
    let today: string;
    try {
      const timeZone = input.timeZone === undefined ? 'UTC' : text(input.timeZone, 'time_zone', 80);
      const parts = new Intl.DateTimeFormat('en-US', {timeZone, year: 'numeric', month: '2-digit', day: '2-digit'})
        .formatToParts(new Date(this.service.now()));
      today = ['year', 'month', 'day'].map(name => parts.find(part => part.type === name)!.value).join('-');
    } catch {fail('invalid_time_zone', 'invalid-argument');}
    if (startedOn && startedOn > today) fail('future_pair_date', 'invalid-argument');
    await this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      tx.update(this.db.doc(`pairs/${pairId}`), {startedOn});
      if (pair.startedOn !== startedOn) this.notifyWidgets(tx, pair);
    });
    return {pair: await this.service.pairResponse(caller.uid, pairId)};
  }
  async upsertMemory(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input), memoryId = id(input.memoryId, 'memory_id');
    const title = text(input.title, 'title', 120), date = dateOnly(input.date);
    if (!['date', 'memory'].includes(String(input.kind))) fail('invalid_memory_kind', 'invalid-argument');
    if (input.recursYearly !== undefined && typeof input.recursYearly !== 'boolean') fail('invalid_recurs_yearly', 'invalid-argument');
    const decoration = input.decoration;
    if (decoration !== undefined && (decoration === null || typeof decoration !== 'object' || Array.isArray(decoration) ||
        !['polaroid', 'postcard', 'journal'].includes(String((decoration as Input).layout)) ||
        !['', 'heart', 'sparkles', 'flower', 'star', 'moon'].includes(String((decoration as Input).sticker)))) {
      fail('invalid_decoration', 'invalid-argument');
    }
    const body = input.body === undefined ? undefined : text(input.body, 'body', 2000, true);
    const noteId = input.noteId === undefined ? undefined : input.noteId === null ? null : id(input.noteId, 'note_id');
    await this.service.rate(caller.uid, 'memory', 40, 60_000);
    return this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const ref = this.db.doc(`pairs/${pairId}/memories/${memoryId}`), old = (await tx.get(ref)).data();
      if (!old && (await tx.get(this.db.collection(`pairs/${pairId}/memories`).limit(200))).size >= 200) fail('memory_limit', 'resource-exhausted');
      const linkedNote = noteId === undefined ? old?.noteId ?? null : noteId;
      if (linkedNote && !(await tx.get(this.db.doc(`pairs/${pairId}/notes/${linkedNote}`))).exists) fail('note_unavailable', 'not-found');
      const value = {id: memoryId, pairId, pairEpoch, authorId: old?.authorId ?? caller.uid, title, date,
        kind: input.kind, recursYearly: input.recursYearly ?? old?.recursYearly ?? false, body: body ?? old?.body ?? '',
        decoration: decoration === undefined ? old?.decoration ?? null : {layout: (decoration as Input).layout, sticker: (decoration as Input).sticker},
        noteId: linkedNote, photo: old?.photo ?? null, createdAt: old?.createdAt ?? Timestamp.fromMillis(this.service.now()),
        updatedAt: Timestamp.fromMillis(this.service.now())};
      tx.set(ref, value); return {memory: publicMemory(value)};
    });
  }
  async memories(caller: Caller, input: Input): Promise<Input> {
    const space = await this.getCoupleSpace(caller, input); return {memories: space.memories};
  }
  async deleteMemory(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input), memoryId = id(input.memoryId, 'memory_id');
    await this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const ref = this.db.doc(`pairs/${pairId}/memories/${memoryId}`), old = (await tx.get(ref)).data();
      if (old) {
        const trash = this.db.doc(`memoryTrash/${pairId}_${memoryId}`);
        const previous = (await tx.get(trash)).data();
        if (previous?.memory?.photo) this.retireImage(tx, previous.memory.photo.id);
        tx.set(trash, {pairId, pairEpoch, memory: old, expiresAt: Timestamp.fromMillis(this.service.now() + 60_000)});
        tx.delete(ref);
      }
    });
    return {};
  }
  async restoreMemory(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input), memoryId = id(input.memoryId, 'memory_id');
    return this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const trash = this.db.doc(`memoryTrash/${pairId}_${memoryId}`), deleted = (await tx.get(trash)).data();
      if (!deleted || deleted.pairEpoch !== pairEpoch || deleted.expiresAt.toMillis() <= this.service.now()) fail('undo_expired', 'not-found');
      const ref = this.db.doc(`pairs/${pairId}/memories/${memoryId}`);
      if ((await tx.get(ref)).exists) fail('memory_exists', 'already-exists');
      if ((await tx.get(this.db.collection(`pairs/${pairId}/memories`).limit(200))).size >= 200) fail('memory_limit', 'resource-exhausted');
      tx.set(ref, deleted.memory); tx.delete(trash);
      return {memory: publicMemory(deleted.memory)};
    });
  }
  async sendMessage(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input), messageId = id(input.messageId, 'message_id');
    const content = text(input.text, 'message', 500);
    await this.service.rate(caller.uid, 'message', 30, 60_000);
    return this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const ref = this.db.doc(`pairs/${pairId}/messages/${messageId}`), previous = (await tx.get(ref)).data();
      if (previous) {
        if (previous.authorId !== caller.uid || previous.text !== content) fail('idempotency_conflict', 'already-exists');
        return {message: publicMessage(previous)};
      }
      const recipientId = pair.members.find((member: string) => member !== caller.uid);
      const sentAt = Timestamp.fromMillis(Math.max(this.service.now(), (pair.lastMessageMillis ?? 0) + 1));
      const message = {id: messageId, pairId, pairEpoch, authorId: caller.uid, recipientId, text: content, sentAt};
      tx.create(ref, message); tx.update(this.db.doc(`pairs/${pairId}`), {lastMessageMillis: sentAt.toMillis()});
      tx.set(this.db.doc(`pairs/${pairId}/views/${recipientId}`), {latestMessageId: messageId}, {merge: true});
      tx.create(this.db.doc(`notificationEvents/${digest(`${pairId}:message:${messageId}`)}`), {
        pairId, pairEpoch, type: 'message', messageId, recipientId, status: 'pending', attempts: 0, nextAttemptAt: sentAt});
      return {message: publicMessage(message)};
    });
  }
  async messages(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input), maximum = input.limit === undefined ? 30 : positive(input.limit, 'limit');
    if (maximum > 50) fail('invalid_limit', 'invalid-argument');
    let cursor: {sentAt: number; messageId: string} | undefined;
    if (input.cursor !== undefined && input.cursor !== null) {
      const value = input.cursor as Input;
      cursor = {sentAt: positive(value.sentAt, 'cursor_time'), messageId: id(value.messageId, 'cursor_message_id')};
    }
    await this.db.runTransaction(tx => this.service.pair(tx, caller.uid, pairId, pairEpoch));
    const rows = await this.db.messagesPage(pairId, maximum + 1, cursor), visible = rows.slice(0, maximum), last = visible.at(-1);
    await this.db.runTransaction(tx => this.service.pair(tx, caller.uid, pairId, pairEpoch));
    return {messages: visible.map(publicMessage), nextCursor: rows.length > maximum && last ? {sentAt: last.sentAt.toMillis(), messageId: last.id} : null};
  }
  async normalizeImage(bytes: Buffer, contentType: string, avatar: boolean): Promise<Buffer> {
    if (!['image/png', 'image/jpeg'].includes(contentType) || bytes.length > 5 * 1024 * 1024 || !bytes.length) fail('invalid_image', 'invalid-argument');
    try {
      const image = sharp(bytes, {limitInputPixels: 4096 * 4096, failOn: 'warning'}), metadata = await image.metadata();
      if (!['png', 'jpeg'].includes(metadata.format ?? '') || (metadata.pages ?? 1) > 1) fail('invalid_image', 'invalid-argument');
      // rotate applies orientation; the fresh PNG has no EXIF/GPS/profile metadata.
      const result = await image.rotate().resize(avatar ? 256 : 1536, avatar ? 256 : 1536,
        {fit: avatar ? 'cover' : 'inside', withoutEnlargement: true}).png().toBuffer();
      if (result.length > (avatar ? 512 * 1024 : 5 * 1024 * 1024)) fail('image_too_large', 'invalid-argument');
      return result;
    } catch {fail('invalid_image', 'invalid-argument');}
  }
  async stageImage(uid: string, bytes: Buffer, contentType = 'image/png'): Promise<DocumentData> {
    const imageId = randomUUID(), path = `private/${uid}/${imageId}/image`, sha256 = digest(bytes);
    // Durable pending metadata allows cleanup even if upload or the attach transaction fails.
    await this.db.doc(`privateImages/${imageId}`).create({id: imageId, ownerId: uid, path, sha256, status: 'pending',
      expiresAt: Timestamp.fromMillis(this.service.now() + 3600_000), cleanupDone: false});
    await this.service.bucket.file(path).save(bytes, {metadata: {contentType, metadata: {sha256}}});
    return {id: imageId, path, sha256};
  }
  async attachImage(tx: Transaction, image: DocumentData): Promise<void> {
    const ref = this.db.doc(`privateImages/${image.id}`), value = (await tx.get(ref)).data();
    if (value?.status !== 'pending' || value.expiresAt.toMillis() <= this.service.now()) fail('image_upload_expired');
    tx.update(ref, {status: 'attached', cleanupDone: true});
  }
  retireImage(tx: Transaction, imageId: string): void {
    tx.update(this.db.doc(`privateImages/${imageId}`), {status: 'obsolete', expiresAt: Timestamp.fromMillis(this.service.now()), cleanupDone: false});
  }
  async abandonImage(image: DocumentData): Promise<void> {
    await this.db.runTransaction(async tx => {
      const ref = this.db.doc(`privateImages/${image.id}`), value = (await tx.get(ref)).data();
      if (value && value.status !== 'attached') this.retireImage(tx, image.id);
    });
  }
  async profileAvatar(caller: Caller, bytes: Buffer, contentType: string): Promise<Input> {
    await this.service.rate(caller.uid, 'avatar', 10, 60_000);
    if (!(await this.db.doc(`users/${caller.uid}`).get()).exists) fail('profile_required');
    const image = await this.stageImage(caller.uid, await this.normalizeImage(bytes, contentType, true));
    return this.db.runTransaction(async tx => {
      const ref = this.db.doc(`users/${caller.uid}`), user = (await tx.get(ref)).data();
      if (!user) fail('profile_required');
      await this.attachImage(tx, image);
      if (user.avatar) this.retireImage(tx, user.avatar.id);
      tx.update(ref, {avatar: image});
      if (user.activePairId) {
        const pair = await this.service.pair(tx, caller.uid, user.activePairId);
        this.notifyWidgets(tx, pair);
        tx.set(this.db.doc(`pairs/${user.activePairId}/profiles/${caller.uid}`), {uid: caller.uid, displayName: user.displayName, avatar: image});
      }
      return {profile: publicProfile({...user, uid: caller.uid, avatar: image})};
    }).catch(async error => {await this.abandonImage(image); throw error;});
  }
  async deleteProfileAvatar(caller: Caller): Promise<Input> {
    return this.db.runTransaction(async tx => {
      const ref = this.db.doc(`users/${caller.uid}`), user = (await tx.get(ref)).data();
      if (!user) fail('profile_required');
      if (user.avatar) this.retireImage(tx, user.avatar.id);
      tx.update(ref, {avatar: null});
      if (user.activePairId) {
        const pair = await this.service.pair(tx, caller.uid, user.activePairId);
        this.notifyWidgets(tx, pair);
        tx.set(this.db.doc(`pairs/${user.activePairId}/profiles/${caller.uid}`), {uid: caller.uid, displayName: user.displayName, avatar: null});
      }
      return {profile: publicProfile({...user, uid: caller.uid, avatar: null})};
    });
  }
  async avatar(caller: Caller, uid: string, avatarId?: string): Promise<Buffer> {
    id(uid, 'user_id');
    const read = () => this.db.runTransaction(async tx => {
      const user = (await tx.get(this.db.doc(`users/${caller.uid}`))).data();
      if (uid !== caller.uid) {
        if (!user?.activePairId) fail('not_pair_member', 'permission-denied');
        const pair = await this.service.pair(tx, caller.uid, user.activePairId);
        if (!pair.members.includes(uid)) fail('not_pair_member', 'permission-denied');
      }
      const profile = (await tx.get(this.db.doc(`users/${uid}`))).data();
      if (!profile?.avatar) fail('avatar_unavailable', 'not-found');
      if (avatarId && profile.avatar.id !== avatarId) fail('avatar_changed', 'aborted');
      return profile.avatar;
    });
    const image = await read(), [bytes] = await this.service.bucket.file(image.path).download(), fresh = await read();
    if (fresh.id !== image.id) fail('avatar_changed', 'aborted');
    if (digest(bytes) !== image.sha256) fail('asset_integrity_mismatch');
    return bytes;
  }
  async memoryPhoto(caller: Caller, input: Input, bytes?: Buffer, contentType?: string): Promise<Input | Buffer> {
    const {pairId, pairEpoch} = pairInput(input), memoryId = id(input.memoryId, 'memory_id');
    const read = () => this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const memory = (await tx.get(this.db.doc(`pairs/${pairId}/memories/${memoryId}`))).data();
      if (!memory) fail('memory_unavailable', 'not-found');
      return memory;
    });
    const original = await read();
    if (bytes) {
      await this.service.rate(caller.uid, 'memory_photo', 10, 60_000);
      const image = await this.stageImage(caller.uid, await this.normalizeImage(bytes, contentType ?? '', false));
      return this.db.runTransaction(async tx => {
        await this.service.pair(tx, caller.uid, pairId, pairEpoch);
        const ref = this.db.doc(`pairs/${pairId}/memories/${memoryId}`), memory = (await tx.get(ref)).data();
        if (!memory) fail('memory_unavailable', 'not-found');
        await this.attachImage(tx, image); if (memory.photo) this.retireImage(tx, memory.photo.id);
        const value = {...memory, photo: image, updatedAt: Timestamp.fromMillis(this.service.now())};
        tx.set(ref, value); return {memory: publicMemory(value)};
      }).catch(async error => {await this.abandonImage(image); throw error;});
    }
    if (!original.photo) fail('memory_photo_unavailable', 'not-found');
    if (input.photoId && original.photo.id !== input.photoId) fail('memory_photo_changed', 'aborted');
    const [image] = await this.service.bucket.file(original.photo.path).download(), fresh = await read();
    if (fresh.photo?.id !== original.photo.id) fail('memory_photo_changed', 'aborted');
    if (digest(image) !== original.photo.sha256) fail('asset_integrity_mismatch');
    return image;
  }
  async deleteMemoryPhoto(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input), memoryId = id(input.memoryId, 'memory_id');
    return this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const ref = this.db.doc(`pairs/${pairId}/memories/${memoryId}`), memory = (await tx.get(ref)).data();
      if (!memory) fail('memory_unavailable', 'not-found');
      if (memory.photo) this.retireImage(tx, memory.photo.id);
      const value = {...memory, photo: null, updatedAt: Timestamp.fromMillis(this.service.now())};
      tx.set(ref, value); return {memory: publicMemory(value)};
    });
  }
  async location(tx: Transaction, uid: string, pair: DocumentData): Promise<DocumentData> {
    const consents = await tx.getAll(...(pair.members as string[]).map(member => this.db.doc(`pairs/${pair.id}/locationConsent/${member}`)));
    const mine = consents.find(value => value.id === uid)?.data();
    const enabled = consents.every(value => value.data()?.enabled === true);
    const distance = (await tx.get(this.db.doc(`pairs/${pair.id}/distance/current`))).data();
    let publicDistance: DocumentData = {status: enabled ? 'waiting' : 'disabled', meters: null, updatedAt: null, accuracyMeters: null};
    if (enabled && distance) {
      const age = this.service.now() - distance.updatedAt;
      publicDistance = {status: age <= freshness ? 'available' : 'stale', meters: age < retention ? distance.meters : null,
        updatedAt: distance.updatedAt, accuracyMeters: age < retention ? distance.accuracyMeters : null};
    }
    return {sharingEnabled: mine?.enabled === true, sourceDeviceId: mine?.enabled ? mine.deviceId : null,
      consentVersion: mine?.version ?? 0, distance: publicDistance};
  }
  async setLocationConsent(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input);
    if (typeof input.enabled !== 'boolean') fail('invalid_enabled', 'invalid-argument');
    const deviceId = input.enabled ? id(input.deviceId, 'device_id') : null;
    await this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      if (deviceId) await this.locationDevice(tx, caller, deviceId);
      const ref = this.db.doc(`pairs/${pairId}/locationConsent/${caller.uid}`), old = (await tx.get(ref)).data();
      if (old?.enabled === input.enabled && old?.deviceId === deviceId) return;
      tx.set(ref, {enabled: input.enabled, deviceId, version: (old?.version ?? 0) + 1, lastSequence: 0, lastCapturedAt: 0});
      // A pause/source change erases coordinates and any derived distance. Other consent remains independent.
      for (const member of input.enabled ? [caller.uid] : pair.members) tx.delete(this.db.doc(`locationPrivate/${member}`));
      tx.delete(this.db.doc(`pairs/${pairId}/distance/current`));
      this.notifyWidgets(tx, pair);
    });
    return this.db.runTransaction(async tx => ({location: await this.location(tx, caller.uid,
      await this.service.pair(tx, caller.uid, pairId, pairEpoch))}));
  }
  private async locationDevice(tx: Transaction, caller: Caller, deviceId: string): Promise<void> {
    const device = (await tx.get(this.db.doc(`users/${caller.uid}/devices/${deviceId}`))).data();
    const binding = (await tx.get(this.db.doc(`installationSessions/${digest(deviceId)}`))).data();
    if (!device?.active || (binding && (binding.uid !== caller.uid || binding.sessionId !== caller.sessionId))) fail('location_device_unavailable', 'permission-denied');
  }
  async updateLocation(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = pairInput(input), deviceId = id(input.deviceId, 'device_id');
    const version = positive(input.consentVersion, 'consent_version'), sequence = positive(input.sequence, 'sequence');
    const latitude = numeric(input.latitude, -90, 90, 'latitude'), longitude = numeric(input.longitude, -180, 180, 'longitude');
    const accuracy = numeric(input.horizontalAccuracy, 0, 5000, 'accuracy'), capturedAt = positive(input.capturedAt, 'captured_at');
    const now = this.service.now();
    if (capturedAt > now + 60_000 || capturedAt <= now - retention) fail('invalid_location_time', 'invalid-argument');
    await this.service.rate(caller.uid, 'location', 30, 60_000);
    await this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const consent = (await tx.get(this.db.doc(`pairs/${pairId}/locationConsent/${caller.uid}`))).data();
      if (!consent?.enabled || consent.version !== version || consent.deviceId !== deviceId) fail('location_consent_required', 'permission-denied');
      await this.locationDevice(tx, caller, deviceId);
      const ref = this.db.doc(`locationPrivate/${caller.uid}`);
      if (sequence <= (consent.lastSequence ?? 0) || capturedAt <= (consent.lastCapturedAt ?? 0)) fail('stale_location_sample', 'aborted');
      const sample = {pairId, pairEpoch, deviceId, consentVersion: version, sequence, latitude, longitude, accuracy,
        capturedAt, receivedAt: now, expiresAt: Timestamp.fromMillis(capturedAt + retention)};
      tx.set(ref, sample);
      tx.update(this.db.doc(`pairs/${pairId}/locationConsent/${caller.uid}`), {lastSequence: sequence, lastCapturedAt: capturedAt});
      const partnerId = pair.members.find((member: string) => member !== caller.uid);
      const partnerConsent = (await tx.get(this.db.doc(`pairs/${pairId}/locationConsent/${partnerId}`))).data();
      const partner = (await tx.get(this.db.doc(`locationPrivate/${partnerId}`))).data();
      if (partnerConsent?.enabled && partner && partner.pairId === pairId && partner.pairEpoch === pairEpoch
        && partner.consentVersion === partnerConsent.version && partner.deviceId === partnerConsent.deviceId && partner.capturedAt > now - retention) {
        const radians = (degrees: number) => degrees * Math.PI / 180;
        const deltaLat = radians(latitude - partner.latitude), deltaLon = radians(longitude - partner.longitude);
        const h = Math.sin(deltaLat / 2) ** 2 + Math.cos(radians(latitude)) * Math.cos(radians(partner.latitude)) * Math.sin(deltaLon / 2) ** 2;
        const meters = 2 * 6371008.8 * Math.asin(Math.sqrt(Math.min(1, Math.max(0, h))));
        tx.set(this.db.doc(`pairs/${pairId}/distance/current`), {meters: Math.round(meters / 100) * 100,
          accuracyMeters: Math.max(100, Math.ceil((accuracy + partner.accuracy) / 100) * 100), updatedAt: Math.min(now, capturedAt, partner.capturedAt)});
        // Location uploads are bounded by the app; coalesce pushes to one per
        // five-minute window for both members, even across multiple devices.
        const notice = this.db.doc(`pairs/${pairId}/widgetUpdates/location`);
        const previous = (await tx.get(notice)).data();
        if (!previous || previous.sentAt <= now - 5 * 60_000) {
          this.notifyWidgets(tx, pair);
          tx.set(notice, {sentAt: now});
        }
      }
    });
    return this.db.runTransaction(async tx => ({location: await this.location(tx, caller.uid,
      await this.service.pair(tx, caller.uid, pairId, pairEpoch))}));
  }
  async cleanup(): Promise<void> {
    const now = this.service.now();
    await this.db.runTransaction(async tx => {
      const coordinates = await tx.get(this.db.collection('locationPrivate').where('expiresAt', '<=', Timestamp.fromMillis(now)).limit(100));
      for (const item of coordinates.docs) tx.delete(item.ref);
    });
    await this.db.runTransaction(async tx => {
      const expired = await tx.get(this.db.collection('memoryTrash').where('expiresAt', '<=', Timestamp.fromMillis(now)).limit(100));
      for (const item of expired.docs) {
        const memory = item.data()!.memory;
        if (memory.photo) this.retireImage(tx, memory.photo.id);
        tx.delete(item.ref);
      }
    });
    const candidates = await this.db.collection('privateImages').where('cleanupDone', '==', false)
      .where('expiresAt', '<=', Timestamp.fromMillis(now - 3600_000)).limit(20).get();
    for (const candidate of candidates.docs) {
      await this.db.runTransaction(async tx => {
        const value = (await tx.get(candidate.ref)).data();
        if (!value || value.status === 'attached' || value.cleanupDone || value.expiresAt.toMillis() > now - 3600_000) return;
        await this.service.bucket.file(value.path).delete();
        tx.update(candidate.ref, {cleanupDone: true, status: 'deleted'});
      });
    }
  }
}
