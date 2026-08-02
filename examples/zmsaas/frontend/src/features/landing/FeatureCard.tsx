import type { JSX, ParentProps } from 'solid-js';

export function FeatureCard(props: ParentProps<{ icon: JSX.Element; title: string }>) {
  return (
    <div class="rounded-xl border border-border bg-background p-5">
      <div class="size-12 rounded-lg bg-linear-to-br from-sky-500 via-teal-500 to-emerald-500 p-2 [&_svg]:stroke-white [&_svg]:stroke-2">
        {props.icon}
      </div>
      <div class="mt-2 text-lg font-bold">{props.title}</div>
      <div class="my-3 w-8 border-t border-teal-500" />
      <div class="mt-2 text-muted-foreground">{props.children}</div>
    </div>
  );
}
