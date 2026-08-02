import { createDbConnection } from '@/utils/DBConnection';
import { Env } from './Env';

declare global {
  var cachedDrizzle: ReturnType<typeof createDbConnection> | undefined;
}

const db = globalThis.cachedDrizzle ?? createDbConnection();

if (Env.NODE_ENV !== 'production') {
  globalThis.cachedDrizzle = db;
}

export { db };
