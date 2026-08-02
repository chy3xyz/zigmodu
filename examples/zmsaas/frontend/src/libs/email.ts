import { Resend } from 'resend';
import { Env } from '@/libs/Env';

const resend = Env.RESEND_API_KEY ? new Resend(Env.RESEND_API_KEY) : null;

type MailLocale = 'en' | 'zh';

function t(locale: MailLocale, en: string, zh: string) {
  return locale === 'zh' ? zh : en;
}

async function send(opts: { to: string; subject: string; html: string }) {
  if (Env.EMAIL_MOCK || !resend) {
    console.info('[email:mock]', opts.subject, '→', opts.to, '\n', opts.html);
    return { id: 'mock' };
  }
  const result = await resend.emails.send({
    from: Env.EMAIL_FROM,
    to: opts.to,
    subject: opts.subject,
    html: opts.html,
  });
  if (result.error) {
    throw new Error(result.error.message);
  }
  return result.data;
}

export async function sendVerifyEmail(opts: {
  to: string;
  name: string;
  url: string;
  locale?: MailLocale;
}) {
  const locale = opts.locale ?? 'en';
  return send({
    to: opts.to,
    subject: t(locale, 'Verify your email', '验证您的邮箱'),
    html: `<p>${t(locale, `Hi ${opts.name},`, `你好 ${opts.name}，`)}</p>
<p>${t(locale, 'Please verify your email by clicking the link below:', '请点击以下链接验证邮箱：')}</p>
<p><a href="${opts.url}">${opts.url}</a></p>`,
  });
}

export async function sendPasswordResetEmail(opts: {
  to: string;
  name: string;
  url: string;
  locale?: MailLocale;
}) {
  const locale = opts.locale ?? 'en';
  return send({
    to: opts.to,
    subject: t(locale, 'Reset your password', '重置密码'),
    html: `<p>${t(locale, `Hi ${opts.name},`, `你好 ${opts.name}，`)}</p>
<p>${t(locale, 'Reset your password using this link (valid for 1 hour):', '请使用以下链接重置密码（1 小时内有效）：')}</p>
<p><a href="${opts.url}">${opts.url}</a></p>`,
  });
}

export async function sendInviteEmail(opts: {
  to: string;
  orgName: string;
  url: string;
  locale?: MailLocale;
}) {
  const locale = opts.locale ?? 'en';
  return send({
    to: opts.to,
    subject: t(locale, `Invitation to ${opts.orgName}`, `邀请加入 ${opts.orgName}`),
    html: `<p>${t(locale, `You have been invited to join ${opts.orgName}.`, `您被邀请加入 ${opts.orgName}。`)}</p>
<p><a href="${opts.url}">${t(locale, 'Accept invitation', '接受邀请')}</a></p>`,
  });
}
