import type { VariantProps } from 'class-variance-authority';
import type { JSX, ValidComponent } from 'solid-js';
import { splitProps } from 'solid-js';
import { Dynamic } from 'solid-js/web';
import { cn } from '@/utils/Helpers';
import { buttonVariants } from './buttonVariants';

type ButtonProps = JSX.ButtonHTMLAttributes<HTMLButtonElement>
  & VariantProps<typeof buttonVariants>
  & {
    as?: ValidComponent;
  };

export function Button(props: ButtonProps) {
  const [local, rest] = splitProps(props, ['class', 'variant', 'size', 'as']);
  return (
    <Dynamic
      component={local.as ?? 'button'}
      data-slot="button"
      class={cn(buttonVariants({ variant: local.variant, size: local.size }), local.class)}
      {...rest}
    />
  );
}
