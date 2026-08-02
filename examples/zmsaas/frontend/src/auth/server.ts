import { redirect } from '@solidjs/router';
import { useSession } from '@solidjs/start/http';
import {
  createAuthToken,
  createOrganization,
  createUser,
  findOrganization,
  findUserByEmail,
  findUserById,
  findValidAuthToken,
  getMembership,
  listOrganizationsForUser,
  markAuthTokenUsed,
  updateUser,
} from '@/auth/db';
import { createRawToken, hashPassword, hashToken, verifyPassword } from '@/libs/crypto';
import { sendPasswordResetEmail, sendVerifyEmail } from '@/libs/email';
import { Env } from '@/libs/Env';
import { AUTH_TOKEN_TYPE, type OrgRole, type SessionUser } from '@/types/Auth';

export type SessionData = Partial<SessionUser>;

export const getSession = () =>
  useSession<SessionData>({
    password: Env.SESSION_SECRET,
    name: 'saas_session',
    cookie: {
      secure: Env.NODE_ENV === 'production',
      httpOnly: true,
      sameSite: 'lax',
      maxAge: 60 * 60 * 24 * 14,
    },
  });

async function toSessionUser(
  user: {
    id: number;
    email: string;
    name: string;
    emailVerifiedAt: Date | null;
    locale: string;
  },
  activeOrgId?: string,
): Promise<SessionUser> {
  let orgName: string | undefined;
  let role: OrgRole | undefined;
  if (activeOrgId) {
    const org = await findOrganization(activeOrgId);
    const membership = await getMembership(user.id, activeOrgId);
    orgName = org?.name;
    role = membership?.role as OrgRole | undefined;
  }
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    emailVerified: Boolean(user.emailVerifiedAt),
    locale: user.locale,
    activeOrgId,
    activeOrgName: orgName,
    role,
  };
}

export async function createSession(user: SessionUser, redirectTo?: string) {
  const session = await getSession();
  await session.update(user);
  const dest = redirectTo && redirectTo.startsWith('/') ? redirectTo : '/dashboard';
  return redirect(dest);
}

export async function refreshSession(activeOrgId?: string) {
  const session = await getSession();
  if (!session.data.id) return null;
  const user = await findUserById(session.data.id);
  if (!user) return null;
  const next = await toSessionUser(user, activeOrgId ?? session.data.activeOrgId);
  await session.update(next);
  return next;
}

export async function signIn(email: string, password: string, redirectTo?: string) {
  const user = await findUserByEmail(email);
  if (!user) throw new Error('Invalid email or password');
  await verifyPassword(user.passwordHash, password);
  const orgs = await listOrganizationsForUser(user.id);
  const activeOrgId = orgs[0]?.id;
  const sessionUser = await toSessionUser(user, activeOrgId);
  return createSession(sessionUser, redirectTo);
}

export async function signUp(
  email: string,
  password: string,
  name: string,
  locale: string,
  redirectTo?: string,
) {
  const existing = await findUserByEmail(email);
  if (existing) throw new Error('Account already exists');
  const user = await createUser({
    email,
    name,
    passwordHash: await hashPassword(password),
    locale,
  });
  await issueEmailVerification(user.id, user.email, user.name, locale);
  const sessionUser = await toSessionUser(user);
  return createSession(sessionUser, redirectTo ?? '/onboarding/organization-selection');
}

export async function issueEmailVerification(
  userId: number,
  email: string,
  name: string,
  locale: string,
) {
  const raw = createRawToken();
  await createAuthToken({
    userId,
    type: AUTH_TOKEN_TYPE.EMAIL_VERIFY,
    tokenHash: hashToken(raw),
    expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24),
  });
  const url = `${Env.PUBLIC_APP_URL}/verify-email?token=${raw}`;
  await sendVerifyEmail({
    to: email,
    name,
    url,
    locale: locale === 'zh' ? 'zh' : 'en',
  });
}

export async function verifyEmailToken(rawToken: string) {
  const token = await findValidAuthToken(hashToken(rawToken), AUTH_TOKEN_TYPE.EMAIL_VERIFY);
  if (!token) throw new Error('Invalid or expired token');
  await updateUser(token.userId, { emailVerifiedAt: new Date() });
  await markAuthTokenUsed(token.id);
  await refreshSession();
}

export async function requestPasswordReset(email: string) {
  const user = await findUserByEmail(email);
  if (!user) return; // do not leak existence
  const raw = createRawToken();
  await createAuthToken({
    userId: user.id,
    type: AUTH_TOKEN_TYPE.PASSWORD_RESET,
    tokenHash: hashToken(raw),
    expiresAt: new Date(Date.now() + 1000 * 60 * 60),
  });
  const url = `${Env.PUBLIC_APP_URL}/reset-password?token=${raw}`;
  await sendPasswordResetEmail({
    to: user.email,
    name: user.name,
    url,
    locale: user.locale === 'zh' ? 'zh' : 'en',
  });
}

export async function resetPassword(rawToken: string, password: string) {
  const token = await findValidAuthToken(hashToken(rawToken), AUTH_TOKEN_TYPE.PASSWORD_RESET);
  if (!token) throw new Error('Invalid or expired token');
  await updateUser(token.userId, { passwordHash: await hashPassword(password) });
  await markAuthTokenUsed(token.id);
}

export async function selectOrganization(orgId: string) {
  const session = await getSession();
  if (!session.data.id) throw redirect('/sign-in');
  const membership = await getMembership(session.data.id, orgId);
  if (!membership) throw new Error('Organization not found');
  await refreshSession(orgId);
  return redirect('/dashboard');
}

export async function createAndSelectOrganization(name: string) {
  const session = await getSession();
  if (!session.data.id) throw redirect('/sign-in');
  const org = await createOrganization(session.data.id, name);
  await refreshSession(org.id);
  return redirect('/dashboard');
}

export { listOrganizationsForUser, findOrganization, getMembership };
