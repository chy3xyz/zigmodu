import { Title, Meta } from '@solidjs/meta';
import { A, useSearchParams, useSubmission } from '@solidjs/router';
import { Show } from 'solid-js';
import { formSignIn } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredContainer } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { Logo } from '@/templates/Logo';

export default function SignInPage() {
  const t = useTranslations();
  const [params] = useSearchParams();
  const submission = useSubmission(formSignIn);

  return (
    <CenteredContainer>
      <Title>{t('SignIn.meta_title') as string}</Title>
      <Meta name="description" content={t('SignIn.meta_description') as string} />
      <A href="/" class="mb-4"><Logo /></A>
      <div class="w-full max-w-sm rounded-xl border bg-card p-6 shadow-sm">
        <h1 class="mb-4 text-center text-xl font-semibold">{t('SignIn.meta_title')}</h1>
        <form action={formSignIn} method="post" class="space-y-4">
          <CsrfField />
          <input type="hidden" name="redirect" value={params.redirect ?? '/dashboard'} />
          <label class="block text-sm font-medium">
            {t('SignIn.email')}
            <input name="email" type="email" required autocomplete="email" class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <label class="block text-sm font-medium">
            {t('SignIn.password')}
            <input name="password" type="password" required minLength={6} autocomplete="current-password" class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <button type="submit" class={buttonVariants({ class: 'w-full' })} disabled={submission.pending}>
            {t('Navbar.sign_in')}
          </button>
          <Show when={submission.result instanceof Error}>
            <p class="text-center text-sm text-destructive">{(submission.result as Error).message}</p>
          </Show>
        </form>
        <p class="mt-4 text-center text-sm">
          <A href="/forgot-password" class="text-primary underline">{t('SignIn.forgot_password')}</A>
        </p>
        <p class="mt-2 text-center text-sm text-muted-foreground">
          {t('SignIn.no_account')}
          {' '}
          <A href="/sign-up" class="text-primary underline">{t('Navbar.sign_up')}</A>
        </p>
      </div>
    </CenteredContainer>
  );
}
