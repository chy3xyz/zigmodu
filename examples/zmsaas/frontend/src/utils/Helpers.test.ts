import { describe, expect, it } from 'vitest';
import { cn, getI18nPath } from '@/utils/Helpers';

describe('cn', () => {
  it('merges class names', () => {
    expect(cn('px-2', 'px-4')).toBe('px-4');
  });
});

describe('getI18nPath', () => {
  it('omits default locale prefix', () => {
    expect(getI18nPath('/dashboard', 'en')).toBe('/dashboard');
  });

  it('prefixes non-default locale', () => {
    expect(getI18nPath('/dashboard', 'zh')).toBe('/zh/dashboard');
  });
});
