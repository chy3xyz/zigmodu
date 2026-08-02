import type { AppLocale } from '@/types/I18n';

const locales = [
  { id: 'en', name: 'English' },
  { id: 'zh', name: '中文' },
] satisfies AppLocale[];

/** Centralized application configuration */
export const AppConfig = {
  name: 'SaaS SolidJS',
  githubUrl: 'https://github.com/chy3xyz/saas-solidjs',
  i18n: {
    locales,
    defaultLocale: 'en' as const,
    localePrefix: 'as-needed' as const,
  },
  email: {
    support: 'contact@example.com',
  },
} as const;

export const AllLocales = AppConfig.i18n.locales.map(locale => locale.id);

export type LocaleId = (typeof AllLocales)[number];
