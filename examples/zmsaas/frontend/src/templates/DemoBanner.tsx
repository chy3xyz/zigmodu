import { A, createAsync } from '@solidjs/router';
import { querySession } from '@/auth';
import { StickyBanner } from '@/features/landing/StickyBanner';
import { useTranslations } from '@/libs/I18nContext';

export function DemoBanner() {
  const t = useTranslations();
  const session = createAsync(() => querySession('/'));
  const href = () => (session()?.id ? '/dashboard' : '/sign-up');

  return (
    <StickyBanner>
      {t('DemoBanner.text')}
      {' '}
      <A href={href()}>{t('DemoBanner.cta')}</A>
    </StickyBanner>
  );
}
