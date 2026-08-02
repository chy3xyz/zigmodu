import { Show } from 'solid-js';
import { AppConfig } from '@/utils/AppConfig';

export function Logo(props: { isTextHidden?: boolean }) {
  return (
    <div class="flex items-center text-xl font-semibold">
      <svg
        class="mr-1 size-8 stroke-current stroke-2"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M0 0h24v24H0z" stroke="none" />
        <rect x="3" y="12" width="6" height="8" rx="1" />
        <rect x="9" y="8" width="6" height="12" rx="1" />
        <rect x="15" y="4" width="6" height="16" rx="1" />
        <path d="M4 20h14" />
      </svg>
      <Show when={!props.isTextHidden}>{AppConfig.name}</Show>
    </div>
  );
}
