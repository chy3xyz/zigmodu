import { query } from '@solidjs/router';
import { getRequestEvent } from 'solid-js/web';
import { CSRF_COOKIE } from '@/libs/csrfConstants';

function readCookie(request: Request, name: string): string | undefined {
  const raw = request.headers.get('cookie');
  if (!raw) return undefined;
  for (const part of raw.split(';')) {
    const [k, ...rest] = part.trim().split('=');
    if (k === name) return decodeURIComponent(rest.join('='));
  }
  return undefined;
}

/** CSRF token from middleware locals (preferred) or request cookie. */
export const queryCsrfToken = query(async () => {
  'use server';
  const event = getRequestEvent();
  if (!event?.request) return '';
  const fromLocals = (event.locals as { csrfToken?: string }).csrfToken;
  if (fromLocals) return fromLocals;
  return readCookie(event.request, CSRF_COOKIE) ?? '';
}, 'csrf');
