import { Env } from '@/libs/Env';
import { PLAN_NAME } from '@/utils/PricingPlans';

export function priceIdForPlan(plan: string) {
  if (plan === PLAN_NAME.PREMIUM) return Env.STRIPE_PRICE_PREMIUM;
  if (plan === PLAN_NAME.ENTERPRISE) return Env.STRIPE_PRICE_ENTERPRISE;
  return '';
}

export function planForPriceId(priceId: string | null | undefined) {
  if (!priceId) return PLAN_NAME.FREE;
  if (priceId === Env.STRIPE_PRICE_PREMIUM) return PLAN_NAME.PREMIUM;
  if (priceId === Env.STRIPE_PRICE_ENTERPRISE) return PLAN_NAME.ENTERPRISE;
  return PLAN_NAME.FREE;
}

export function stripeCheckoutLocale(locale: string): 'zh' | 'en' {
  return locale === 'zh' ? 'zh' : 'en';
}
