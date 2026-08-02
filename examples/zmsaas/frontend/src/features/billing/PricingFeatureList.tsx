import type { PricingPlan } from '@/types/Subscription';
import { useTranslations } from '@/libs/I18nContext';
import { PricingFeatureItem } from './PricingFeatureItem';

export function PricingFeatureList(props: Pick<PricingPlan, 'limits'>) {
  const t = useTranslations();
  return (
    <>
      <PricingFeatureItem>
        {t('PricingFeatures.feature_team_member', { number: props.limits.teamMember })}
      </PricingFeatureItem>
      <PricingFeatureItem>
        {t('PricingFeatures.feature_website', { number: props.limits.website })}
      </PricingFeatureItem>
      <PricingFeatureItem>
        {t('PricingFeatures.feature_storage', { number: props.limits.storage })}
      </PricingFeatureItem>
      <PricingFeatureItem>
        {t('PricingFeatures.feature_transfer', { number: props.limits.transfer })}
      </PricingFeatureItem>
      <PricingFeatureItem>{t('PricingFeatures.feature_email_support')}</PricingFeatureItem>
    </>
  );
}
