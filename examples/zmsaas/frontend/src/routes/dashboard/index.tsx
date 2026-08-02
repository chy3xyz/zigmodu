import { PageMessage, TitleBar } from '@/features/dashboard/shared';
import { SponsorLogos } from '@/features/sponsors/SponsorLogos';
import { useTranslations } from '@/libs/I18nContext';

export default function DashboardIndexPage() {
  const t = useTranslations();
  return (
    <>
      <TitleBar
        title={t('DashboardIndexPage.title_bar')}
        description={t('DashboardIndexPage.title_bar_description')}
      />
      <PageMessage
        icon={(
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round">
            <path d="M0 0h24v24H0z" stroke="none" />
            <path d="M12 3l8 4.5v9L12 21l-8-4.5v-9L12 3M12 12l8-4.5M12 12v9M12 12L4 7.5" />
          </svg>
        )}
        title={t('DashboardIndexPage.message_state_title')}
        description={(
          <>
            Customize this page by editing
            {' '}
            <code class="bg-secondary text-secondary-foreground">src/routes/dashboard/index.tsx</code>
            .
          </>
        )}
        button={(
          <div class="mt-7">
            <SponsorLogos />
          </div>
        )}
      />
    </>
  );
}
