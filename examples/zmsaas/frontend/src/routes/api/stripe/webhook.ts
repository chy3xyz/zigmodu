import type { APIEvent } from '@solidjs/start/server';
import type Stripe from 'stripe';
import { claimWebhookEvent } from '@/auth/db';
import { applyStripeSubscription } from '@/libs/billingWebhook';
import { Env } from '@/libs/Env';
import { getStripe } from '@/libs/stripe';

async function syncSubscription(subscription: Stripe.Subscription) {
  const orgId = subscription.metadata.orgId;
  if (!orgId) return;
  const item = subscription.items.data[0];
  const priceId = item?.price.id ?? null;
  await applyStripeSubscription({
    orgId,
    subscriptionId: subscription.id,
    priceId,
    status: subscription.status,
    currentPeriodEnd: item?.current_period_end ?? null,
  });
}

export async function POST(event: APIEvent) {
  const stripe = getStripe();
  const signature = event.request.headers.get('stripe-signature');
  if (!signature || !Env.STRIPE_WEBHOOK_SECRET) {
    return new Response('Webhook not configured', { status: 400 });
  }

  const rawBody = await event.request.text();
  let stripeEvent: Stripe.Event;
  try {
    stripeEvent = stripe.webhooks.constructEvent(
      rawBody,
      signature,
      Env.STRIPE_WEBHOOK_SECRET,
    );
  }
  catch (error) {
    const message = error instanceof Error ? error.message : 'Invalid signature';
    return new Response(message, { status: 400 });
  }

  const claimed = await claimWebhookEvent(stripeEvent.id, stripeEvent.type);
  if (!claimed) {
    return new Response(JSON.stringify({ received: true, duplicate: true }), {
      headers: { 'content-type': 'application/json' },
    });
  }

  switch (stripeEvent.type) {
    case 'checkout.session.completed': {
      const session = stripeEvent.data.object as Stripe.Checkout.Session;
      if (session.subscription && typeof session.subscription === 'string') {
        const sub = await stripe.subscriptions.retrieve(session.subscription);
        if (!sub.metadata.orgId && session.metadata?.orgId) {
          await stripe.subscriptions.update(sub.id, {
            metadata: { ...sub.metadata, orgId: session.metadata.orgId },
          });
          sub.metadata.orgId = session.metadata.orgId;
        }
        await syncSubscription(sub);
      }
      break;
    }
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      await syncSubscription(stripeEvent.data.object as Stripe.Subscription);
      break;
    }
    default:
      break;
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { 'content-type': 'application/json' },
  });
}
