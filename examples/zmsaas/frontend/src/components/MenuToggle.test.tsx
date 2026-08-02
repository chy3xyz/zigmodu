import { describe, expect, it } from 'vitest';
import { render } from '@solidjs/testing-library';
import { MenuToggle } from '@/components/MenuToggle';

describe('MenuToggle', () => {
  it('renders a button', () => {
    const { container } = render(() => <MenuToggle />);
    expect(container.querySelector('button')).toBeTruthy();
  });
});
