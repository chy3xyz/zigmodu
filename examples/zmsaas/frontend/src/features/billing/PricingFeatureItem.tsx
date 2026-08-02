import type { ParentProps } from 'solid-js';

export function PricingFeatureItem(props: ParentProps) {
  return (
    <li class="flex items-center text-muted-foreground">
      <svg
        class="mr-2 size-6 stroke-current stroke-2 text-purple-400"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M0 0h24v24H0z" stroke="none" />
        <path d="M5 12l5 5L20 7" />
      </svg>
      {props.children}
    </li>
  );
}
