import { defineConfig, devices } from '@playwright/test';

const PORT = process.env.PORT ?? '3008';
const baseURL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: './tests',
  testMatch: '*.@(integ|e2e).?(c|m)[jt]s?(x)',
  timeout: 30 * 1000,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? 'github' : 'list',
  expect: {
    timeout: 15 * 1000,
  },
  webServer: {
    command: process.env.CI ? 'npm run start' : 'npm run dev',
    url: baseURL,
    timeout: 120 * 1000,
    reuseExistingServer: !process.env.CI,
    env: {
      PUBLIC_APP_URL: baseURL,
      PORT,
      SESSION_SECRET: 'ci-e2e-session-secret-32chars-min!!',
      DATABASE_URL: process.env.DATABASE_URL ?? 'postgres://postgres:postgres@127.0.0.1:5432/saas',
      EMAIL_MOCK: 'true',
      NODE_ENV: 'production',
    },
  },
  use: {
    baseURL,
    trace: process.env.CI ? 'on' : 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
