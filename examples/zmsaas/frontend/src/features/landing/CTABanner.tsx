import type { JSX } from 'solid-js';

export function CTABanner(props: {
  title: string;
  description: string;
  buttons: JSX.Element;
}) {
  return (
    <div class="rounded-xl bg-muted bg-linear-to-br from-indigo-400 via-purple-400 to-pink-400 px-6 py-10 text-center">
      <div class="text-3xl font-bold text-primary-foreground">{props.title}</div>
      <div class="mt-2 text-lg font-medium text-muted">{props.description}</div>
      <div class="mt-6">{props.buttons}</div>
    </div>
  );
}
