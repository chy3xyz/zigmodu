import type { JSX, ParentProps } from 'solid-js';
import { Show } from 'solid-js';

export function TitleBar(props: { title: JSX.Element; description?: JSX.Element }) {
  return (
    <div class="mb-8">
      <div class="text-2xl font-semibold">{props.title}</div>
      <Show when={props.description}>
        <div class="text-sm font-medium text-muted-foreground">{props.description}</div>
      </Show>
    </div>
  );
}

export function PageMessage(props: {
  icon: JSX.Element;
  title: JSX.Element;
  description: JSX.Element;
  button: JSX.Element;
}) {
  return (
    <div class="flex h-150 flex-col items-center justify-center rounded-md bg-card p-5">
      <div class="size-16 rounded-full bg-muted p-3 [&_svg]:stroke-muted-foreground [&_svg]:stroke-2">
        {props.icon}
      </div>
      <div class="mt-3 text-center">
        <div class="text-xl font-semibold">{props.title}</div>
        <div class="mt-1 text-sm font-medium text-muted-foreground">{props.description}</div>
        <div class="mt-5">{props.button}</div>
      </div>
    </div>
  );
}

export function SlashIcon() {
  return (
    <svg
      class="size-8 stroke-muted-foreground max-sm:hidden"
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path stroke="none" d="M0 0h24v24H0z" />
      <path d="M17 5 7 19" />
    </svg>
  );
}

export function CenteredContainer(props: ParentProps) {
  return (
    <div class="flex min-h-svh flex-col items-center justify-center gap-6 p-6 md:p-10">
      {props.children}
    </div>
  );
}
