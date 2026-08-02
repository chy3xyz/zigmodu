import { A } from '@solidjs/router';
import type { JSX, ParentProps } from 'solid-js';
import { MenuToggle } from '@/components/MenuToggle';
import { useMenu } from '@/hooks/UseMenu';
import { cn } from '@/utils/Helpers';

export function CenteredMenu(props: ParentProps<{
  logo: JSX.Element;
  rightMenu: JSX.Element;
}>) {
  const { isMenuOpen, toggleMenu } = useMenu();
  const navClass = () =>
    cn('max-lg:w-full max-lg:bg-secondary max-lg:p-5', {
      'max-lg:hidden': !isMenuOpen(),
    });

  return (
    <div class="flex flex-wrap items-center justify-between">
      <A href="/">{props.logo}</A>
      <div class="lg:hidden">
        <MenuToggle onClick={toggleMenu} />
      </div>
      <nav class={cn('rounded-t-xl max-lg:mt-2', navClass())}>
        <ul class="flex gap-x-6 gap-y-1 text-lg font-medium max-lg:flex-col max-lg:[&_a]:inline-block max-lg:[&_a]:w-full [&_a:hover]:opacity-70">
          {props.children}
        </ul>
      </nav>
      <div class={cn('rounded-b-xl max-lg:border-t max-lg:border-border', navClass())}>
        <ul class="flex flex-row items-center gap-x-1.5 text-lg font-medium [&_a:hover]:opacity-70">
          {props.rightMenu}
        </ul>
      </div>
    </div>
  );
}
