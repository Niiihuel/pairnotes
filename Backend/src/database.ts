import {Pool, PoolClient} from 'pg';

export type DocumentData = Record<string, any>;
export class Timestamp {
  constructor(readonly milliseconds: number) {}
  static fromMillis(value: number): Timestamp {return new Timestamp(value);}
  static now(): Timestamp {return new Timestamp(Date.now());}
  toMillis(): number {return this.milliseconds;}
  toJSON(): {$time: number} {return {$time: this.milliseconds};}
}
const deletion = Symbol('delete');
export const FieldValue = {delete: () => deletion};
function decode(value: unknown): any {
  if (Array.isArray(value)) return value.map(decode);
  if (value && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    if (Object.keys(object).length === 1 && typeof object.$time === 'number') return Timestamp.fromMillis(object.$time);
    return Object.fromEntries(Object.entries(object).map(([key, item]) => [key, decode(item)]));
  }
  return value;
}
export class Snapshot {
  constructor(readonly ref: Reference, private readonly value: DocumentData | undefined) {}
  get id(): string {return this.ref.id;}
  get exists(): boolean {return this.value !== undefined;}
  data(): DocumentData | undefined {return this.value;}
}
type Filter = {field: string; operation: '==' | '<=' | '<'; value: unknown};
export class Query {
  constructor(readonly db: Database, readonly prefix: string, readonly filters: Filter[] = [], readonly maximum = 100,
    readonly sort?: {field: string; direction: 'asc' | 'desc'}) {}
  where(field: string, operation: Filter['operation'], value: unknown): Query {return new Query(this.db, this.prefix, [...this.filters, {field, operation, value}], this.maximum, this.sort);}
  limit(maximum: number): Query {return new Query(this.db, this.prefix, this.filters, maximum, this.sort);}
  orderBy(field: string, direction: 'asc' | 'desc' = 'asc'): Query {return new Query(this.db, this.prefix, this.filters, this.maximum, {field, direction});}
  doc(id: string): Reference {return this.db.doc(`${this.prefix}/${id}`);}
  async get(): Promise<QuerySnapshot> {return this.db.query(this);}
  async add(value: DocumentData): Promise<void> {await this.doc(crypto.randomUUID()).create(value);}
}
export class QuerySnapshot {
  constructor(readonly docs: Snapshot[]) {}
  get size(): number {return this.docs.length;}
}
export class Reference {
  constructor(readonly db: Database, readonly path: string) {}
  get id(): string {return this.path.split('/').at(-1)!;}
  get(): Promise<Snapshot> {return this.db.read(this);}
  collection(name: string): Query {return new Query(this.db, `${this.path}/${name}`);}
  async set(value: DocumentData, options?: {merge: boolean}): Promise<void> {await this.db.runTransaction(async tx => {tx.set(this, value, options);});}
  async create(value: DocumentData): Promise<void> {await this.db.runTransaction(async tx => {tx.create(this, value);});}
  async update(value: DocumentData): Promise<void> {await this.db.runTransaction(async tx => {tx.update(this, value);});}
  async delete(): Promise<void> {await this.db.runTransaction(async tx => {tx.delete(this);});}
}
export class Transaction {
  private readonly writes: (() => Promise<void>)[] = [];
  constructor(readonly db: Database, readonly client: PoolClient) {}
  get(ref: Reference): Promise<Snapshot>;
  get(ref: Query): Promise<QuerySnapshot>;
  get(ref: Reference | Query): Promise<Snapshot | QuerySnapshot> {return ref instanceof Reference ? this.db.read(ref, this.client) : this.db.query(ref, this.client);}
  getAll(...refs: Reference[]): Promise<Snapshot[]> {return Promise.all(refs.map(ref => this.db.read(ref, this.client)));}
  create(ref: Reference, value: DocumentData): void {
    this.writes.push(async () => {await this.client.query('INSERT INTO documents(path, value) VALUES ($1,$2::jsonb)', [ref.path, JSON.stringify(value)]);});
  }
  set(ref: Reference, value: DocumentData, options?: {merge: boolean}): void {
    this.writes.push(async () => {
      const previous = options?.merge ? (await this.db.read(ref, this.client)).data() ?? {} : {};
      const merged = {...previous, ...value};
      for (const [key, item] of Object.entries(merged)) if (item === deletion) delete merged[key];
      await this.client.query('INSERT INTO documents(path,value) VALUES($1,$2::jsonb) ON CONFLICT(path) DO UPDATE SET value=EXCLUDED.value', [ref.path, JSON.stringify(merged)]);
    });
  }
  update(ref: Reference, value: DocumentData): void {
    this.writes.push(async () => {
      const previous = (await this.db.read(ref, this.client)).data();
      if (!previous) throw new Error('document_missing');
      const merged = {...previous, ...value};
      for (const [key, item] of Object.entries(merged)) if (item === deletion) delete merged[key];
      await this.client.query('UPDATE documents SET value=$2::jsonb WHERE path=$1', [ref.path, JSON.stringify(merged)]);
    });
  }
  delete(ref: Reference): void {this.writes.push(async () => {await this.client.query('DELETE FROM documents WHERE path=$1', [ref.path]);});}
  async flush(): Promise<void> {for (const write of this.writes) await write();}
}

/** PostgreSQL JSONB aggregates. One transactional advisory lock serializes private-app mutations.
 * Scale beyond this small private app by partitioning locks; correctness comes before throughput.
 */
export class Database {
  readonly pool: Pool;
  constructor(connectionString: string) {this.pool = new Pool({connectionString, max: 10, connectionTimeoutMillis: 10_000});}
  async migrate(): Promise<void> {
    await this.pool.query('CREATE TABLE IF NOT EXISTS documents(path text PRIMARY KEY, value jsonb NOT NULL)');
    await this.pool.query('CREATE INDEX IF NOT EXISTS documents_path_pattern ON documents(path text_pattern_ops)');
    await this.pool.query("CREATE INDEX IF NOT EXISTS documents_notification_due ON documents ((value->>'status'), ((value->'nextAttemptAt'->>'$time')::bigint)) WHERE path LIKE 'notificationEvents/%'");
  }
  doc(path: string): Reference {return new Reference(this, path);}
  collection(path: string): Query {return new Query(this, path);}
  async read(ref: Reference, connection: Pool | PoolClient = this.pool): Promise<Snapshot> {
    const rows = await connection.query('SELECT value FROM documents WHERE path=$1', [ref.path]);
    return new Snapshot(ref, rows.rows[0] ? decode(rows.rows[0].value) : undefined);
  }
  async query(query: Query, connection: Pool | PoolClient = this.pool): Promise<QuerySnapshot> {
    const values: unknown[] = [`${query.prefix}/`];
    const clauses = ["left(path,length($1))=$1", "strpos(substring(path from length($1)+1),'/')=0"];
    for (const filter of query.filters) {
      values.push(filter.field, JSON.stringify(filter.value));
      clauses.push(`value->($${values.length - 1}::text) ${filter.operation === '==' ? '=' : filter.operation} $${values.length}::jsonb`);
    }
    let order = 'path ASC';
    if (query.sort) {values.push(query.sort.field); order = `value->($${values.length}::text) ${query.sort.direction === 'desc' ? 'DESC' : 'ASC'}, path DESC`;}
    values.push(query.maximum);
    const rows = await connection.query(`SELECT path,value FROM documents WHERE ${clauses.join(' AND ')} ORDER BY ${order} LIMIT $${values.length}`, values);
    return new QuerySnapshot(rows.rows.map(row => new Snapshot(this.doc(row.path), decode(row.value))));
  }
  async notesPage(pairId: string, maximum: number, cursor?: {publishedAt: number; noteId: string}): Promise<DocumentData[]> {
    const prefix = `pairs/${pairId}/notes/`, values: unknown[] = [prefix];
    let condition = '';
    if (cursor) {
      values.push(cursor.publishedAt, cursor.noteId);
      condition = " AND ((value->'publishedAt'->>'$time')::bigint < $2 OR ((value->'publishedAt'->>'$time')::bigint = $2 AND value->>'id' < $3))";
    }
    values.push(maximum);
    const rows = await this.pool.query(`SELECT value FROM documents WHERE left(path,length($1))=$1 AND strpos(substring(path from length($1)+1),'/')=0${condition}
      ORDER BY (value->'publishedAt'->>'$time')::bigint DESC, value->>'id' DESC LIMIT $${values.length}`, values);
    return rows.rows.map(row => decode(row.value));
  }
  async pruneExpiredCredentials(now: number): Promise<void> {
    await this.runTransaction(async tx => {
      // Refresh records live until their absolute family deadline, preserving reuse detection.
      await tx.client.query(`DELETE FROM documents WHERE
        ((path LIKE 'authChallenges/%' OR path LIKE 'authAssertions/%' OR path LIKE 'authAccess/%'
          OR path LIKE 'authRefresh/%' OR path LIKE 'widgetSessions/%') AND (value->'expiresAt'->>'$time')::bigint <= $1)
        OR (path LIKE 'authSessions/%' AND (value->'refreshExpiresAt'->>'$time')::bigint <= $1)
        OR (path LIKE 'rateLimits/%' AND (value->'until'->>'$time')::bigint <= $1)`, [now]);
    });
  }
  async messagesPage(pairId: string, maximum: number, cursor?: {sentAt: number; messageId: string}): Promise<DocumentData[]> {
    const prefix = `pairs/${pairId}/messages/`, values: unknown[] = [prefix];
    let condition = '';
    if (cursor) {
      values.push(cursor.sentAt, cursor.messageId);
      condition = " AND ((value->'sentAt'->>'$time')::bigint < $2 OR ((value->'sentAt'->>'$time')::bigint = $2 AND value->>'id' < $3))";
    }
    values.push(maximum);
    const rows = await this.pool.query(`SELECT value FROM documents WHERE left(path,length($1))=$1 AND strpos(substring(path from length($1)+1),'/')=0${condition}
      ORDER BY (value->'sentAt'->>'$time')::bigint DESC, value->>'id' DESC LIMIT $${values.length}`, values);
    return rows.rows.map(row => decode(row.value));
  }
  async photosPage(pairId: string, pairEpoch: number, maximum: number, cursor?: {sentAt: number; photoId: string}): Promise<DocumentData[]> {
    const prefix = `pairs/${pairId}/photos/`, values: unknown[] = [prefix, pairEpoch];
    let condition = '';
    if (cursor) {
      values.push(cursor.sentAt, cursor.photoId);
      condition = " AND ((value->'sentAt'->>'$time')::bigint < $3 OR ((value->'sentAt'->>'$time')::bigint = $3 AND value->>'id' < $4))";
    }
    values.push(maximum);
    const rows = await this.pool.query(`SELECT value FROM documents WHERE left(path,length($1))=$1 AND strpos(substring(path from length($1)+1),'/')=0
      AND (value->>'pairEpoch')::bigint=$2${condition}
      ORDER BY (value->'sentAt'->>'$time')::bigint DESC, value->>'id' DESC LIMIT $${values.length}`, values);
    return rows.rows.map(row => decode(row.value));
  }
  async lettersPage(pairId: string, maximum: number, cursor?: {sentAt: number; letterId: string}): Promise<DocumentData[]> {
    const prefix = `pairs/${pairId}/letters/`, values: unknown[] = [prefix];
    // Older sealed letters predate sealedAt; their public sentAt is createdAt.
    const sentAt = "coalesce((value->'sealedAt'->>'$time')::bigint, (value->'createdAt'->>'$time')::bigint)";
    let condition = '';
    if (cursor) {
      values.push(cursor.sentAt, cursor.letterId);
      condition = ` AND (${sentAt} < $2 OR (${sentAt} = $2 AND value->>'id' < $3))`;
    }
    values.push(maximum);
    const rows = await this.pool.query(`SELECT value FROM documents WHERE left(path,length($1))=$1 AND strpos(substring(path from length($1)+1),'/')=0
      AND value->>'status'='sealed'${condition}
      ORDER BY ${sentAt} DESC, value->>'id' DESC LIMIT $${values.length}`, values);
    return rows.rows.map(row => decode(row.value));
  }
  async runTransaction<T>(operation: (tx: Transaction) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL lock_timeout = '15s'");
      await client.query('SELECT pg_advisory_xact_lock(727001)');
      const tx = new Transaction(this, client), result = await operation(tx);
      await tx.flush(); await client.query('COMMIT');
      return result;
    } catch (error) {await client.query('ROLLBACK'); throw error;}
    finally {client.release();}
  }
  async terminate(): Promise<void> {await this.pool.end();}
}
