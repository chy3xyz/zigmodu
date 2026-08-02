import { upsertSubscription } from '@/auth/db';

/** Used by Stripe webhook handler only — keep out of client-imported modules. */
export async function applyStripeSubscription(opts: {
  orgId: string;
  subscriptionId: string;
  priceId: string | null;
  status: string;
  currentPeriodEnd: number | null;
}) {
  await upsertSubscription({
    orgId: opts.orgId,
    stripeSubscriptionId: opts.subscriptionId,
    stripePriceId: opts.priceId,
    status: opts.status,
    currentPeriodEnd: opts.currentPeriodEnd
      ? new Date(opts.currentPeriodEnd * 1000)
      : null,
  });
}
