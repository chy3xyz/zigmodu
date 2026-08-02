import { A, createAsync } from '@solidjs/router';
import { For, Show } from 'solid-js';
import { querySession } from '@/auth';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { PricingCard } from '@/features/billing/PricingCard';
import { Section } from '@/features/landing/Section';
import { formStartCheckout } from '@/libs/billing';
import { useTranslations } from '@/libs/I18nContext';
import { AllPlans, PLAN_NAME } from '@/utils/PricingPlans';

export function Pricing() {
  const t = useTranslations();
  const session = createAsync(() => querySession('/'));

  return (
    <Section
      id="pricing"
      subtitle={t('Pricing.section_subtitle') as string}
      title={t('Pricing.section_title') as string}
      description={t('Pricing.section_description') as string}
    >
      <div class="grid grid-cols-1 gap-x-6 gap-y-8 @xl:grid-cols-2 @4xl:grid-cols-3">
        <For each={AllPlans}>
          {(plan) => {
            const isFree = plan.name === PLAN_NAME.FREE;
            return (
              <PricingCard
                plan={plan}
                button={(
                  <Show
                    when={session()?.activeOrgId && !isFree}
                    fallback={(
                      <A
                        class={buttonVariants({ size: 'sm', class: 'w-full' })}
                        href={session()?.id ? '/dashboard' : '/sign-up'}
                      >
                        {t('Pricing.button_text')}
                      </A>
                    )}
                  >
                    <form action={formStartCheckout} method="post">
                      <CsrfField />
                      <input type="hidden" name="plan" value={plan.name} />
                      <button type="submit" class={buttonVariants({ size: 'sm', class: 'w-full' })}>
                        {t('Pricing.upgrade_text')}
                      </button>
                    </form>
                  </Show>
                )}
              />
            );
          }}
        </For>
      </div>
    </Section>
  );
}
