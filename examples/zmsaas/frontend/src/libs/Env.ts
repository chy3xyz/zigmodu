import { z } from 'zod';

const isProd = process.env.NODE_ENV === 'production';

const serverSchema = z.object({
  SESSION_SECRET: isProd
    ? z.string().min(32)
    : z.string().min(32).default('dev-session-secret-change-me-please-32chars'),
  DATABASE_URL: z.string().min(1).default('postgres://postgres:postgres@127.0.0.1:5432/saas'),
  RESEND_API_KEY: z.string().optional().default(''),
  EMAIL_FROM: z.string().default('SaaS SolidJS <onboarding@resend.dev>'),
  STRIPE_SECRET_KEY: z.string().optional().default(''),
  STRIPE_WEBHOOK_SECRET: z.string().optional().default(''),
  STRIPE_PRICE_PREMIUM: z.string().optional().default(''),
  STRIPE_PRICE_ENTERPRISE: z.string().optional().default(''),
  EMAIL_MOCK: z
    .enum(['true', 'false'])
    .optional()
    .default(isProd ? 'false' : 'true')
    .transform(v => v === 'true'),
});

const clientSchema = z.object({
  PUBLIC_APP_URL: z.string().default('http://localhost:3000'),
  PUBLIC_STRIPE_PUBLISHABLE_KEY: z.string().optional().default(''),
});

function readEnv() {
  // Never run production secret checks in the browser bundle.
  if (typeof window === 'undefined' && isProd) {
    const secret = process.env.SESSION_SECRET;
    if (!secret || secret.includes('change-me')) {
      throw new Error('SESSION_SECRET must be set to a strong value in production');
    }
  }

  const server = serverSchema.parse({
    SESSION_SECRET: process.env.SESSION_SECRET,
    DATABASE_URL: process.env.DATABASE_URL,
    RESEND_API_KEY: process.env.RESEND_API_KEY,
    EMAIL_FROM: process.env.EMAIL_FROM,
    STRIPE_SECRET_KEY: process.env.STRIPE_SECRET_KEY,
    STRIPE_WEBHOOK_SECRET: process.env.STRIPE_WEBHOOK_SECRET,
    STRIPE_PRICE_PREMIUM: process.env.STRIPE_PRICE_PREMIUM,
    STRIPE_PRICE_ENTERPRISE: process.env.STRIPE_PRICE_ENTERPRISE,
    EMAIL_MOCK: process.env.EMAIL_MOCK,
  });

  const client = clientSchema.parse({
    PUBLIC_APP_URL: process.env.PUBLIC_APP_URL ?? process.env.VITE_PUBLIC_APP_URL,
    PUBLIC_STRIPE_PUBLISHABLE_KEY: process.env.PUBLIC_STRIPE_PUBLISHABLE_KEY,
  });

  return {
    ...server,
    ...client,
    NODE_ENV: process.env.NODE_ENV ?? 'development',
  };
}

export const Env = readEnv();
