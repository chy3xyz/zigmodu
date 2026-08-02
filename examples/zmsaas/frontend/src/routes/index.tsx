import { Meta, Title } from '@solidjs/meta';
import { CTA } from '@/templates/CTA';
import { DemoBanner } from '@/templates/DemoBanner';
import { FAQ } from '@/templates/FAQ';
import { Features } from '@/templates/Features';
import { Footer } from '@/templates/Footer';
import { Hero } from '@/templates/Hero';
import { Navbar } from '@/templates/Navbar';
import { Pricing } from '@/templates/Pricing';
import { Sponsors } from '@/templates/Sponsors';
import { useTranslations } from '@/libs/I18nContext';
import { AppConfig } from '@/utils/AppConfig';
import { getBaseUrl } from '@/utils/Helpers';

export default function Home() {
  const t = useTranslations();
  const title = () => t('Index.meta_title') as string;
  const description = () => t('Index.meta_description') as string;
  const url = () => getBaseUrl();

  return (
    <>
      <Title>{title()}</Title>
      <Meta name="description" content={description()} />
      <Meta property="og:type" content="website" />
      <Meta property="og:site_name" content={AppConfig.name} />
      <Meta property="og:title" content={title()} />
      <Meta property="og:description" content={description()} />
      <Meta property="og:url" content={url()} />
      <Meta name="twitter:card" content="summary_large_image" />
      <Meta name="twitter:title" content={title()} />
      <Meta name="twitter:description" content={description()} />
      <DemoBanner />
      <Navbar />
      <Hero />
      <Sponsors />
      <Features />
      <Pricing />
      <FAQ />
      <CTA />
      <Footer />
    </>
  );
}
