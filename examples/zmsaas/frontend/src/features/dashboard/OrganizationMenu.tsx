import { A, createAsync, useSubmission } from '@solidjs/router';
import { For, Show } from 'solid-js';
import { formSelectOrg, logout, queryOrgs, querySession } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';

export function OrganizationMenu() {
  const session = createAsync(() => querySession('/dashboard'));
  const orgs = createAsync(() => queryOrgs());
  const selectSubmission = useSubmission(formSelectOrg);

  return (
    <div class="flex items-center gap-2">
      <Show when={session()?.activeOrgName} fallback={<A href="/onboarding/organization-selection" class="text-sm opacity-75">Select org</A>}>
        {name => (
          <DropdownMenu>
            <DropdownMenuTrigger class="max-w-28 truncate rounded-md border px-2 py-1 text-sm sm:max-w-52">
              {name()}
            </DropdownMenuTrigger>
            <DropdownMenuContent>
              <For each={orgs() ?? []}>
                {org => (
                  <form action={formSelectOrg} method="post">
                    <CsrfField />
                    <input type="hidden" name="orgId" value={org.id} />
                    <DropdownMenuItem closeOnSelect={false}>
                      <button type="submit" class="w-full text-left" disabled={selectSubmission.pending}>
                        {org.name}
                      </button>
                    </DropdownMenuItem>
                  </form>
                )}
              </For>
              <DropdownMenuItem>
                <A href="/onboarding/organization-selection">Manage organizations</A>
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </Show>
    </div>
  );
}

export function UserMenu() {
  const session = createAsync(() => querySession('/dashboard'));
  return (
    <DropdownMenu>
      <DropdownMenuTrigger class="rounded-md border px-2 py-1.5 text-sm">
        {session()?.name ?? session()?.email ?? 'Account'}
      </DropdownMenuTrigger>
      <DropdownMenuContent>
        <DropdownMenuItem>
          <A href="/dashboard/user-profile">Profile</A>
        </DropdownMenuItem>
        <DropdownMenuItem>
          <A href="/dashboard/organization-profile">Organization</A>
        </DropdownMenuItem>
        <form action={logout} method="post">
          <CsrfField />
          <DropdownMenuItem closeOnSelect={false}>
            <button type="submit" class="w-full text-left">Sign out</button>
          </DropdownMenuItem>
        </form>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export function MobileNavigation(props: { menu: { href: string; label: string }[] }) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger as={Button} variant="ghost" class="p-2">
        <svg class="size-6 stroke-current" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" stroke-width="1.5" fill="none" stroke-linecap="round" stroke-linejoin="round">
          <path d="M0 0h24v24H0z" stroke="none" />
          <path d="M4 6h16M4 12h16M4 18h16" />
        </svg>
      </DropdownMenuTrigger>
      <DropdownMenuContent>
        <For each={props.menu}>
          {item => (
            <DropdownMenuItem>
              <A href={item.href}>{item.label}</A>
            </DropdownMenuItem>
          )}
        </For>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
