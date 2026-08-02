import { Title, Meta } from '@solidjs/meta';
import { A, useSearchParams, useSubmission } from '@solidjs/router';
import { Show } from 'solid-js';
import { formSignUp } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredContainer } from '@/features/dashboard/shared';
import { useLocale, useTranslations } from '@/libs/I18nContext';
import { Logo } from '@/templates/Logo';

export default function SignUpPage() {
  const t = useTranslations();
  const locale = useLocale();
  const [params] = useSearchParams();
  const submission = useSubmission(formSignUp);

  return (
    <CenteredContainer>
      <Title>{t('SignUp.meta_title') as string}</Title>
      <Meta name="description" content={t('SignUp.meta_description') as string} />
      <A href="/" class="mb-4"><Logo /></A>
      <div class="w-full max-w-sm rounded-xl border bg-card p-6 shadow-sm">
        <h1 class="mb-4 text-center text-xl font-semibold">{t('SignUp.meta_title')}</h1>
        <form action={formSignUp} method="post" class="space-y-4">
          <CsrfField />
          <input type="hidden" name="redirect" value={params.redirect ?? '/onboarding/organization-selection'} />
          <input type="hidden" name="locale" value={locale()} />
          <label class="block text-sm font-medium">
            {t('SignUp.name')}
            <input name="name" type="text" required autocomplete="name" class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <label class="block text-sm font-medium">
            {t('SignUp.email')}
            <input name="email" type="email" required autocomplete="email" class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <label class="block text-sm font-medium">
            {t('SignUp.password')}
            <input name="password" type="password" required minLength={6} autocomplete="new-password" class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <button type="submit" class={buttonVariants({ class: 'w-full' })} disabled={submission.pending}>
            {t('Navbar.sign_up')}
          </button>
          <Show when={submission.result instanceof Error}>
            <p class="text-center text-sm text-destructive">{(submission.result as Error).message}</p>
          </Show>
        </form>
        <p class="mt-4 text-center text-sm text-muted-foreground">
          {t('SignUp.have_account')}
          {' '}
          <A href="/sign-in" class="text-primary underline">{t('Navbar.sign_in')}</A>
        </p>
      </div>
    </CenteredContainer>
  );
}
