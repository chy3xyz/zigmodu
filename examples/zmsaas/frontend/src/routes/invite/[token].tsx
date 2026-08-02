import { Title } from '@solidjs/meta';
import { useParams, useSubmission, createAsync } from '@solidjs/router';
import { Show } from 'solid-js';
import { formAcceptInvite, querySession } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredContainer } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { Logo } from '@/templates/Logo';

export default function InvitePage() {
  const t = useTranslations();
  const params = useParams();
  const session = createAsync(() => querySession(`/invite/${params.token}`));
  const submission = useSubmission(formAcceptInvite);

  return (
    <CenteredContainer>
      <Title>{t('InvitePage.meta_title') as string}</Title>
      <Logo />
      <div class="mt-4 w-full max-w-sm rounded-xl border bg-card p-6 shadow-sm">
        <h1 class="mb-4 text-center text-xl font-semibold">{t('InvitePage.title')}</h1>
        <form action={formAcceptInvite} method="post" class="space-y-3">
          <CsrfField />
          <input type="hidden" name="token" value={params.token} />
          <Show when={!session()?.id}>
            <label class="block text-sm">
              {t('SignUp.name')}
              <input name="name" required class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
            </label>
            <label class="block text-sm">
              {t('SignUp.password')}
              <input name="password" type="password" required minLength={6} class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
            </label>
          </Show>
          <button type="submit" class={buttonVariants({ class: 'w-full' })} disabled={submission.pending}>
            {session()?.id ? t('InvitePage.accept') : t('InvitePage.create_account')}
          </button>
          <Show when={submission.result instanceof Error}>
            <p class="text-center text-sm text-destructive">{(submission.result as Error).message}</p>
          </Show>
        </form>
      </div>
    </CenteredContainer>
  );
}
