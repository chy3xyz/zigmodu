import type { JSX } from 'solid-js';
import type { PricingPlan } from '@/types/Subscription';
import { useTranslations } from '@/libs/I18nContext';
import { PricingFeatureList } from './PricingFeatureList';

export function PricingCard(props: { plan: PricingPlan; button: JSX.Element }) {
  const t = useTranslations();
  return (
    <div class="rounded-xl border border-border px-6 py-8 text-center">
      <div class="text-lg font-semibold">
        {t(`PricingPlans.${props.plan.name}_plan_name`)}
      </div>
      <div class="mt-3 flex items-center justify-center">
        <div class="text-5xl font-bold">
          {t('PricingCard.plan_price', { price: props.plan.price })}
        </div>
        <div class="ml-1 text-muted-foreground">{t('PricingCard.plan_interval_month')}</div>
      </div>
      <div class="mt-2 mb-5 text-sm text-muted-foreground">
        {t(`PricingCard.${props.plan.name}_plan_description`)}
      </div>
      {props.button}
      <ul class="mt-8 space-y-3">
        <PricingFeatureList limits={props.plan.limits} />
      </ul>
    </div>
  );
}
