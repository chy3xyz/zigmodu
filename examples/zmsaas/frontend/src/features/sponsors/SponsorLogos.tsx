import { useTranslations } from '@/libs/I18nContext';
import { LogoCloud } from '@/features/landing/LogoCloud';

export function SponsorLogos() {
  const t = useTranslations();
  return (
    <LogoCloud text={t('SponsorLogos.sponsored_by')}>
      <a href="https://www.solidjs.com" target="_blank" rel="noopener">
        <span class="text-sm font-semibold tracking-wide">SolidJS</span>
      </a>
      <a href="https://orm.drizzle.team" target="_blank" rel="noopener">
        <span class="text-sm font-semibold tracking-wide">Drizzle</span>
      </a>
      <a href="https://stripe.com" target="_blank" rel="noopener">
        <span class="text-sm font-semibold tracking-wide">Stripe</span>
      </a>
      <a href="https://resend.com" target="_blank" rel="noopener">
        <span class="text-sm font-semibold tracking-wide">Resend</span>
      </a>
      <a href="https://tailwindcss.com" target="_blank" rel="noopener">
        <span class="text-sm font-semibold tracking-wide">Tailwind</span>
      </a>
      <a href="https://www.postgresql.org" target="_blank" rel="noopener">
        <span class="text-sm font-semibold tracking-wide">Postgres</span>
      </a>
    </LogoCloud>
  );
}
