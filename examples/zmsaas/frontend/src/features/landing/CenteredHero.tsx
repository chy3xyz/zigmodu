import type { JSX } from 'solid-js';

export function CenteredHero(props: {
  banner: JSX.Element;
  title: JSX.Element;
  description: string;
  buttons: JSX.Element;
}) {
  return (
    <>
      <div class="text-center">{props.banner}</div>
      <div class="mt-3 text-center text-5xl font-bold tracking-tight">{props.title}</div>
      <div class="mx-auto mt-5 max-w-3xl text-center text-xl text-muted-foreground">
        {props.description}
      </div>
      <div class="mt-8 flex justify-center gap-x-5 gap-y-3 max-sm:flex-col">
        {props.buttons}
      </div>
    </>
  );
}
