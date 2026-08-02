import { Separator as KSeparator } from '@kobalte/core/separator';
import type { ComponentProps } from 'solid-js';
import { splitProps } from 'solid-js';
import { cn } from '@/utils/Helpers';

export function Separator(props: ComponentProps<typeof KSeparator> & { class?: string }) {
  const [local, rest] = splitProps(props, ['class', 'orientation']);
  return (
    <KSeparator
      data-slot="separator"
      orientation={local.orientation ?? 'horizontal'}
      class={cn(
        `
          shrink-0 bg-border
          data-[orientation=horizontal]:h-px data-[orientation=horizontal]:w-full
          data-[orientation=vertical]:h-full data-[orientation=vertical]:w-px
        `,
        local.class,
      )}
      {...rest}
    />
  );
}
