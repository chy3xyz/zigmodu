import type { ClassValue } from 'clsx';
import { clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';
import { AppConfig } from '@/utils/AppConfig';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export const getBaseUrl = () => {
  return process.env.PUBLIC_APP_URL
    ?? process.env.VITE_PUBLIC_APP_URL
    ?? 'http://localhost:3000';
};

export const getI18nPath = (url: string, locale: string) => {
  if (locale === AppConfig.i18n.defaultLocale) {
    return url;
  }

  return `/${locale}${url}`;
};

/** Strip locale prefix from pathname. */
export function stripLocale(pathname: string): { locale: string; path: string } {
  const segments = pathname.split('/').filter(Boolean);
  const maybeLocale = segments[0];
  if (maybeLocale && AllLocalesSet.has(maybeLocale) && maybeLocale !== AppConfig.i18n.defaultLocale) {
    return {
      locale: maybeLocale,
      path: segments.length > 1 ? `/${segments.slice(1).join('/')}` : '/',
    };
  }
  return { locale: AppConfig.i18n.defaultLocale, path: pathname || '/' };
}

const AllLocalesSet = new Set(AppConfig.i18n.locales.map(l => l.id));
