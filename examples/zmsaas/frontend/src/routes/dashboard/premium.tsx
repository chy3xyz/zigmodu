import { createAsync } from '@solidjs/router';
import { queryPremiumFeature } from '@/libs/billing';
import { TitleBar } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';

export default function PremiumPage() {
  const t = useTranslations();
  const data = createAsync(() => queryPremiumFeature());

  return (
    <>
      <TitleBar
        title={t('PremiumPage.title_bar')}
        description={t('PremiumPage.title_bar_description')}
      />
      <div class="max-w-xl rounded-xl border bg-card p-6">
        <p class="text-sm text-muted-foreground">{t('PremiumPage.body')}</p>
        <p class="mt-4 text-sm font-medium">
          {t('PremiumPage.status')}
          {': '}
          {data()?.status}
        </p>
      </div>
    </>
  );
}
