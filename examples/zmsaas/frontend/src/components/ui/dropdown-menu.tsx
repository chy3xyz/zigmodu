import { DropdownMenu as KDropdownMenu } from '@kobalte/core/dropdown-menu';
import { Check, Circle } from 'lucide-solid';
import type { ComponentProps, ParentProps } from 'solid-js';
import { splitProps } from 'solid-js';
import { cn } from '@/utils/Helpers';

export function DropdownMenu(props: ComponentProps<typeof KDropdownMenu>) {
  return <KDropdownMenu data-slot="dropdown-menu" {...props} />;
}

export function DropdownMenuTrigger(props: ComponentProps<typeof KDropdownMenu.Trigger>) {
  return <KDropdownMenu.Trigger data-slot="dropdown-menu-trigger" {...props} />;
}

export function DropdownMenuContent(props: ComponentProps<typeof KDropdownMenu.Content> & { class?: string }) {
  const [local, rest] = splitProps(props, ['class']);
  return (
    <KDropdownMenu.Portal>
      <KDropdownMenu.Content
        data-slot="dropdown-menu-content"
        class={cn(
          `
            z-50 min-w-32 overflow-hidden rounded-md border bg-popover p-1
            text-popover-foreground shadow-md outline-none
          `,
          local.class,
        )}
        {...rest}
      />
    </KDropdownMenu.Portal>
  );
}

export function DropdownMenuItem(props: ComponentProps<typeof KDropdownMenu.Item> & { class?: string }) {
  const [local, rest] = splitProps(props, ['class']);
  return (
    <KDropdownMenu.Item
      data-slot="dropdown-menu-item"
      class={cn(
        `
          relative flex cursor-default items-center gap-2 rounded-sm px-2 py-1.5
          text-sm outline-hidden select-none
          focus:bg-accent focus:text-accent-foreground
          data-[disabled]:pointer-events-none data-[disabled]:opacity-50
        `,
        local.class,
      )}
      {...rest}
    />
  );
}

export function DropdownMenuRadioGroup(props: ComponentProps<typeof KDropdownMenu.RadioGroup>) {
  return <KDropdownMenu.RadioGroup data-slot="dropdown-menu-radio-group" {...props} />;
}

export function DropdownMenuRadioItem(props: ParentProps<ComponentProps<typeof KDropdownMenu.RadioItem> & { class?: string }>) {
  const [local, rest] = splitProps(props, ['class', 'children']);
  return (
    <KDropdownMenu.RadioItem
      data-slot="dropdown-menu-radio-item"
      class={cn(
        `
          relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-2
          pl-8 text-sm outline-hidden select-none
          focus:bg-accent focus:text-accent-foreground
          data-[disabled]:pointer-events-none data-[disabled]:opacity-50
        `,
        local.class,
      )}
      {...rest}
    >
      <span class="pointer-events-none absolute left-2 flex size-3.5 items-center justify-center">
        <KDropdownMenu.ItemIndicator>
          <Circle class="size-2 fill-current" />
        </KDropdownMenu.ItemIndicator>
      </span>
      {local.children}
    </KDropdownMenu.RadioItem>
  );
}

export function DropdownMenuCheckboxItem(props: ParentProps<ComponentProps<typeof KDropdownMenu.CheckboxItem> & { class?: string }>) {
  const [local, rest] = splitProps(props, ['class', 'children']);
  return (
    <KDropdownMenu.CheckboxItem
      class={cn(
        `
          relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-2
          pl-8 text-sm outline-hidden select-none
          focus:bg-accent focus:text-accent-foreground
        `,
        local.class,
      )}
      {...rest}
    >
      <span class="pointer-events-none absolute left-2 flex size-3.5 items-center justify-center">
        <KDropdownMenu.ItemIndicator>
          <Check class="size-4" />
        </KDropdownMenu.ItemIndicator>
      </span>
      {local.children}
    </KDropdownMenu.CheckboxItem>
  );
}
