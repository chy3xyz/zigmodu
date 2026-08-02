import { getRequestEvent } from 'solid-js/web';
import { createCsrfToken, CSRF_COOKIE, CSRF_FIELD } from '@/libs/csrfConstants';
import { Env } from '@/libs/Env';

export { CSRF_COOKIE, CSRF_FIELD, createCsrfToken };

export function csrfCookieHeader(token: string) {
  const secure = Env.NODE_ENV === 'production' ? '; Secure' : '';
  return `${CSRF_COOKIE}=${encodeURIComponent(token)}; Path=/; Max-Age=${60 * 60 * 24 * 7}; SameSite=Lax; HttpOnly${secure}`;
}

function readCookie(request: Request, name: string): string | undefined {
  const raw = request.headers.get('cookie');
  if (!raw) return undefined;
  for (const part of raw.split(';')) {
    const [k, ...rest] = part.trim().split('=');
    if (k === name) return decodeURIComponent(rest.join('='));
  }
  return undefined;
}

/** Origin / Referer must match app URL for mutating requests when headers are present. */
export function assertSameOrigin(request: Request) {
  const origin = request.headers.get('origin');
  const referer = request.headers.get('referer');
  const allowed = new URL(Env.PUBLIC_APP_URL).origin;

  if (origin) {
    if (origin !== allowed && origin !== new URL(request.url).origin) {
      throw new Error('Invalid request origin');
    }
    return;
  }
  if (referer) {
    try {
      const refOrigin = new URL(referer).origin;
      if (refOrigin !== allowed && refOrigin !== new URL(request.url).origin) {
        throw new Error('Invalid request origin');
      }
    }
    catch {
      throw new Error('Invalid request origin');
    }
  }
}

export function assertCsrf(formData: FormData, request?: Request) {
  const event = getRequestEvent();
  const req = request ?? event?.request;
  if (!req) throw new Error('Missing request for CSRF check');

  assertSameOrigin(req);

  const cookieToken
    = readCookie(req, CSRF_COOKIE)
      ?? (event?.locals as { csrfToken?: string } | undefined)?.csrfToken;
  const formToken = formData.get(CSRF_FIELD);
  if (
    typeof formToken !== 'string'
    || !cookieToken
    || formToken.length < 16
    || formToken !== cookieToken
  ) {
    throw new Error('Invalid CSRF token');
  }
}

export async function requireCsrf(formData: FormData) {
  try {
    assertCsrf(formData);
  }
  catch (error) {
    return error instanceof Error ? error : new Error('CSRF validation failed');
  }
  return null;
}

/** Validate CSRF (+ optional rate limit). Returns Error or null. */
export async function guardForm(
  formData: FormData,
  opts?: { rateKey?: string; limit?: number; windowMs?: number },
) {
  const csrfError = await requireCsrf(formData);
  if (csrfError) return csrfError;

  if (opts?.rateKey) {
    const { rateLimit, clientKey } = await import('@/libs/rateLimit');
    const event = getRequestEvent();
    const ip = clientKey(event?.request, 'local');
    const result = rateLimit({
      key: `${opts.rateKey}:${ip}`,
      limit: opts.limit ?? 20,
      windowMs: opts.windowMs ?? 60_000,
    });
    if (!result.ok) {
      return new Error(`Too many attempts. Try again in ${result.retryAfterSec}s`);
    }
  }
  return null;
}
