import { action, query, redirect } from '@solidjs/router';
import { findOrganization, getSubscription, updateOrganization } from '@/auth/db';
import { guardForm } from '@/libs/csrf';
import { Env } from '@/libs/Env';
import { requireActiveSubscription, requireOrgMember } from '@/libs/rbac';
import { getStripe, planForPriceId, priceIdForPlan, stripeCheckoutLocale } from '@/libs/stripe';
import { ORG_ROLE, SUBSCRIPTION_STATUS } from '@/types/Auth';

export const queryBilling = query(async () => {
  'use server';
  const member = await requireOrgMember();
  const sub = await getSubscription(member.activeOrgId);
  const org = await findOrganization(member.activeOrgId);
  return {
    plan: planForPriceId(sub?.stripePriceId),
    status: sub?.status ?? SUBSCRIPTION_STATUS.INACTIVE,
    currentPeriodEnd: sub?.currentPeriodEnd?.toISOString() ?? null,
    hasCustomer: Boolean(org?.stripeCustomerId),
    role: member.role,
    stripeConfigured: Boolean(Env.STRIPE_SECRET_KEY && Env.STRIPE_PRICE_PREMIUM),
  };
}, 'billing');

export const formStartCheckout = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  if (!member.emailVerified) {
    return new Error('Verify your email before upgrading');
  }
  const plan = String(formData.get('plan') ?? '');
  const priceId = priceIdForPlan(plan);
  if (!priceId) {
    if (!Env.STRIPE_SECRET_KEY) {
      return new Error('Stripe is not configured. Set STRIPE_SECRET_KEY and price IDs.');
    }
    return new Error('Unknown or unconfigured plan');
  }

  const stripe = getStripe();
  let org = await findOrganization(member.activeOrgId);
  if (!org) return new Error('Organization not found');

  if (!org.stripeCustomerId) {
    const customer = await stripe.customers.create({
      email: member.email,
      name: org.name,
      metadata: { orgId: org.id },
    });
    org = (await updateOrganization(org.id, { stripeCustomerId: customer.id }))!;
  }

  const session = await stripe.checkout.sessions.create({
    mode: 'subscription',
    customer: org.stripeCustomerId!,
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: `${Env.PUBLIC_APP_URL}/dashboard/billing?success=1`,
    cancel_url: `${Env.PUBLIC_APP_URL}/dashboard/billing?canceled=1`,
    locale: stripeCheckoutLocale(member.locale ?? 'en'),
    metadata: { orgId: org.id, plan },
    subscription_data: {
      metadata: { orgId: org.id, plan },
    },
  });

  if (!session.url) return new Error('Failed to create checkout session');
  return redirect(session.url);
});

export const formBillingPortal = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  const org = await findOrganization(member.activeOrgId);
  if (!org?.stripeCustomerId) {
    return new Error('No billing customer yet. Start a subscription first.');
  }
  const stripe = getStripe();
  const portal = await stripe.billingPortal.sessions.create({
    customer: org.stripeCustomerId,
    return_url: `${Env.PUBLIC_APP_URL}/dashboard/billing`,
  });
  return redirect(portal.url);
});

export const queryPremiumFeature = query(async () => {
  'use server';
  const member = await requireActiveSubscription();
  return {
    orgId: member.activeOrgId,
    status: member.subscription?.status ?? 'active',
  };
}, 'premium');
