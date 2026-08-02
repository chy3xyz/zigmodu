import { action, query, redirect } from '@solidjs/router';
import {
  acceptInvitation,
  addMembership,
  countAdmins,
  createInvitation,
  createUser,
  deleteOrganization,
  findInvitationById,
  findInvitationByTokenHash,
  findUserByEmail,
  findUserById,
  getMembership,
  listInvitations,
  listMembers,
  listOrganizationsForUser,
  refreshInvitationToken,
  removeMember,
  revokeInvitation,
  updateOrganization,
  updateUser,
} from '@/auth/db';
import {
  createAndSelectOrganization,
  getSession,
  issueEmailVerification,
  refreshSession,
  requestPasswordReset,
  resetPassword,
  selectOrganization,
  signIn,
  signUp,
  verifyEmailToken,
} from '@/auth/server';
import { createRawToken, hashPassword, hashToken, verifyPassword } from '@/libs/crypto';
import { guardForm } from '@/libs/csrf';
import { sendInviteEmail } from '@/libs/email';
import { Env } from '@/libs/Env';
import { requireOrgMember, requireUser } from '@/libs/rbac';
import { ORG_ROLE, type OrgRole } from '@/types/Auth';
import { stripLocale } from '@/utils/Helpers';

const PROTECTED_PREFIXES = ['/dashboard', '/onboarding'];

function isProtected(path: string) {
  return PROTECTED_PREFIXES.some(
    prefix => path === prefix || path.startsWith(`${prefix}/`),
  );
}

export const querySession = query(async (pathname: string) => {
  'use server';
  const { path } = stripLocale(pathname);
  const { data } = await getSession();

  if ((path === '/sign-in' || path === '/sign-up') && data.id) {
    return redirect('/dashboard');
  }

  if (data.id) {
    if (
      path.startsWith('/dashboard')
      && !data.activeOrgId
      && !path.startsWith('/onboarding')
    ) {
      throw redirect('/onboarding/organization-selection');
    }
    return data;
  }

  if (isProtected(path)) {
    throw redirect(`/sign-in?redirect=${encodeURIComponent(path)}`);
  }

  return null;
}, 'session');

export const formSignIn = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData, { rateKey: 'signin', limit: 10, windowMs: 60_000 });
  if (blocked) return blocked;
  const email = formData.get('email');
  const password = formData.get('password');
  const redirectTo = formData.get('redirect');
  if (typeof email !== 'string' || typeof password !== 'string') {
    return new Error('Email and password are required');
  }
  try {
    return await signIn(
      email.trim().toLowerCase(),
      password,
      typeof redirectTo === 'string' ? redirectTo : undefined,
    );
  }
  catch (error) {
    return error instanceof Error ? error : new Error('Sign in failed');
  }
});

export const formSignUp = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData, { rateKey: 'signup', limit: 8, windowMs: 60_000 });
  if (blocked) return blocked;
  const email = formData.get('email');
  const password = formData.get('password');
  const name = formData.get('name');
  const locale = formData.get('locale');
  const redirectTo = formData.get('redirect');
  if (
    typeof email !== 'string'
    || typeof password !== 'string'
    || typeof name !== 'string'
  ) {
    return new Error('Name, email and password are required');
  }
  try {
    return await signUp(
      email.trim().toLowerCase(),
      password,
      name.trim(),
      typeof locale === 'string' ? locale : 'en',
      typeof redirectTo === 'string' ? redirectTo : undefined,
    );
  }
  catch (error) {
    return error instanceof Error ? error : new Error('Sign up failed');
  }
});

export const logout = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const session = await getSession();
  await session.update(null as never);
  throw redirect('/sign-in', { revalidate: 'session' });
});

export const formCreateOrg = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const name = formData.get('name');
  if (typeof name !== 'string' || !name.trim()) {
    return new Error('Organization name is required');
  }
  try {
    return await createAndSelectOrganization(name.trim());
  }
  catch (error) {
    return error instanceof Error ? error : new Error('Failed to create organization');
  }
});

export const formSelectOrg = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const orgId = formData.get('orgId');
  if (typeof orgId !== 'string') {
    return new Error('Organization is required');
  }
  try {
    return await selectOrganization(orgId);
  }
  catch (error) {
    return error instanceof Error ? error : new Error('Failed to select organization');
  }
});

export const formForgotPassword = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData, { rateKey: 'forgot', limit: 5, windowMs: 60_000 });
  if (blocked) return blocked;
  const email = formData.get('email');
  if (typeof email !== 'string') return new Error('Email is required');
  await requestPasswordReset(email.trim().toLowerCase());
  return { ok: true };
});

export const formResetPassword = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData, { rateKey: 'reset', limit: 8, windowMs: 60_000 });
  if (blocked) return blocked;
  const token = formData.get('token');
  const password = formData.get('password');
  if (typeof token !== 'string' || typeof password !== 'string') {
    return new Error('Token and password are required');
  }
  try {
    await resetPassword(token, password);
    return redirect('/sign-in');
  }
  catch (error) {
    return error instanceof Error ? error : new Error('Reset failed');
  }
});

export const formVerifyEmail = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData, { rateKey: 'verify', limit: 10, windowMs: 60_000 });
  if (blocked) return blocked;
  const token = formData.get('token');
  if (typeof token !== 'string') return new Error('Token is required');
  try {
    await verifyEmailToken(token);
    return redirect('/dashboard');
  }
  catch (error) {
    return error instanceof Error ? error : new Error('Verification failed');
  }
});

export const formResendVerification = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData, { rateKey: 'resend-verify', limit: 5, windowMs: 60_000 });
  if (blocked) return blocked;
  const user = await requireUser();
  const dbUser = await findUserById(user.id);
  if (!dbUser) return new Error('User not found');
  if (dbUser.emailVerifiedAt) return { ok: true };
  await issueEmailVerification(dbUser.id, dbUser.email, dbUser.name, dbUser.locale);
  return { ok: true };
});

export const formUpdateProfile = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const user = await requireUser();
  const name = formData.get('name');
  if (typeof name !== 'string' || !name.trim()) return new Error('Name is required');
  await updateUser(user.id, { name: name.trim() });
  const session = await getSession();
  await session.update({ ...session.data, name: name.trim() });
  return redirect('/dashboard/user-profile');
});

export const formChangePassword = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const user = await requireUser();
  const current = formData.get('currentPassword');
  const next = formData.get('newPassword');
  if (typeof current !== 'string' || typeof next !== 'string') {
    return new Error('Passwords are required');
  }
  const dbUser = await findUserById(user.id);
  if (!dbUser) return new Error('User not found');
  try {
    await verifyPassword(dbUser.passwordHash, current);
  }
  catch {
    return new Error('Current password is incorrect');
  }
  await updateUser(user.id, { passwordHash: await hashPassword(next) });
  return { ok: true };
});

export const formUpdateOrg = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  const name = formData.get('name');
  if (typeof name !== 'string' || !name.trim()) return new Error('Name is required');
  await updateOrganization(member.activeOrgId, { name: name.trim() });
  const session = await getSession();
  await session.update({ ...session.data, activeOrgName: name.trim() });
  return redirect('/dashboard/organization-profile');
});

export const formLeaveOrg = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const member = await requireOrgMember();
  if (member.role === ORG_ROLE.ADMIN) {
    const admins = await countAdmins(member.activeOrgId);
    if (admins <= 1) {
      return new Error('Cannot leave as the only admin. Transfer ownership or delete the organization.');
    }
  }
  await removeMember(member.activeOrgId, member.id);
  const orgs = await listOrganizationsForUser(member.id);
  const next = orgs[0]?.id;
  await refreshSession(next);
  throw redirect(next ? '/dashboard' : '/onboarding/organization-selection');
});

export const formDeleteOrg = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  const confirm = formData.get('confirm');
  if (confirm !== member.activeOrgName) {
    return new Error('Type the organization name to confirm deletion');
  }
  await deleteOrganization(member.activeOrgId);
  const orgs = await listOrganizationsForUser(member.id);
  const next = orgs[0]?.id;
  await refreshSession(next);
  throw redirect(next ? '/dashboard' : '/onboarding/organization-selection');
});

export const formInviteMember = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData, { rateKey: 'invite', limit: 20, windowMs: 60_000 });
  if (blocked) return blocked;
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  if (!member.emailVerified) {
    return new Error('Verify your email before inviting members');
  }
  const email = formData.get('email');
  const role = formData.get('role');
  if (typeof email !== 'string') return new Error('Email is required');
  const inviteRole = (typeof role === 'string' && role === ORG_ROLE.ADMIN
    ? ORG_ROLE.ADMIN
    : ORG_ROLE.MEMBER) as OrgRole;
  const raw = createRawToken();
  await createInvitation({
    orgId: member.activeOrgId,
    email: email.trim().toLowerCase(),
    role: inviteRole,
    tokenHash: hashToken(raw),
    invitedBy: member.id,
    expiresAt: new Date(Date.now() + 1000 * 60 * 60 * 24 * 7),
  });
  const url = `${Env.PUBLIC_APP_URL}/invite/${raw}`;
  await sendInviteEmail({
    to: email.trim().toLowerCase(),
    orgName: member.activeOrgName ?? 'organization',
    url,
    locale: member.locale === 'zh' ? 'zh' : 'en',
  });
  return redirect('/dashboard/members');
});

export const formRevokeInvite = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  const invitationId = Number(formData.get('invitationId'));
  if (!invitationId) return new Error('Invitation is required');
  await revokeInvitation(member.activeOrgId, invitationId);
  return redirect('/dashboard/members');
});

export const formResendInvite = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData, { rateKey: 'resend-invite', limit: 10, windowMs: 60_000 });
  if (blocked) return blocked;
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  const invitationId = Number(formData.get('invitationId'));
  if (!invitationId) return new Error('Invitation is required');
  const invite = await findInvitationById(member.activeOrgId, invitationId);
  if (!invite) return new Error('Invitation not found');
  const raw = createRawToken();
  await refreshInvitationToken(
    invite.id,
    hashToken(raw),
    new Date(Date.now() + 1000 * 60 * 60 * 24 * 7),
  );
  await sendInviteEmail({
    to: invite.email,
    orgName: member.activeOrgName ?? 'organization',
    url: `${Env.PUBLIC_APP_URL}/invite/${raw}`,
    locale: member.locale === 'zh' ? 'zh' : 'en',
  });
  return redirect('/dashboard/members');
});

export const formRemoveMember = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  const userId = Number(formData.get('userId'));
  if (!userId || userId === member.id) {
    return new Error('Cannot remove this member');
  }
  await removeMember(member.activeOrgId, userId);
  return redirect('/dashboard/members');
});

export const formAcceptInvite = action(async (formData: FormData) => {
  'use server';
  const blocked = await guardForm(formData);
  if (blocked) return blocked;
  const token = formData.get('token');
  if (typeof token !== 'string') return new Error('Token is required');
  const invite = await findInvitationByTokenHash(hashToken(token));
  if (!invite) return new Error('Invalid or expired invitation');

  let user = await findUserByEmail(invite.email);
  const password = formData.get('password');
  const name = formData.get('name');

  if (!user) {
    if (typeof password !== 'string' || typeof name !== 'string') {
      return new Error('Name and password are required to join');
    }
    user = await createUser({
      email: invite.email,
      name: name.trim(),
      passwordHash: await hashPassword(password),
    });
  }

  const existing = await getMembership(user.id, invite.orgId);
  if (!existing) {
    await addMembership(user.id, invite.orgId, invite.role as OrgRole);
  }
  await acceptInvitation(invite.id);
  const session = await getSession();
  await session.update({
    id: user.id,
    email: user.email,
    name: user.name,
    emailVerified: Boolean(user.emailVerifiedAt),
    locale: user.locale,
    activeOrgId: invite.orgId,
  });
  await refreshSession(invite.orgId);
  return redirect('/dashboard');
});

export const queryOrgs = query(async () => {
  'use server';
  const { data } = await getSession();
  if (!data.id) return [];
  return listOrganizationsForUser(data.id);
}, 'orgs');

export const queryMembers = query(async () => {
  'use server';
  const member = await requireOrgMember();
  return listMembers(member.activeOrgId);
}, 'members');

export const queryPendingInvites = query(async () => {
  'use server';
  const member = await requireOrgMember(ORG_ROLE.ADMIN);
  return listInvitations(member.activeOrgId);
}, 'invites');
