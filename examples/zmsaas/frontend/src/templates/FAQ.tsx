import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion';
import { Section } from '@/features/landing/Section';
import { useTranslations } from '@/libs/I18nContext';

const ITEMS = [
  { q: 'q1', a: 'a1' },
  { q: 'q2', a: 'a2' },
  { q: 'q3', a: 'a3' },
  { q: 'q4', a: 'a4' },
  { q: 'q5', a: 'a5' },
  { q: 'q6', a: 'a6' },
] as const;

export function FAQ() {
  const t = useTranslations();
  return (
    <Section
      id="faq"
      subtitle={t('FAQ.section_subtitle') as string}
      title={t('FAQ.section_title') as string}
      description={t('FAQ.section_description') as string}
    >
      <Accordion multiple class="w-full">
        {ITEMS.map(item => (
          <AccordionItem value={item.q}>
            <AccordionTrigger>{t(`FAQ.${item.q}`)}</AccordionTrigger>
            <AccordionContent>{t(`FAQ.${item.a}`)}</AccordionContent>
          </AccordionItem>
        ))}
      </Accordion>
    </Section>
  );
}
