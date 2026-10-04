const {Pool} = require('pg');
const pool = new Pool({connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 1000});
(async () => {
  if (!process.env.DATABASE_URL || !['127.0.0.1', 'localhost', 'postgres'].includes(new URL(process.env.DATABASE_URL).hostname)) throw Error('Use an isolated local test database');
  const endpoint = process.env.TEST_S3_ENDPOINT ?? 'http://127.0.0.1:59000';
  if (!['127.0.0.1', 'localhost', 'minio'].includes(new URL(endpoint).hostname)) throw Error('Use an isolated local S3 endpoint');
  const until = Date.now() + 60_000;
  while (Date.now() < until) {
    try {
      await pool.query('SELECT 1');
      const response = await fetch(`${endpoint}/minio/health/live`, {signal: AbortSignal.timeout(1000)});
      if (response.ok) {console.info('PostgreSQL and MinIO test services ready'); return;}
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw Error('Local test services did not become ready');
})().catch(error => {console.error(error.message); process.exitCode = 1;}).finally(() => pool.end());
