import { Title } from '@solidjs/meta';
import { A, useSubmission } from '@solidjs/router';
import { Show, createSignal } from 'solid-js';
import { formForgotPassword } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredContainer } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { Logo } from '@/templates/Logo';

export default function ForgotPasswordPage() {
  const t = useTranslations();
  const submission = useSubmission(formForgotPassword);
  const [sent, setSent] = createSignal(false);

  return (
    <CenteredContainer>
      <Title>{t('ForgotPassword.meta_title') as string}</Title>
      <A href="/" class="mb-4"><Logo /></A>
      <div class="w-full max-w-sm rounded-xl border bg-card p-6 shadow-sm">
        <h1 class="mb-2 text-center text-xl font-semibold">{t('ForgotPassword.title')}</h1>
        <p class="mb-4 text-center text-sm text-muted-foreground">{t('ForgotPassword.description')}</p>
        <Show
          when={!sent()}
          fallback={<p class="text-center text-sm">{t('ForgotPassword.sent')}</p>}
        >
          <form
            action={formForgotPassword}
            method="post"
            class="space-y-4"
            onSubmit={() => setSent(true)}
          >
            <CsrfField />
            <label class="block text-sm font-medium">
              {t('SignIn.email')}
              <input name="email" type="email" required class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
            </label>
            <button type="submit" class={buttonVariants({ class: 'w-full' })} disabled={submission.pending}>
              {t('ForgotPassword.submit')}
            </button>
          </form>
        </Show>
        <p class="mt-4 text-center text-sm">
          <A href="/sign-in" class="underline">{t('Navbar.sign_in')}</A>
        </p>
      </div>
    </CenteredContainer>
  );
}
