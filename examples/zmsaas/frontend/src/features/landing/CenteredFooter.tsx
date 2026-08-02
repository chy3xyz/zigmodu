import type { JSX, ParentProps } from 'solid-js';
import { AppConfig } from '@/utils/AppConfig';

export function CenteredFooter(props: ParentProps<{
  logo: JSX.Element;
  name: string;
  iconList: JSX.Element;
  legalLinks: JSX.Element;
}>) {
  return (
    <div class="flex flex-col items-center text-center">
      {props.logo}
      <ul class="mt-4 flex gap-x-8 text-lg max-sm:flex-col [&_a:hover]:opacity-70">
        {props.children}
      </ul>
      <ul class="mt-4 flex flex-row gap-x-5 text-primary [&_svg]:size-5 [&_svg]:fill-current [&_svg:hover]:opacity-60">
        {props.iconList}
      </ul>
      <div class="mt-6 flex w-full items-center justify-between gap-y-2 border-t pt-3 text-sm text-muted-foreground max-md:flex-col">
        <div>
          {`© ${new Date().getFullYear()} ${props.name || AppConfig.name}`}
        </div>
        <ul class="flex gap-x-4 font-medium [&_a:hover]:opacity-60">{props.legalLinks}</ul>
      </div>
    </div>
  );
}
