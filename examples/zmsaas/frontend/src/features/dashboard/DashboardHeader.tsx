import { A } from '@solidjs/router';
import { For } from 'solid-js';
import { ActiveLink } from '@/components/ActiveLink';
import { LocaleSwitcher } from '@/components/LocaleSwitcher';
import { Separator } from '@/components/ui/separator';
import { Logo } from '@/templates/Logo';
import { MobileNavigation, OrganizationMenu, UserMenu } from './OrganizationMenu';
import { SlashIcon } from './shared';

export function DashboardHeader(props: {
  menu: { href: string; label: string }[];
}) {
  return (
    <>
      <div class="flex items-center">
        <A href="/dashboard" class="max-sm:hidden">
          <Logo />
        </A>
        <SlashIcon />
        <OrganizationMenu />
        <nav class="ml-3 max-lg:hidden">
          <ul class="flex flex-row items-center gap-x-3 text-lg font-medium [&_a]:opacity-75 [&_a:hover]:opacity-100">
            <For each={props.menu}>
              {item => (
                <li>
                  <ActiveLink href={item.href}>{item.label}</ActiveLink>
                </li>
              )}
            </For>
          </ul>
        </nav>
      </div>
      <div>
        <ul class="flex items-center gap-x-1.5">
          <li class="lg:hidden">
            <MobileNavigation menu={props.menu} />
          </li>
          <li>
            <LocaleSwitcher />
          </li>
          <li>
            <Separator orientation="vertical" class="h-4" />
          </li>
          <li>
            <UserMenu />
          </li>
        </ul>
      </div>
    </>
  );
}
