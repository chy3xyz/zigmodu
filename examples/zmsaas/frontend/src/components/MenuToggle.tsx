import { Button } from '@/components/ui/button';

export function MenuToggle(props: { onClick?: () => void }) {
  return (
    <Button variant="ghost" onClick={props.onClick}>
      <svg
        class="size-6 stroke-current"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        stroke-width="1.5"
        fill="none"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M0 0h24v24H0z" stroke="none" />
        <path d="M4 6h16M4 12h16M4 18h16" />
      </svg>
    </Button>
  );
}
