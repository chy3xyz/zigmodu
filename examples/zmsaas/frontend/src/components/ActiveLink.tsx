import { A, useLocation } from '@solidjs/router';
import type { ParentProps } from 'solid-js';
import { cn } from '@/utils/Helpers';

export function ActiveLink(props: ParentProps<{ href: string }>) {
  const location = useLocation();
  return (
    <A
      href={props.href}
      class={cn(
        'px-3 py-2',
        location.pathname.endsWith(props.href) && 'rounded-md bg-primary text-primary-foreground',
      )}
    >
      {props.children}
    </A>
  );
}
