import { describe, expect, it, beforeEach } from 'vitest';
import { createRawToken, hashPassword, hashToken, verifyPassword } from '@/libs/crypto';
import { rateLimit, resetRateLimits } from '@/libs/rateLimit';

describe('crypto', () => {
  it('hashes and verifies passwords', async () => {
    const hash = await hashPassword('password123');
    await expect(verifyPassword(hash, 'password123')).resolves.toBeUndefined();
    await expect(verifyPassword(hash, 'wrong')).rejects.toThrow();
  });

  it('hashes tokens stably', () => {
    const raw = createRawToken(16);
    expect(hashToken(raw)).toBe(hashToken(raw));
    expect(hashToken(raw)).not.toBe(hashToken(`${raw}x`));
  });
});

describe('rateLimit', () => {
  beforeEach(() => {
    resetRateLimits();
  });

  it('allows requests under the limit', () => {
    expect(rateLimit({ key: 't1', limit: 2, windowMs: 60_000 }).ok).toBe(true);
    expect(rateLimit({ key: 't1', limit: 2, windowMs: 60_000 }).ok).toBe(true);
  });

  it('blocks when limit exceeded', () => {
    rateLimit({ key: 't2', limit: 1, windowMs: 60_000 });
    const blocked = rateLimit({ key: 't2', limit: 1, windowMs: 60_000 });
    expect(blocked.ok).toBe(false);
    if (!blocked.ok) {
      expect(blocked.retryAfterSec).toBeGreaterThan(0);
    }
  });
});
