import type { ParentProps } from 'solid-js';
import { cn } from '@/utils/Helpers';

export function Background(props: ParentProps<{ class?: string }>) {
  return (
    <div class={cn('w-full bg-secondary', props.class)}>
      {props.children}
    </div>
  );
}
