#!/usr/bin/env node
/**
 * Local Postgres-compatible server backed by PGLite (no Docker required).
 * Usage: node scripts/db-server.mjs
 * Env: PGLITE_DATA (default .data/pglite), PGLITE_PORT (default 5432)
 */
import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { PGlite } from '@electric-sql/pglite';
import { PGLiteSocketServer } from '@electric-sql/pglite-socket';

const dataDir = resolve(process.env.PGLITE_DATA ?? '.data/pglite');
const port = Number(process.env.PGLITE_PORT ?? 5432);
const host = process.env.PGLITE_HOST ?? '127.0.0.1';

mkdirSync(dataDir, { recursive: true });

const db = await PGlite.create({ dataDir });
const server = new PGLiteSocketServer({
  db,
  host,
  port,
});

await server.start();
console.info(`[pglite] listening on postgres://postgres@${host}:${port}/postgres`);
console.info(`[pglite] data directory: ${dataDir}`);

const shutdown = async () => {
  await server.stop();
  await db.close();
  process.exit(0);
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
