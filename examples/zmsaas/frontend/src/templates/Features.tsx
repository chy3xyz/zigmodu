import {
  Building2,
  CreditCard,
  Database,
  Languages,
  Mail,
  ShieldCheck,
} from 'lucide-solid';
import type { JSX } from 'solid-js';
import { For } from 'solid-js';
import { Background } from '@/components/Background';
import { FeatureCard } from '@/features/landing/FeatureCard';
import { Section } from '@/features/landing/Section';
import { useTranslations } from '@/libs/I18nContext';

type FeatureKey = 1 | 2 | 3 | 4 | 5 | 6;

const FEATURES: { key: FeatureKey; icon: () => JSX.Element }[] = [
  { key: 1, icon: () => <ShieldCheck /> },
  { key: 2, icon: () => <Building2 /> },
  { key: 3, icon: () => <CreditCard /> },
  { key: 4, icon: () => <Mail /> },
  { key: 5, icon: () => <Languages /> },
  { key: 6, icon: () => <Database /> },
];

export function Features() {
  const t = useTranslations();
  return (
    <Background>
      <Section
        id="features"
        subtitle={t('Features.section_subtitle') as string}
        title={t('Features.section_title') as string}
        description={t('Features.section_description') as string}
      >
        <div class="grid grid-cols-1 gap-x-3 gap-y-8 md:grid-cols-3">
          <For each={FEATURES}>
            {(item) => {
              const titleKey = `Features.feature${item.key}_title` as const;
              const bodyKey = `Features.feature${item.key}_description` as const;
              return (
                <FeatureCard icon={item.icon()} title={t(titleKey) as string}>
                  {t(bodyKey) as string}
                </FeatureCard>
              );
            }}
          </For>
        </div>
      </Section>
    </Background>
  );
}
