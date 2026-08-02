import { ArrowRight, Github } from 'lucide-solid';
import type { JSX } from 'solid-js';
import { badgeVariants } from '@/components/ui/badgeVariants';
import { buttonVariants } from '@/components/ui/buttonVariants';
import { CenteredHero } from '@/features/landing/CenteredHero';
import { Section } from '@/features/landing/Section';
import { useTranslations } from '@/libs/I18nContext';
import { AppConfig } from '@/utils/AppConfig';

function ImportantTitle(props: { text: string }): JSX.Element {
  const match = props.text.match(/^(.*?)<important>(.*?)<\/important>(.*)$/s);
  if (!match) return <>{props.text}</>;
  return (
    <>
      {match[1]}
      <span class="bg-linear-to-r from-sky-600 via-teal-600 to-emerald-600 bg-clip-text text-transparent">
        {match[2]}
      </span>
      {match[3]}
    </>
  );
}

export function Hero() {
  const t = useTranslations();
  return (
    <Section class="py-28 sm:py-36">
      <CenteredHero
        banner={(
          <a
            class={badgeVariants()}
            href={AppConfig.githubUrl}
            target="_blank"
            rel="noopener noreferrer"
          >
            <Github class="size-3" />
            {' '}
            {t('Hero.follow_github')}
          </a>
        )}
        title={<ImportantTitle text={t('Hero.title') as string} />}
        description={t('Hero.description') as string}
        buttons={(
          <>
            <a class={buttonVariants({ size: 'lg' })} href="/sign-up">
              {t('Hero.primary_button')}
              <ArrowRight class="ml-1 size-5" />
            </a>
            <a
              class={buttonVariants({ variant: 'outline', size: 'lg' })}
              href={AppConfig.githubUrl}
              target="_blank"
              rel="noopener noreferrer"
            >
              <Github class="mr-2 size-5" />
              {t('Hero.secondary_button')}
            </a>
          </>
        )}
      />
    </Section>
  );
}
