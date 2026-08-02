import type { VariantProps } from 'class-variance-authority';
import type { JSX, ValidComponent } from 'solid-js';
import { splitProps } from 'solid-js';
import { Dynamic } from 'solid-js/web';
import { cn } from '@/utils/Helpers';
import { badgeVariants } from './badgeVariants';

type BadgeProps = JSX.HTMLAttributes<HTMLSpanElement>
  & VariantProps<typeof badgeVariants>
  & {
    as?: ValidComponent;
  };

export function Badge(props: BadgeProps) {
  const [local, rest] = splitProps(props, ['class', 'variant', 'as']);
  return (
    <Dynamic
      component={local.as ?? 'span'}
      data-slot="badge"
      class={cn(badgeVariants({ variant: local.variant }), local.class)}
      {...rest}
    />
  );
}
