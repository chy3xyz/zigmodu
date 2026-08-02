import { createSignal } from 'solid-js';

export function useMenu(defaultOpen = false) {
  const [isMenuOpen, setIsMenuOpen] = createSignal(defaultOpen);
  const toggleMenu = () => setIsMenuOpen(prev => !prev);
  const closeMenu = () => setIsMenuOpen(false);
  const openMenu = () => setIsMenuOpen(true);
  return { isMenuOpen, openMenu, closeMenu, toggleMenu };
}
