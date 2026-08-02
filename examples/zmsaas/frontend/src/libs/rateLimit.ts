type Bucket = { count: number; resetAt: number };

const buckets = new Map<string, Bucket>();

export type RateLimitResult = { ok: true } | { ok: false; retryAfterSec: number };

/**
 * Simple in-memory fixed window rate limiter (per process).
 * Good enough for single-node / local; swap for Redis in multi-instance prod.
 */
export function rateLimit(opts: {
  key: string;
  limit: number;
  windowMs: number;
}): RateLimitResult {
  const now = Date.now();
  const existing = buckets.get(opts.key);
  if (!existing || existing.resetAt <= now) {
    buckets.set(opts.key, { count: 1, resetAt: now + opts.windowMs });
    return { ok: true };
  }
  if (existing.count >= opts.limit) {
    return { ok: false, retryAfterSec: Math.max(1, Math.ceil((existing.resetAt - now) / 1000)) };
  }
  existing.count += 1;
  return { ok: true };
}

/** Test helper */
export function resetRateLimits() {
  buckets.clear();
}

export function clientKey(request: Request | undefined, fallback: string) {
  const forwarded = request?.headers.get('x-forwarded-for')?.split(',')[0]?.trim();
  const realIp = request?.headers.get('x-real-ip')?.trim();
  return forwarded || realIp || fallback;
}
