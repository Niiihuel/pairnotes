import {DocumentData, Timestamp, Transaction} from './database';
import {Caller, PairNotesService, digest, fail} from './service';

type Input = Record<string, unknown>;
const currencies = new Set(Intl.supportedValuesOf('currency'));
const categories = ['travel', 'home', 'food', 'plans', 'gifts', 'other'];
const maximumWishes = 200;
function uuid(value: unknown, field: string): string {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) fail(`invalid_${field}`, 'invalid-argument');
  return value.toLowerCase();
}
function scope(input: Input) {
  if (typeof input.pairId !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(input.pairId)) fail('invalid_pair_id', 'invalid-argument');
  if (typeof input.pairEpoch !== 'number' || !Number.isSafeInteger(input.pairEpoch) || input.pairEpoch < 1) fail('invalid_pair_epoch', 'invalid-argument');
  return {pairId: input.pairId, pairEpoch: input.pairEpoch};
}
function text(value: unknown, field: string, maximum: number): string {
  if (typeof value !== 'string' || value.length > maximum) fail(`invalid_${field}`, 'invalid-argument');
  return value.trim();
}
function amount(value: unknown, field: string): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,9})(?:\.[0-9]{1,4})?$/.test(value)) fail(`invalid_${field}`, 'invalid-argument');
  return value.includes('.') ? value.replace(/0+$/, '').replace(/\.$/, '') : value;
}
function fields(input: Input): DocumentData {
  const title = text(input.title, 'title', 120), notes = text(input.notes ?? '', 'notes', 1000);
  if (!title) fail('invalid_title', 'invalid-argument');
  if (typeof input.category !== 'string' || !categories.includes(input.category)) fail('invalid_category', 'invalid-argument');
  if (typeof input.fulfilled !== 'boolean') fail('invalid_fulfilled', 'invalid-argument');
  const priceAmount = amount(input.priceAmount, 'price_amount'), currencyCode = input.currencyCode ?? null;
  if (currencyCode !== null && (typeof currencyCode !== 'string' || !currencies.has(currencyCode))) fail('invalid_currency_code', 'invalid-argument');
  if ((priceAmount === null) !== (currencyCode === null)) fail('price_currency_required_together', 'invalid-argument');
  let linkURL: string | null = null;
  if (input.linkURL !== null && input.linkURL !== undefined) {
    linkURL = text(input.linkURL, 'link_url', 2048);
    try {
      const parsed = new URL(linkURL);
      if (!['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname || parsed.username || parsed.password) fail('invalid_link_url', 'invalid-argument');
    } catch {fail('invalid_link_url', 'invalid-argument');}
  }
  const targetDate = input.targetDate ?? null;
  if (targetDate !== null) {
    if (typeof targetDate !== 'string' || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(targetDate) || targetDate.startsWith('0000')) fail('invalid_target_date', 'invalid-argument');
    const date = new Date(targetDate + 'T00:00:00.000Z');
    if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== targetDate) fail('invalid_target_date', 'invalid-argument');
  }
  const location = text(input.location ?? '', 'location', 240);
  const savedAmount = input.category === 'travel' ? amount(input.savedAmount, 'saved_amount') : null;
  if (savedAmount !== null && priceAmount === null) fail('saved_amount_requires_target', 'invalid-argument');
  const recipient = input.category === 'gifts' ? text(input.recipient ?? '', 'recipient', 120) : '';
  const occasion = input.category === 'gifts' ? text(input.occasion ?? '', 'occasion', 120) : '';
  const foodKind = input.category === 'food' ? input.foodKind ?? null : null;
  if (foodKind !== null && (typeof foodKind !== 'string' || !['restaurant', 'recipe'].includes(foodKind))) fail('invalid_food_kind', 'invalid-argument');
  const ingredients = foodKind === 'recipe' ? text(input.ingredients ?? '', 'ingredients', 6000) : '';
  const instructions = foodKind === 'recipe' ? text(input.instructions ?? '', 'instructions', 10000) : '';
  return {title, category: input.category, notes, priceAmount, currencyCode, fulfilled: input.fulfilled,
    linkURL, targetDate, location, savedAmount, recipient, occasion, foodKind, ingredients, instructions};
}
function revision(input: Input): number {
  if (typeof input.expectedRevision !== 'number' || !Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 0 || input.expectedRevision >= Number.MAX_SAFE_INTEGER) fail('invalid_expected_revision', 'invalid-argument');
  return input.expectedRevision;
}
export function publicWish(value: DocumentData): DocumentData {
  const {id, pairId, pairEpoch, authorId, title, category, notes, priceAmount, currencyCode, fulfilled,
    linkURL, targetDate, location, savedAmount, recipient, occasion, foodKind, ingredients, instructions, revision} = value;
  return {id, pairId, pairEpoch, authorId, title, category, notes, priceAmount, currencyCode, fulfilled,
    linkURL, targetDate, location, savedAmount, recipient, occasion, foodKind, ingredients, instructions, revision,
    photo: value.photo ? {id: value.photo.id, sha256: value.photo.sha256} : null,
    createdAt: value.createdAt.toMillis(), updatedAt: value.updatedAt.toMillis()};
}

/** Shared, bounded wishlist. Every edit uses an optimistic revision and durable retry identity. */
export class WishFeatures {
  constructor(readonly service: PairNotesService) {}
  get db() {return this.service.db;}
  private ref(pairId: string, id: string) {return this.db.doc(`pairs/${pairId}/wishes/${id}`);}
  private async read(tx: Transaction, caller: Caller, input: Input): Promise<DocumentData> {
    const {pairId, pairEpoch} = scope(input), id = uuid(input.id, 'wish_id');
    await this.service.pair(tx, caller.uid, pairId, pairEpoch);
    const value = (await tx.get(this.ref(pairId, id))).data();
    if (!value || value.deleted || value.pairEpoch !== pairEpoch) fail('wish_unavailable', 'not-found');
    return value;
  }
  private identity(caller: Caller, input: Input, operation: string, payload: Input = {}) {
    const {pairId, pairEpoch} = scope(input), id = uuid(input.id, 'wish_id'), requestId = uuid(input.requestId, 'request_id');
    const expectedRevision = revision(input);
    const signature = digest(JSON.stringify({operation, pairId, pairEpoch, id, actorId: caller.uid, expectedRevision, payload}));
    return {pairId, pairEpoch, id, expectedRevision, signature, receipt: this.db.doc(`pairs/${pairId}/wishRequests/${requestId}`)};
  }
  private async checked(tx: Transaction, caller: Caller, mutation: ReturnType<WishFeatures['identity']>) {
    await this.service.pair(tx, caller.uid, mutation.pairId, mutation.pairEpoch);
    const receipt = (await tx.get(mutation.receipt)).data();
    if (receipt && receipt.signature !== mutation.signature) fail('idempotency_conflict', 'already-exists');
    const current = (await tx.get(this.ref(mutation.pairId, mutation.id))).data();
    if (current && current.pairEpoch !== mutation.pairEpoch) fail('wish_unavailable', 'not-found');
    if (!receipt && (current?.revision ?? 0) !== mutation.expectedRevision) fail('wish_revision_conflict', 'aborted');
    return {current, repeated: !!receipt};
  }
  private receipt(tx: Transaction, mutation: ReturnType<WishFeatures['identity']>) {
    tx.create(mutation.receipt, {signature: mutation.signature});
  }
  private live(value: DocumentData | undefined): DocumentData {
    if (!value || value.deleted) fail('wish_unavailable', 'not-found');
    return value;
  }
  private updated(current: DocumentData): DocumentData {
    return {...current, revision: current.revision + 1,
      updatedAt: Timestamp.fromMillis(Math.max(this.service.now(), current.updatedAt.toMillis() + 1))};
  }

  async list(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input);
    return this.db.runTransaction(async tx => {
      await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      const rows = await tx.get(this.db.collection(`pairs/${pairId}/wishes`).where('deleted', '==', false)
        .where('pairEpoch', '==', pairEpoch).orderBy('createdAt', 'desc').limit(maximumWishes));
      return {wishes: rows.docs.map(row => publicWish(row.data()!)), limit: maximumWishes};
    });
  }
  async get(caller: Caller, input: Input): Promise<Input> {
    return this.db.runTransaction(async tx => ({wish: publicWish(await this.read(tx, caller, input))}));
  }
  async save(caller: Caller, input: Input): Promise<Input> {
    const values = fields(input), mutation = this.identity(caller, input, 'save', values);
    await this.service.rate(caller.uid, 'wish_mutation', 60, 60_000);
    return this.db.runTransaction(async tx => {
      const {current, repeated} = await this.checked(tx, caller, mutation);
      if (repeated) return {wish: publicWish(this.live(current))};
      if (current?.deleted) fail('wish_unavailable', 'not-found');
      if (!current && (await tx.get(this.db.collection(`pairs/${mutation.pairId}/wishes`).where('deleted', '==', false).where('pairEpoch', '==', mutation.pairEpoch).limit(maximumWishes))).size >= maximumWishes) fail('wish_limit', 'resource-exhausted');
      const now = Timestamp.fromMillis(this.service.now());
      const value = {...(current ? this.updated(current) : {id: mutation.id, pairId: mutation.pairId, pairEpoch: mutation.pairEpoch,
        authorId: caller.uid, photo: null, createdAt: now, updatedAt: now, revision: 1, deleted: false}), ...values};
      tx.set(this.ref(mutation.pairId, mutation.id), value);
      this.receipt(tx, mutation);
      return {wish: publicWish(value)};
    });
  }
  async delete(caller: Caller, input: Input): Promise<Input> {
    const mutation = this.identity(caller, input, 'delete');
    await this.service.rate(caller.uid, 'wish_mutation', 60, 60_000);
    return this.db.runTransaction(async tx => {
      const {current, repeated} = await this.checked(tx, caller, mutation);
      if (repeated) return {};
      const value = this.live(current);
      if (value.photo) this.service.couple.retireImage(tx, value.photo.id);
      // Tombstones prevent a delayed create retry from resurrecting a deleted wish.
      tx.set(this.ref(mutation.pairId, mutation.id), {id: mutation.id, pairEpoch: mutation.pairEpoch,
        revision: value.revision + 1, deleted: true});
      this.receipt(tx, mutation);
      return {};
    });
  }
  async removePhoto(caller: Caller, input: Input): Promise<Input> {
    const mutation = this.identity(caller, input, 'deletePhoto');
    await this.service.rate(caller.uid, 'wish_mutation', 60, 60_000);
    return this.db.runTransaction(async tx => {
      const {current, repeated} = await this.checked(tx, caller, mutation), value = this.live(current);
      if (repeated) return {wish: publicWish(value)};
      if (value.photo) this.service.couple.retireImage(tx, value.photo.id);
      const updated = {...this.updated(value), photo: null};
      tx.set(this.ref(mutation.pairId, mutation.id), updated); this.receipt(tx, mutation);
      return {wish: publicWish(updated)};
    });
  }
  async uploadPhoto(caller: Caller, input: Input, bytes: Buffer, contentType: string): Promise<Input> {
    const mutation = this.identity(caller, input, 'photo', {sourceSHA256: digest(bytes), contentType});
    const previous = await this.db.runTransaction(async tx => {
      const {current, repeated} = await this.checked(tx, caller, mutation), value = this.live(current);
      return repeated ? {wish: publicWish(value)} : null;
    });
    if (previous) return previous;
    await this.service.rate(caller.uid, 'wish_photo', 12, 60_000);
    const image = await this.service.couple.stageImage(caller.uid, await this.service.couple.normalizeImage(bytes, contentType, false));
    let attached = false;
    try {
      const result = await this.db.runTransaction(async tx => {
        const {current, repeated} = await this.checked(tx, caller, mutation), value = this.live(current);
        if (repeated) return {wish: publicWish(value)};
        await this.service.couple.attachImage(tx, image);
        if (value.photo) this.service.couple.retireImage(tx, value.photo.id);
        const updated = {...this.updated(value), photo: image};
        tx.set(this.ref(mutation.pairId, mutation.id), updated); this.receipt(tx, mutation); attached = true;
        return {wish: publicWish(updated)};
      });
      if (!attached) await this.service.couple.abandonImage(image);
      return result;
    } catch (error) {await this.service.couple.abandonImage(image); throw error;}
  }
  async photo(caller: Caller, input: Input): Promise<Buffer> {
    const photoId = uuid(input.photoId, 'photo_id');
    const read = async () => {
      const value = await this.db.runTransaction(tx => this.read(tx, caller, input));
      if (!value.photo) fail('wish_photo_unavailable', 'not-found');
      if (value.photo.id !== photoId) fail('wish_photo_changed', 'aborted');
      return value.photo;
    };
    const before = await read(), [bytes] = await this.service.bucket.file(before.path).download();
    const after = await read();
    if (after.id !== before.id) fail('wish_photo_changed', 'aborted');
    if (digest(bytes) !== before.sha256) fail('asset_integrity_mismatch');
    return bytes;
  }
  async closePair(tx: Transaction, pairId: string): Promise<void> {
    const rows = await tx.get(this.db.collection(`pairs/${pairId}/wishes`).where('deleted', '==', false).limit(maximumWishes));
    for (const row of rows.docs) if (row.data()!.photo) this.service.couple.retireImage(tx, row.data()!.photo.id);
    // The same transaction makes the relationship inaccessible and queues private image cleanup.
    await tx.client.query("DELETE FROM documents WHERE left(path,length($1))=$1 OR left(path,length($2))=$2",
      [`pairs/${pairId}/wishes/`, `pairs/${pairId}/wishRequests/`]);
  }
}
