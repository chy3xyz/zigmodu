import { flatten, resolveTemplate, translator } from '@solid-primitives/i18n';
import { createMemo, createRoot } from 'solid-js';
import en from '@/locales/en.json';
import zh from '@/locales/zh.json';
import type { Dictionary } from '@/types/I18n';
import { AppConfig, type LocaleId } from '@/utils/AppConfig';
import { stripLocale } from '@/utils/Helpers';

const dictionaries: Record<string, Dictionary> = {
  en,
  zh,
};

export function isLocale(value: string): value is LocaleId {
  return AppConfig.i18n.locales.some(l => l.id === value);
}

export function loadDictionary(locale: string): Dictionary {
  return dictionaries[locale] ?? dictionaries[AppConfig.i18n.defaultLocale]!;
}

export function createI18n(locale: () => string) {
  const flat = createMemo(() => flatten(loadDictionary(locale())));
  const t = translator(flat, resolveTemplate);
  return { t, dict: () => loadDictionary(locale()), flat };
}

export function localeFromPath(pathname: string): string {
  return stripLocale(pathname).locale;
}

export function localizedPath(path: string, locale: string): string {
  const normalized = path.startsWith('/') ? path : `/${path}`;
  if (locale === AppConfig.i18n.defaultLocale) {
    return normalized;
  }
  if (normalized === '/') {
    return `/${locale}`;
  }
  return `/${locale}${normalized}`;
}

export function switchLocalePath(pathname: string, nextLocale: string): string {
  const { path } = stripLocale(pathname);
  return localizedPath(path, nextLocale);
}

export const defaultLocale = AppConfig.i18n.defaultLocale;

export function getStaticTranslator(dict: Dictionary) {
  return createRoot(() => {
    const flat = () => flatten(dict);
    return translator(flat, resolveTemplate);
  });
}
