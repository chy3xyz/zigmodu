import { describe, expect, it } from 'vitest';
import { CSRF_FIELD } from '@/libs/csrfConstants';
import { assertSameOrigin } from '@/libs/csrf';

describe('csrf helpers', () => {
  it('exports csrf field name', () => {
    expect(CSRF_FIELD).toBe('csrf');
  });

  it('accepts matching request origin', () => {
    const req = new Request('http://localhost:3000/sign-in', {
      headers: { origin: 'http://localhost:3000' },
    });
    expect(() => assertSameOrigin(req)).not.toThrow();
  });

  it('rejects mismatched origin', () => {
    const req = new Request('http://localhost:3000/sign-in', {
      headers: { origin: 'https://evil.example' },
    });
    expect(() => assertSameOrigin(req)).toThrow(/origin/i);
  });
});
