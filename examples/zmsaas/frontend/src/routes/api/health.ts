import type { APIEvent } from '@solidjs/start/server';
import { db } from '@/libs/DB';
import { sql } from 'drizzle-orm';

export async function GET(_event: APIEvent) {
  let dbOk = false;
  try {
    await db.execute(sql`select 1`);
    dbOk = true;
  }
  catch {
    dbOk = false;
  }

  const body = {
    status: dbOk ? 'ok' : 'degraded',
    db: dbOk ? 'up' : 'down',
    time: new Date().toISOString(),
  };

  return new Response(JSON.stringify(body), {
    status: dbOk ? 200 : 503,
    headers: { 'content-type': 'application/json' },
  });
}
