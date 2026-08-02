import { expect, test } from '@playwright/test';

test.describe('Sanity', () => {
  test.describe('Static pages', () => {
    test('should display the homepage', async ({ page }) => {
      await page.goto('/');
      await expect(page.getByRole('link', { name: 'SaaS SolidJS' }).first()).toBeVisible();
      await expect(page.locator('#features')).toBeVisible();
      await expect(page.locator('#pricing')).toBeVisible();
      await expect(page.locator('#faq')).toBeVisible();
    });
  });

  test('sign-up → org → dashboard', async ({ page }) => {
    const email = `e2e_${Date.now()}@example.com`;
    const password = 'password123';

    await page.goto('/sign-up');
    await expect(page.locator('input[name="csrf"]')).not.toHaveValue('', { timeout: 10_000 });
    await page.locator('input[name="name"]').fill('E2E User');
    await page.locator('input[name="email"]').fill(email);
    await page.locator('input[name="password"]').fill(password);
    await page.locator('form').locator('button[type="submit"]').click();

    await page.waitForURL(/\/(onboarding\/organization-selection|dashboard)/, { timeout: 20_000 });

    if (page.url().includes('/onboarding/organization-selection')) {
      await expect(page.locator('form input[name="name"]')).toBeVisible();
      await page.locator('form input[name="name"]').fill(`Org ${Date.now()}`);
      await page.locator('form').filter({ has: page.locator('input[name="name"]') }).locator('button[type="submit"]').click();
    }

    await page.waitForURL(/\/dashboard/, { timeout: 20_000 });
    await expect(page).toHaveURL(/\/dashboard/);
  });
});
