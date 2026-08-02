import { expect, test } from '@playwright/test';

test.describe('I18n', () => {
  test('serves Chinese copy when locale cookie is zh', async ({ page, context }) => {
    await context.addCookies([
      {
        name: 'locale',
        value: 'zh',
        url: 'http://localhost:3008',
      },
    ]);
    await page.goto('/');
    await expect(page.getByRole('link', { name: '登录' })).toBeVisible();
    await expect(page.getByRole('link', { name: '免费开始' }).first()).toBeVisible();
    await expect(page.locator('html')).toHaveAttribute('lang', 'zh');
  });
});
