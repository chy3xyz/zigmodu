import { Title, Meta } from '@solidjs/meta';
import type { RouteSectionProps } from '@solidjs/router';
import { createAsync, useSubmission } from '@solidjs/router';
import { Show } from 'solid-js';
import { formResendVerification, querySession } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { DashboardHeader } from '@/features/dashboard/DashboardHeader';
import { useTranslations } from '@/libs/I18nContext';

export default function DashboardLayout(props: RouteSectionProps) {
  const t = useTranslations();
  const session = createAsync(() => querySession('/dashboard'));
  const resend = useSubmission(formResendVerification);

  return (
    <>
      <Title>{t('DashboardLayout.meta_title') as string}</Title>
      <Meta name="description" content={t('DashboardLayout.meta_description') as string} />
      <Show when={session() && !session()!.emailVerified}>
        <div class="bg-amber-100 px-3 py-2 text-center text-sm text-amber-900">
          {t('VerifyEmail.banner')}
          {' '}
          <form action={formResendVerification} method="post" class="inline">
            <CsrfField />
            <button type="submit" class="underline" disabled={resend.pending}>
              {t('VerifyEmail.resend')}
            </button>
          </form>
        </div>
      </Show>
      <div class="shadow-md">
        <div class="mx-auto flex max-w-7xl items-center justify-between px-3 py-4">
          <DashboardHeader
            menu={[
              { href: '/dashboard', label: t('DashboardLayout.home') as string },
              { href: '/dashboard/members', label: t('DashboardLayout.members') as string },
              { href: '/dashboard/organization-profile', label: t('DashboardLayout.settings') as string },
              { href: '/dashboard/billing', label: t('DashboardLayout.billing') as string },
              { href: '/dashboard/premium', label: t('DashboardLayout.premium') as string },
            ]}
          />
        </div>
      </div>
      <div class="min-h-[calc(100vh-72px)] bg-muted">
        <div class="mx-auto max-w-7xl px-3 pt-6 pb-16">
          {props.children}
        </div>
      </div>
    </>
  );
}
