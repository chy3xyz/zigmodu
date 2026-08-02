import { Title, Meta } from '@solidjs/meta';
import { A, createAsync, useSubmission } from '@solidjs/router';
import { For, Show } from 'solid-js';
import { formCreateOrg, formSelectOrg, queryOrgs } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredContainer } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { Logo } from '@/templates/Logo';

export default function OrganizationSelectionPage() {
  const t = useTranslations();
  const orgs = createAsync(() => queryOrgs());
  const createSubmission = useSubmission(formCreateOrg);
  const selectSubmission = useSubmission(formSelectOrg);

  return (
    <CenteredContainer>
      <Title>{t('Onboarding.title') as string}</Title>
      <Meta name="description" content={t('Onboarding.title') as string} />
      <A href="/" class="mb-4"><Logo /></A>
      <div class="w-full max-w-md space-y-6 rounded-xl border bg-card p-6 shadow-sm">
        <h1 class="text-center text-xl font-semibold">{t('Onboarding.title')}</h1>

        <Show when={(orgs() ?? []).length > 0}>
          <ul class="space-y-2">
            <For each={orgs() ?? []}>
              {org => (
                <li>
                  <form action={formSelectOrg} method="post">
                    <CsrfField />
                    <input type="hidden" name="orgId" value={org.id} />
                    <button
                      type="submit"
                      class={buttonVariants({ variant: 'outline', class: 'w-full' })}
                      disabled={selectSubmission.pending}
                    >
                      {org.name}
                    </button>
                  </form>
                </li>
              )}
            </For>
          </ul>
        </Show>

        <form action={formCreateOrg} method="post" class="space-y-3 border-t pt-4">
          <CsrfField />
          <label class="block text-sm font-medium">
            {t('Onboarding.create_label')}
            <input
              name="name"
              type="text"
              required
              placeholder="Acme Inc"
              class="mt-1 w-full rounded-md border bg-background px-3 py-2"
            />
          </label>
          <button type="submit" class={buttonVariants({ class: 'w-full' })} disabled={createSubmission.pending}>
            {t('Onboarding.create')}
          </button>
          <Show when={createSubmission.result instanceof Error}>
            <p class="text-center text-sm text-destructive">{(createSubmission.result as Error).message}</p>
          </Show>
        </form>
      </div>
    </CenteredContainer>
  );
}
