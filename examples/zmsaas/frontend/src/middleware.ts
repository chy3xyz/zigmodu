import { createMiddleware } from '@solidjs/start/middleware';
import { createCsrfToken, CSRF_COOKIE, csrfCookieHeader } from '@/libs/csrf';
import { isLocale } from '@/libs/i18n';
import { AppConfig } from '@/utils/AppConfig';
import { stripLocale } from '@/utils/Helpers';

const LOCALE_COOKIE = 'locale';
const SESSION_COOKIE = 'saas_session';
const PROTECTED_PREFIXES = ['/dashboard', '/onboarding'];

function readCookie(request: Request, name: string): string | undefined {
  const raw = request.headers.get('cookie');
  if (!raw) return undefined;
  for (const part of raw.split(';')) {
    const [k, ...rest] = part.trim().split('=');
    if (k === name) return decodeURIComponent(rest.join('='));
  }
  return undefined;
}

function isProtected(path: string) {
  return PROTECTED_PREFIXES.some(
    prefix => path === prefix || path.startsWith(`${prefix}/`),
  );
}

function ensureCsrf(event: { request: Request; response: { headers: Headers }; locals: Record<string, unknown> }) {
  const existing = readCookie(event.request, CSRF_COOKIE);
  const token = existing ?? createCsrfToken();
  event.locals.csrfToken = token;
  if (!existing) {
    event.response.headers.append('Set-Cookie', csrfCookieHeader(token));
  }
  return token;
}

export default createMiddleware({
  onRequest: (event) => {
    const url = new URL(event.request.url);
    if (url.pathname.startsWith('/api/')) {
      return;
    }

    ensureCsrf(event);

    const segments = url.pathname.split('/').filter(Boolean);

    if (segments[0] === AppConfig.i18n.defaultLocale) {
      const rest = segments.length > 1 ? `/${segments.slice(1).join('/')}` : '/';
      return Response.redirect(new URL(rest + url.search, url.origin), 302);
    }

    const { locale: pathLocale, path } = stripLocale(url.pathname);
    const cookieLocale = readCookie(event.request, LOCALE_COOKIE);
    const locale
      = (pathLocale !== AppConfig.i18n.defaultLocale && isLocale(pathLocale) ? pathLocale : undefined)
        ?? (cookieLocale && isLocale(cookieLocale) ? cookieLocale : undefined)
        ?? AppConfig.i18n.defaultLocale;

    event.locals.locale = locale;
    event.locals.path = path;

    if (cookieLocale !== locale) {
      event.response.headers.append(
        'Set-Cookie',
        `${LOCALE_COOKIE}=${encodeURIComponent(locale)}; Path=/; Max-Age=${60 * 60 * 24 * 365}; SameSite=Lax`,
      );
    }

    const hasSession = Boolean(readCookie(event.request, SESSION_COOKIE));
    if (isProtected(path) && !hasSession) {
      const signIn = new URL('/sign-in', url.origin);
      signIn.searchParams.set('redirect', path);
      return Response.redirect(signIn, 302);
    }

    if ((path === '/sign-in' || path === '/sign-up') && hasSession) {
      return Response.redirect(new URL('/dashboard', url.origin), 302);
    }
  },
});
