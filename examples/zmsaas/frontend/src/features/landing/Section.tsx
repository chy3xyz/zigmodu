import type { ParentProps } from 'solid-js';
import { Show } from 'solid-js';
import { cn } from '@/utils/Helpers';

export function Section(props: ParentProps<{
  id?: string;
  title?: string;
  subtitle?: string;
  description?: string;
  class?: string;
}>) {
  return (
    <div id={props.id} class={cn('@container scroll-mt-24 px-3 py-16', props.class)}>
      <Show when={props.title || props.subtitle || props.description}>
        <div class="mx-auto mb-12 max-w-3xl text-center">
          <Show when={props.subtitle}>
            <div class="bg-linear-to-r from-sky-600 via-teal-600 to-emerald-600 bg-clip-text text-sm font-bold text-transparent">
              {props.subtitle}
            </div>
          </Show>
          <Show when={props.title}>
            <div class="mt-1 text-3xl font-bold">{props.title}</div>
          </Show>
          <Show when={props.description}>
            <div class="mt-2 text-lg text-muted-foreground">{props.description}</div>
          </Show>
        </div>
      </Show>
      <div class="mx-auto max-w-5xl">{props.children}</div>
    </div>
  );
}
