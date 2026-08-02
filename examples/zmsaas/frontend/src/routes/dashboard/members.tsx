import { createAsync, useSubmission } from '@solidjs/router';
import { For, Show } from 'solid-js';
import {
  formInviteMember,
  formRemoveMember,
  formResendInvite,
  formRevokeInvite,
  queryMembers,
  queryPendingInvites,
  querySession,
} from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { TitleBar } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { ORG_ROLE } from '@/types/Auth';

export default function MembersPage() {
  const t = useTranslations();
  const session = createAsync(() => querySession('/dashboard/members'));
  const members = createAsync(() => queryMembers());
  const invites = createAsync(() => queryPendingInvites());
  const inviteSubmission = useSubmission(formInviteMember);

  return (
    <>
      <TitleBar title={t('MembersPage.title_bar')} description={t('MembersPage.title_bar_description')} />
      <div class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-xl border bg-card p-6">
          <h2 class="mb-4 font-semibold">{t('MembersPage.title_bar')}</h2>
          <ul class="space-y-3">
            <For each={members() ?? []}>
              {(m) => (
                <li class="flex items-center justify-between gap-3 border-b pb-3 text-sm">
                  <div>
                    <div class="font-medium">{m.name}</div>
                    <div class="text-muted-foreground">{m.email} · {m.role}</div>
                  </div>
                  <Show when={session()?.role === ORG_ROLE.ADMIN && m.userId !== session()?.id}>
                    <form action={formRemoveMember} method="post">
                      <CsrfField />
                      <input type="hidden" name="userId" value={m.userId} />
                      <button type="submit" class={buttonVariants({ variant: 'outline', size: 'sm' })}>
                        {t('MembersPage.remove')}
                      </button>
                    </form>
                  </Show>
                </li>
              )}
            </For>
          </ul>
        </div>

        <Show when={session()?.role === ORG_ROLE.ADMIN}>
          <div class="space-y-6">
            <div class="rounded-xl border bg-card p-6">
              <h2 class="mb-4 font-semibold">{t('MembersPage.invite')}</h2>
              <form action={formInviteMember} method="post" class="space-y-3">
                <CsrfField />
                <label class="block text-sm">
                  {t('MembersPage.email')}
                  <input name="email" type="email" required class="mt-1 w-full rounded-md border bg-background px-3 py-2" />
                </label>
                <label class="block text-sm">
                  {t('MembersPage.role')}
                  <select name="role" class="mt-1 w-full rounded-md border bg-background px-3 py-2">
                    <option value="member">member</option>
                    <option value="admin">admin</option>
                  </select>
                </label>
                <button type="submit" class={buttonVariants()} disabled={inviteSubmission.pending}>
                  {t('MembersPage.invite')}
                </button>
                <Show when={inviteSubmission.result instanceof Error}>
                  <p class="text-sm text-destructive">{(inviteSubmission.result as Error).message}</p>
                </Show>
              </form>
            </div>
            <div class="rounded-xl border bg-card p-6">
              <h2 class="mb-4 font-semibold">{t('MembersPage.pending')}</h2>
              <ul class="space-y-3 text-sm">
                <For each={invites() ?? []} fallback={<li class="text-muted-foreground">—</li>}>
                  {inv => (
                    <li class="flex flex-wrap items-center justify-between gap-2 border-b pb-2">
                      <div>
                        <div>{inv.email}</div>
                        <div class="text-muted-foreground">{inv.role}</div>
                      </div>
                      <div class="flex gap-2">
                        <form action={formResendInvite} method="post">
                          <CsrfField />
                          <input type="hidden" name="invitationId" value={inv.id} />
                          <button type="submit" class={buttonVariants({ variant: 'outline', size: 'sm' })}>
                            {t('MembersPage.resend')}
                          </button>
                        </form>
                        <form action={formRevokeInvite} method="post">
                          <CsrfField />
                          <input type="hidden" name="invitationId" value={inv.id} />
                          <button type="submit" class={buttonVariants({ variant: 'destructive', size: 'sm' })}>
                            {t('MembersPage.revoke')}
                          </button>
                        </form>
                      </div>
                    </li>
                  )}
                </For>
              </ul>
            </div>
          </div>
        </Show>
      </div>
    </>
  );
}
