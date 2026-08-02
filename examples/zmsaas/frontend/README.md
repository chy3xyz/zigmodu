# SaaS SolidJS

Production-oriented SolidStart SaaS starter: Postgres/Drizzle auth, org RBAC, Stripe subscriptions, Resend email, and English/Chinese i18n.

**Repository:** [chy3xyz/saas-solidjs](https://github.com/chy3xyz/saas-solidjs)

## Stack

- **SolidStart** (SSR) + `@solidjs/router`
- **Auth**: cookie session + PBKDF2; email verify / password reset via Resend
- **Data**: Drizzle ORM + Postgres (local **PGLite** TCP server or Neon/managed Postgres)
- **Billing**: Stripe Checkout, Customer Portal, webhooks
- **i18n**: `@solid-primitives/i18n` — `en` / `zh`
- **UI**: Kobalte + Tailwind CSS v4
- **Test**: Vitest + Playwright; GitHub Actions CI

## Quick start

```bash
cp .env.example .env
npm install

# Terminal A — local Postgres-compatible DB (PGLite, no Docker)
npm run db-server

# Terminal B
npm run db:migrate
npm run dev      # http://localhost:3000
```

If you already run Postgres/Neon, set `DATABASE_URL` and skip `db-server`.

### Auth smoke path

1. `/sign-up` → create account (verification email mocked to console when `EMAIL_MOCK=true`)
2. `/onboarding/organization-selection` → create org
3. `/dashboard` → members, settings, billing

### Stripe

1. Create Products/Prices in Stripe Dashboard; set `STRIPE_PRICE_PREMIUM` / `STRIPE_PRICE_ENTERPRISE`
2. Forward webhooks: `stripe listen --forward-to localhost:3000/api/stripe/webhook`
3. Put the webhook signing secret in `STRIPE_WEBHOOK_SECRET`

### Resend

Set `RESEND_API_KEY` and `EMAIL_FROM`. Keep `EMAIL_MOCK=true` in local dev to print emails to the server log.

## Environment variables

| Variable | Required | Notes |
|---|---|---|
| `SESSION_SECRET` | yes (≥32 chars) | Production forbids default/`change-me` values |
| `DATABASE_URL` | yes | Postgres connection string |
| `PUBLIC_APP_URL` | yes | App origin for email/Stripe redirects |
| `RESEND_API_KEY` | prod email | Optional when `EMAIL_MOCK=true` |
| `EMAIL_FROM` | optional | Default Resend onboarding sender |
| `EMAIL_MOCK` | optional | `true`/`false` (default true off-prod) |
| `STRIPE_SECRET_KEY` | billing | |
| `STRIPE_WEBHOOK_SECRET` | webhooks | |
| `PUBLIC_STRIPE_PUBLISHABLE_KEY` | optional | Client publishable key |
| `STRIPE_PRICE_PREMIUM` / `ENTERPRISE` | checkout | Price IDs |

## Scripts

```bash
npm run db-server     # PGLite wire protocol on :5432
npm run db:migrate    # Apply Drizzle migrations
npm run dev           # Vite / SolidStart
npm run build && npm start
npm run lint
npm run check:types
npm test
npm run test:e2e
```

## Locales

Default locale is English (`en`). Switch to 中文 via the language menu (`zh` cookie / `/zh/...` paths).
