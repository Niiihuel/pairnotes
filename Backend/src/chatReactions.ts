import {DocumentData, Timestamp, Transaction} from './database';
import {Caller, PairNotesService, digest, fail} from './service';

type Input = Record<string, unknown>;
const targetTypes = ['message', 'photo', 'drawing', 'letter'] as const;
const reactionKinds = ['heart', 'laugh', 'fire', 'tear', 'thumbsUp', 'surprised'] as const;
type Target = {targetType: typeof targetTypes[number]; targetId: string};
const identifier = (value: unknown, name: string): string => {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value)) fail(`invalid_${name}`, 'invalid-argument');
  return value;
};
function scope(input: Input): {pairId: string; pairEpoch: number} {
  if (typeof input.pairEpoch !== 'number' || !Number.isSafeInteger(input.pairEpoch) || input.pairEpoch < 1) fail('invalid_pair_epoch', 'invalid-argument');
  return {pairId: identifier(input.pairId, 'pair_id'), pairEpoch: input.pairEpoch};
}
function target(input: unknown): Target {
  if (!input || typeof input !== 'object' || Array.isArray(input)) fail('invalid_target', 'invalid-argument');
  const value = input as Input;
  if (typeof value.targetType !== 'string' || !targetTypes.includes(value.targetType as Target['targetType'])) fail('invalid_target_type', 'invalid-argument');
  return {targetType: value.targetType as Target['targetType'], targetId: identifier(value.targetId, 'target_id')};
}

/** Chat reactions are independent of the received-photo/widget and drawing APIs. */
export class ChatReactionFeatures {
  constructor(readonly service: PairNotesService) {}
  get db() {return this.service.db;}

  private targetRef(pairId: string, value: Target) {
    const collection = {message: 'messages', photo: 'photos', drawing: 'notes', letter: 'letters'}[value.targetType];
    return this.db.doc(`pairs/${pairId}/${collection}/${value.targetId}`);
  }
  private reactionRef(pairId: string, pairEpoch: number, value: Target, authorId: string) {
    return this.db.doc(`pairs/${pairId}/chatReactions/${pairEpoch}_${digest(`${value.targetType}:${value.targetId}:${authorId}`)}`);
  }
  private visible(value: DocumentData | undefined, requested: Target, pair: DocumentData, uid: string): boolean {
    if (!value || value.id !== requested.targetId || value.authorId === value.recipientId ||
        !pair.members.includes(value.authorId) || !pair.members.includes(value.recipientId) ||
        ![value.authorId, value.recipientId].includes(uid)) return false;
    // Legacy letters have no scope fields. Only the original generation can
    // authorize them; an eventual reactivation must not inherit old content.
    if (value.pairId !== undefined && value.pairId !== pair.id) return false;
    if (value.pairEpoch !== pair.pairEpoch &&
        (requested.targetType !== 'letter' || value.pairEpoch !== undefined || pair.pairEpoch !== 1)) return false;
    if (requested.targetType === 'letter') {
      return value.status === 'sealed' && typeof value.opensAt === 'number' && Number.isSafeInteger(value.opensAt) &&
        (value.authorId === uid || value.opensAt <= this.service.now());
    }
    return true;
  }
  private publicReaction(value: DocumentData | undefined, pair: DocumentData, requested: Target, authorId: string): DocumentData | null {
    if (!value || value.pairId !== pair.id || value.pairEpoch !== pair.pairEpoch ||
        value.targetType !== requested.targetType || value.targetId !== requested.targetId || value.authorId !== authorId ||
        !reactionKinds.includes(value.kind) || !(value.updatedAt instanceof Timestamp) ||
        !Number.isSafeInteger(value.updatedAt.toMillis()) || value.updatedAt.toMillis() < 1) return null;
    return {targetType: value.targetType, targetId: value.targetId, authorId: value.authorId,
      kind: value.kind, updatedAt: value.updatedAt.toMillis()};
  }
  private async readReactions(tx: Transaction, pair: DocumentData, requested: Target): Promise<DocumentData[]> {
    const authors: string[] = [...pair.members].sort();
    const rows = await tx.getMany(authors.map(uid => this.reactionRef(pair.id, pair.pairEpoch, requested, uid)));
    return rows.flatMap((row, index) => {
      const value = this.publicReaction(row.data(), pair, requested, authors[index]!);
      return value ? [value] : [];
    });
  }
  private async rate(tx: Transaction, uid: string, action: string, maximum: number): Promise<void> {
    const ref = this.db.doc(`rateLimits/${digest(`${uid}:${action}`)}`), old = (await tx.get(ref)).data(), now = this.service.now();
    const count = old && old.until.toMillis() > now ? old.count as number : 0;
    if (count >= maximum) fail('rate_limited', 'resource-exhausted');
    tx.set(ref, {count: count + 1, until: Timestamp.fromMillis(count ? old!.until.toMillis() : now + 60_000)});
  }

  async get(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input);
    if (!Array.isArray(input.targets) || input.targets.length > 100) fail('invalid_targets', 'invalid-argument');
    const targets = [...new Map(input.targets.map(item => {
      const value = target(item); return [`${value.targetType}:${value.targetId}`, value] as const;
    })).values()];
    return this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      await this.rate(tx, caller.uid, 'chat_reaction_read', 60);
      const rows = await tx.getMany(targets.map(value => this.targetRef(pairId, value)));
      const visible = targets.filter((requested, index) => this.visible(rows[index]?.data(), requested, pair, caller.uid));
      const authors: string[] = [...pair.members].sort();
      const records = await tx.getMany(visible.flatMap(requested => authors.map(uid => this.reactionRef(pairId, pairEpoch, requested, uid))));
      const reactions: DocumentData[] = [];
      for (const [index, requested] of visible.entries()) {
        for (const [actor, uid] of authors.entries()) {
          const value = this.publicReaction(records[index * authors.length + actor]?.data(), pair, requested, uid);
          if (value) reactions.push(value);
        }
      }
      // Omitted rows never distinguish missing targets from locked content.
      return {reactions};
    });
  }

  async set(caller: Caller, input: Input): Promise<Input> {
    const {pairId, pairEpoch} = scope(input), requested = target(input);
    if (input.kind !== null && (typeof input.kind !== 'string' || !reactionKinds.includes(input.kind as typeof reactionKinds[number]))) fail('invalid_reaction_kind', 'invalid-argument');
    return this.db.runTransaction(async tx => {
      const pair = await this.service.pair(tx, caller.uid, pairId, pairEpoch);
      if (!this.visible((await tx.get(this.targetRef(pairId, requested))).data(), requested, pair, caller.uid)) fail('target_unavailable', 'not-found');
      const ref = this.reactionRef(pairId, pairEpoch, requested, caller.uid), old = (await tx.get(ref)).data();
      const previous = this.publicReaction(old, pair, requested, caller.uid);
      let reaction = previous;
      const reactions = await this.readReactions(tx, pair, requested);
      // Retries remain successful even after the mutation rate limit is reached.
      if (input.kind === null ? !!old : previous?.kind !== input.kind) {
        await this.rate(tx, caller.uid, 'chat_reaction_write', 30);
        if (input.kind === null) {tx.delete(ref); reaction = null;}
        else {
          const value = {pairId, pairEpoch, ...requested, authorId: caller.uid, kind: input.kind,
            updatedAt: Timestamp.fromMillis(Math.max(this.service.now(), (previous?.updatedAt ?? 0) + 1))};
          tx.set(ref, value); reaction = this.publicReaction(value, pair, requested, caller.uid);
        }
      }
      // Transaction writes flush after this callback, so return the confirmed
      // result assembled from the authorized previous state and this mutation.
      return {reaction, reactions: [...reactions.filter(value => value.authorId !== caller.uid), ...(reaction ? [reaction] : [])]
        .sort((a, b) => a.authorId.localeCompare(b.authorId))};
    });
  }
}
