import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';
import { Env } from '@/libs/Env';
import * as schema from '@/models/Schema';

export type AppDb = ReturnType<typeof createDbConnection>;

export const createDbConnection = () => {
  const pool = new Pool({
    connectionString: Env.DATABASE_URL,
  });

  pool.on('error', (error) => {
    console.error(`Database pool error: ${error.message}`);
  });

  return drizzle({
    client: pool,
    schema,
  });
};
