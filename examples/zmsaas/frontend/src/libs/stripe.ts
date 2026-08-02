import Stripe from 'stripe';
import { Env } from '@/libs/Env';

export {
  planForPriceId,
  priceIdForPlan,
  stripeCheckoutLocale,
} from '@/libs/stripePlans';

let stripeClient: Stripe | null = null;

export function getStripe() {
  if (!Env.STRIPE_SECRET_KEY) {
    throw new Error('STRIPE_SECRET_KEY is not configured');
  }
  if (!stripeClient) {
    stripeClient = new Stripe(Env.STRIPE_SECRET_KEY);
  }
  return stripeClient;
}
