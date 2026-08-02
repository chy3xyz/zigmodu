import { Title } from '@solidjs/meta';
import { A, useSearchParams, useSubmission } from '@solidjs/router';
import { Show } from 'solid-js';
import { formResetPassword } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredContainer } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { Logo } from '@/templates/Logo';

export default function ResetPasswordPage() {
  const t = useTranslations();
  const [params] = useSearchParams();
  const submission = useSubmission(formResetPassword);

  return (
    <CenteredContainer>
      <Title>{t('ResetPassword.meta_title') as string}</Title>
      <A href="/" class="mb-4"><Logo /></A>
      <div class="w-full max-w-sm rounded-xl border bg-card p-6 shadow-sm">
        <h1 class="mb-4 text-center text-xl font-semibold">{t('ResetPassword.title')}</h1>
        <form action={formResetPassword} method="post" class="space-y-4">
          <CsrfField />
          <input type="hidden" name="token" value={params.token ?? ''} />
          <label class="block text-sm font-medium">
            {t('SignIn.password')}
            <input name="password" type="password" required minLength={6} class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <button type="submit" class={buttonVariants({ class: 'w-full' })} disabled={submission.pending}>
            {t('ResetPassword.submit')}
          </button>
          <Show when={submission.result instanceof Error}>
            <p class="text-center text-sm text-destructive">{(submission.result as Error).message}</p>
          </Show>
        </form>
      </div>
    </CenteredContainer>
  );
}
