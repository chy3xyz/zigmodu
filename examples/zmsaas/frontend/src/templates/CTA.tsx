import { ArrowRight } from 'lucide-solid';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CTABanner } from '@/features/landing/CTABanner';
import { Section } from '@/features/landing/Section';
import { useTranslations } from '@/libs/I18nContext';

export function CTA() {
  const t = useTranslations();
  return (
    <Section>
      <CTABanner
        title={t('CTA.title') as string}
        description={t('CTA.description') as string}
        buttons={(
          <a
            class={buttonVariants({ variant: 'secondary', size: 'lg', class: 'whitespace-pre-line' })}
            href="/sign-up"
          >
            {t('CTA.button_text')}
            <ArrowRight class="ml-1 size-5" />
          </a>
        )}
      />
    </Section>
  );
}
