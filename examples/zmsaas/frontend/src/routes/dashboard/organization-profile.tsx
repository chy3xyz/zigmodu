import { createAsync, useSubmission } from '@solidjs/router';
import { Show } from 'solid-js';
import { formDeleteOrg, formLeaveOrg, formUpdateOrg, querySession } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { TitleBar } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { ORG_ROLE } from '@/types/Auth';

export default function OrganizationProfilePage() {
  const t = useTranslations();
  const session = createAsync(() => querySession('/dashboard/organization-profile'));
  const submission = useSubmission(formUpdateOrg);
  const leave = useSubmission(formLeaveOrg);
  const del = useSubmission(formDeleteOrg);

  return (
    <>
      <TitleBar
        title={t('OrganizationProfilePage.title_bar')}
        description={t('OrganizationProfilePage.title_bar_description')}
      />
      <div class="max-w-lg space-y-6">
        <div class="rounded-xl border bg-card p-6">
          <Show
            when={session()?.role === ORG_ROLE.ADMIN}
            fallback={(
              <div>
                <div class="text-sm text-muted-foreground">{t('OrganizationProfilePage.org_name')}</div>
                <div class="text-lg font-semibold">{session()?.activeOrgName}</div>
              </div>
            )}
          >
            <form action={formUpdateOrg} method="post" class="space-y-3">
              <CsrfField />
              <label class="block text-sm">
                {t('OrganizationProfilePage.org_name')}
                <input
                  name="name"
                  value={session()?.activeOrgName ?? ''}
                  required
                  class="mt-1 w-full rounded-md border bg-background px-3 py-2"
                />
              </label>
              <div class="text-xs text-muted-foreground">{session()?.activeOrgId}</div>
              <button type="submit" class={buttonVariants()} disabled={submission.pending}>
                {t('OrganizationProfilePage.save')}
              </button>
            </form>
          </Show>
        </div>

        <div class="rounded-xl border border-destructive/40 bg-card p-6">
          <h2 class="mb-2 font-semibold text-destructive">{t('OrganizationProfilePage.danger_zone')}</h2>
          <p class="mb-4 text-sm text-muted-foreground">{t('OrganizationProfilePage.danger_zone_description')}</p>
          <form action={formLeaveOrg} method="post" class="mb-4">
            <CsrfField />
            <button type="submit" class={buttonVariants({ variant: 'outline' })} disabled={leave.pending}>
              {t('OrganizationProfilePage.leave')}
            </button>
            <Show when={leave.result instanceof Error}>
              <p class="mt-2 text-sm text-destructive">{(leave.result as Error).message}</p>
            </Show>
          </form>
          <Show when={session()?.role === ORG_ROLE.ADMIN}>
            <form action={formDeleteOrg} method="post" class="space-y-2">
              <CsrfField />
              <label class="block text-sm">
                {t('OrganizationProfilePage.delete_confirm')}
                <input
                  name="confirm"
                  placeholder={session()?.activeOrgName ?? ''}
                  required
                  class="mt-1 w-full rounded-md border bg-background px-3 py-2"
                />
              </label>
              <button type="submit" class={buttonVariants({ variant: 'destructive' })} disabled={del.pending}>
                {t('OrganizationProfilePage.delete')}
              </button>
              <Show when={del.result instanceof Error}>
                <p class="text-sm text-destructive">{(del.result as Error).message}</p>
              </Show>
            </form>
          </Show>
        </div>
      </div>
    </>
  );
}
