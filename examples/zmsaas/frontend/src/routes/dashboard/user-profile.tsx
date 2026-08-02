import { createAsync, useSubmission } from '@solidjs/router';
import { Show } from 'solid-js';
import { formChangePassword, formUpdateProfile, querySession } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { TitleBar } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';

export default function UserProfilePage() {
  const t = useTranslations();
  const session = createAsync(() => querySession('/dashboard/user-profile'));
  const profileSubmission = useSubmission(formUpdateProfile);
  const passwordSubmission = useSubmission(formChangePassword);

  return (
    <>
      <TitleBar title={t('UserProfilePage.title_bar')} description={t('UserProfilePage.title_bar_description')} />
      <div class="grid max-w-2xl gap-6 lg:grid-cols-2">
        <form action={formUpdateProfile} method="post" class="space-y-3 rounded-xl border bg-card p-6">
          <CsrfField />
          <label class="block text-sm">
            {t('SignUp.name')}
            <input name="name" value={session()?.name ?? ''} required class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <div class="text-sm text-muted-foreground">{session()?.email}</div>
          <button type="submit" class={buttonVariants()} disabled={profileSubmission.pending}>
            {t('UserProfilePage.save_profile')}
          </button>
        </form>
        <form action={formChangePassword} method="post" class="space-y-3 rounded-xl border bg-card p-6">
          <CsrfField />
          <label class="block text-sm">
            {t('UserProfilePage.current_password')}
            <input name="currentPassword" type="password" required class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <label class="block text-sm">
            {t('UserProfilePage.new_password')}
            <input name="newPassword" type="password" required minLength={6} class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
          </label>
          <button type="submit" class={buttonVariants({ variant: 'outline' })} disabled={passwordSubmission.pending}>
            {t('UserProfilePage.change_password')}
          </button>
          <Show when={passwordSubmission.result instanceof Error}>
            <p class="text-sm text-destructive">{(passwordSubmission.result as Error).message}</p>
          </Show>
          <Show when={passwordSubmission.result && !(passwordSubmission.result instanceof Error)}>
            <p class="text-sm text-green-600">OK</p>
          </Show>
        </form>
      </div>
    </>
  );
}
