import { Accordion as KAccordion } from '@kobalte/core/accordion';
import { ChevronRight } from 'lucide-solid';
import type { ComponentProps, ParentProps } from 'solid-js';
import { splitProps } from 'solid-js';
import { cn } from '@/utils/Helpers';

export function Accordion(props: ComponentProps<typeof KAccordion> & { class?: string }) {
  const [local, rest] = splitProps(props, ['class']);
  return <KAccordion data-slot="accordion" class={cn('w-full', local.class)} {...rest} />;
}

export function AccordionItem(props: ComponentProps<typeof KAccordion.Item> & { class?: string }) {
  const [local, rest] = splitProps(props, ['class']);
  return (
    <KAccordion.Item
      data-slot="accordion-item"
      class={cn('border-b last:border-b-0', local.class)}
      {...rest}
    />
  );
}

export function AccordionTrigger(props: ParentProps<{ class?: string }>) {
  const [local, rest] = splitProps(props, ['class', 'children']);
  return (
    <KAccordion.Header class="flex">
      <KAccordion.Trigger
        data-slot="accordion-trigger"
        class={cn(
          `
            flex flex-1 items-start justify-between gap-4 rounded-md py-5
            text-left text-lg font-medium transition-all outline-none
            hover:cursor-pointer
            focus-visible:border-ring focus-visible:ring-[3px]
            focus-visible:ring-ring/50
            disabled:pointer-events-none disabled:opacity-50
            ui-expanded:[&>svg]:rotate-90
          `,
          local.class,
        )}
        {...rest}
      >
        {local.children}
        <ChevronRight class="pointer-events-none size-4 shrink-0 translate-y-0.5 text-muted-foreground transition-transform duration-200" />
      </KAccordion.Trigger>
    </KAccordion.Header>
  );
}

export function AccordionContent(props: ParentProps<{ class?: string }>) {
  const [local, rest] = splitProps(props, ['class', 'children']);
  return (
    <KAccordion.Content
      data-slot="accordion-content"
      class="overflow-hidden text-muted-foreground data-[closed]:animate-accordion-up data-[expanded]:animate-accordion-down"
      {...rest}
    >
      <div class={cn('pt-0 pb-4', local.class)}>{local.children}</div>
    </KAccordion.Content>
  );
}
