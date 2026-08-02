import { A, createAsync } from '@solidjs/router';
import { Show } from 'solid-js';
import { querySession } from '@/auth';
import { LocaleSwitcher } from '@/components/LocaleSwitcher';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredMenu } from '@/features/landing/CenteredMenu';
import { Section } from '@/features/landing/Section';
import { useTranslations } from '@/libs/I18nContext';
import { AppConfig } from '@/utils/AppConfig';
import { Logo } from './Logo';

export function Navbar() {
  const t = useTranslations();
  const session = createAsync(() => querySession('/'));

  return (
    <Section class="px-3 py-6">
      <CenteredMenu
        logo={<Logo />}
        rightMenu={(
          <>
            <li>
              <LocaleSwitcher />
            </li>
            <Show
              when={session()?.id}
              fallback={(
                <>
                  <li class="mr-2.5 ml-1">
                    <A href="/sign-in">{t('Navbar.sign_in')}</A>
                  </li>
                  <li>
                    <A class={buttonVariants()} href="/sign-up">
                      {t('Navbar.sign_up')}
                    </A>
                  </li>
                </>
              )}
            >
              <li>
                <A class={buttonVariants()} href="/dashboard">
                  {t('Navbar.dashboard')}
                </A>
              </li>
            </Show>
          </>
        )}
      >
        <li><a href="/#features">{t('Navbar.features')}</a></li>
        <li><a href="/#pricing">{t('Navbar.pricing')}</a></li>
        <li><a href="/#faq">{t('Navbar.faq')}</a></li>
        <li>
          <a href={AppConfig.githubUrl} target="_blank" rel="noopener noreferrer">
            {t('Navbar.github')}
          </a>
        </li>
      </CenteredMenu>
    </Section>
  );
}
