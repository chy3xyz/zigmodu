import { createAsync, useSubmission } from '@solidjs/router';
import { Show } from 'solid-js';
import { formBillingPortal, formStartCheckout, queryBilling } from '@/libs/billing';
import { CsrfField } from '@/components/CsrfField';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { TitleBar } from '@/features/dashboard/shared';
import { useTranslations } from '@/libs/I18nContext';
import { ORG_ROLE } from '@/types/Auth';
import { PLAN_NAME } from '@/utils/PricingPlans';

export default function BillingPage() {
  const t = useTranslations();
  const billing = createAsync(() => queryBilling());
  const checkoutPremium = useSubmission(formStartCheckout);
  const portal = useSubmission(formBillingPortal);
  const data = () => billing();

  return (
    <>
      <TitleBar title={t('BillingPage.title_bar')} description={t('BillingPage.title_bar_description')} />
      <div class="max-w-xl space-y-6 rounded-xl border bg-card p-6">
        <Show when={data()}>
          <dl class="space-y-3 text-sm">
            <div>
              <dt class="text-muted-foreground">{t('BillingPage.current_plan')}</dt>
              <dd class="text-lg font-semibold capitalize">{data()?.plan}</dd>
            </div>
            <div>
              <dt class="text-muted-foreground">{t('BillingPage.status')}</dt>
              <dd class="font-medium">{data()?.status}</dd>
            </div>
            <Show when={data()?.currentPeriodEnd}>
              <div>
                <dt class="text-muted-foreground">{t('BillingPage.period_end')}</dt>
                <dd>{new Date(data()!.currentPeriodEnd!).toLocaleString()}</dd>
              </div>
            </Show>
          </dl>
        </Show>

        <Show when={!data()?.stripeConfigured}>
          <p class="text-sm text-amber-800">{t('BillingPage.not_configured')}</p>
        </Show>

        <Show when={data()?.role === ORG_ROLE.ADMIN && data()?.stripeConfigured}>
          <div class="flex flex-wrap gap-3">
            <form action={formStartCheckout} method="post">
              <CsrfField />
              <input type="hidden" name="plan" value={PLAN_NAME.PREMIUM} />
              <button type="submit" class={buttonVariants()} disabled={checkoutPremium.pending}>
                {t('BillingPage.upgrade_premium')}
              </button>
            </form>
            <form action={formStartCheckout} method="post">
              <CsrfField />
              <input type="hidden" name="plan" value={PLAN_NAME.ENTERPRISE} />
              <button type="submit" class={buttonVariants({ variant: 'outline' })} disabled={checkoutPremium.pending}>
                {t('BillingPage.upgrade_enterprise')}
              </button>
            </form>
            <Show when={data()?.hasCustomer}>
              <form action={formBillingPortal} method="post">
                <CsrfField />
                <button type="submit" class={buttonVariants({ variant: 'secondary' })} disabled={portal.pending}>
                  {t('BillingPage.manage')}
                </button>
              </form>
            </Show>
          </div>
          <Show when={checkoutPremium.result instanceof Error}>
            <p class="text-sm text-destructive">{(checkoutPremium.result as Error).message}</p>
          </Show>
          <Show when={portal.result instanceof Error}>
            <p class="text-sm text-destructive">{(portal.result as Error).message}</p>
          </Show>
        </Show>
      </div>
    </>
  );
}
