import { Title } from '@solidjs/meta';
import { A, useSearchParams, useSubmission } from '@solidjs/router';
import { Show, createEffect } from 'solid-js';
import { formVerifyEmail } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredContainer } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { Logo } from '@/templates/Logo';

export default function VerifyEmailPage() {
  const t = useTranslations();
  const [params] = useSearchParams();
  const submission = useSubmission(formVerifyEmail);

  // Auto-submit once when token + CSRF are ready
  createEffect(() => {
    if (!params.token || submission.pending || submission.result) return;
    const form = document.getElementById('verify-email-form') as HTMLFormElement | null;
    const csrf = form?.querySelector('input[name="csrf"]') as HTMLInputElement | null;
    if (form && csrf?.value) {
      form.requestSubmit();
    }
  });

  return (
    <CenteredContainer>
      <Title>{t('VerifyEmail.meta_title') as string}</Title>
      <A href="/" class="mb-4"><Logo /></A>
      <div class="w-full max-w-sm rounded-xl border bg-card p-6 shadow-sm">
        <h1 class="mb-4 text-center text-xl font-semibold">{t('VerifyEmail.title')}</h1>
        <form id="verify-email-form" action={formVerifyEmail} method="post" class="space-y-4">
          <CsrfField />
          <input type="hidden" name="token" value={params.token ?? ''} />
          <button type="submit" class={buttonVariants({ class: 'w-full' })} disabled={submission.pending || !params.token}>
            {t('VerifyEmail.submit')}
          </button>
          <Show when={submission.result instanceof Error}>
            <p class="text-center text-sm text-destructive">{(submission.result as Error).message}</p>
          </Show>
        </form>
      </div>
    </CenteredContainer>
  );
}
