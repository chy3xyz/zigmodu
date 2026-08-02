import type { ParentProps } from 'solid-js';

export function LogoCloud(props: ParentProps<{ text: string }>) {
  return (
    <>
      <div class="text-center text-sm font-semibold text-muted-foreground">{props.text}</div>
      <div class="mt-5 grid grid-cols-2 place-items-center gap-x-3 gap-y-6 md:grid-cols-6 md:gap-x-5 [&_a]:opacity-60 [&_a:hover]:opacity-100">
        {props.children}
      </div>
    </>
  );
}
