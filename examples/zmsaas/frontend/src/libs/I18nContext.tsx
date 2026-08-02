import { createContext, useContext, type ParentProps, type Accessor, createSignal, createEffect, onMount } from 'solid-js';
import { getRequestEvent, isServer } from 'solid-js/web';
import { createI18n, isLocale } from '@/libs/i18n';
import { AppConfig } from '@/utils/AppConfig';

type I18nContextValue = ReturnType<typeof createI18n> & {
  locale: Accessor<string>;
  setLocale: (locale: string) => void;
};

const I18nContext = createContext<I18nContextValue>();

function readCookieLocale(): string {
  if (isServer) return AppConfig.i18n.defaultLocale;
  const match = document.cookie.match(/(?:^|; )locale=([^;]*)/);
  const value = match?.[1] ? decodeURIComponent(match[1]) : '';
  return isLocale(value) ? value : AppConfig.i18n.defaultLocale;
}

function resolveInitialLocale(explicit?: string) {
  if (explicit && isLocale(explicit)) return explicit;
  if (isServer) {
    const event = getRequestEvent();
    const fromLocals = (event?.locals as { locale?: string } | undefined)?.locale;
    if (fromLocals && isLocale(fromLocals)) return fromLocals;
  }
  return AppConfig.i18n.defaultLocale;
}

export function I18nProvider(props: ParentProps<{ initialLocale?: string }>) {
  const [locale, setLocaleState] = createSignal(resolveInitialLocale(props.initialLocale));

  onMount(() => {
    const fromCookie = readCookieLocale();
    if (fromCookie !== locale()) {
      setLocaleState(fromCookie);
    }
  });

  const setLocale = (next: string) => {
    if (!isLocale(next)) return;
    setLocaleState(next);
    if (!isServer) {
      document.cookie = `locale=${encodeURIComponent(next)};path=/;max-age=${60 * 60 * 24 * 365};samesite=lax`;
    }
  };

  const i18n = createI18n(locale);

  createEffect(() => {
    if (!isServer) {
      document.documentElement.lang = locale();
    }
  });

  return (
    <I18nContext.Provider value={{ ...i18n, locale, setLocale }}>
      {props.children}
    </I18nContext.Provider>
  );
}

export function useI18n() {
  const ctx = useContext(I18nContext);
  if (!ctx) {
    throw new Error('useI18n must be used within I18nProvider');
  }
  return ctx;
}

export function useTranslations() {
  return useI18n().t;
}

export function useLocale() {
  return useI18n().locale;
}
