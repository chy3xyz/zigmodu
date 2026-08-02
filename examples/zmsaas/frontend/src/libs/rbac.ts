import { redirect } from '@solidjs/router';
import { getMembership, getSubscription } from '@/auth/db';
import { getSession } from '@/auth/server';
import type { OrgRole, SessionUser } from '@/types/Auth';
import { ORG_ROLE, SUBSCRIPTION_STATUS } from '@/types/Auth';

const ROLE_RANK: Record<OrgRole, number> = {
  [ORG_ROLE.MEMBER]: 1,
  [ORG_ROLE.ADMIN]: 2,
};

export async function requireUser(): Promise<SessionUser> {
  const session = await getSession();
  if (!session.data.id) {
    throw redirect('/sign-in');
  }
  return session.data as SessionUser;
}

export async function requireOrgMember(minRole: OrgRole = ORG_ROLE.MEMBER) {
  const user = await requireUser();
  if (!user.activeOrgId) {
    throw redirect('/onboarding/organization-selection');
  }
  const membership = await getMembership(user.id, user.activeOrgId);
  if (!membership) {
    throw redirect('/onboarding/organization-selection');
  }
  const role = membership.role as OrgRole;
  if (ROLE_RANK[role] < ROLE_RANK[minRole]) {
    throw new Error('Forbidden');
  }
  return {
    ...user,
    activeOrgId: user.activeOrgId,
    role,
  };
}

export async function requireActiveSubscription() {
  const member = await requireOrgMember();
  const sub = await getSubscription(member.activeOrgId);
  const ok
    = sub
      && (sub.status === SUBSCRIPTION_STATUS.ACTIVE || sub.status === SUBSCRIPTION_STATUS.TRIALING);
  if (!ok) {
    throw redirect('/dashboard/billing');
  }
  return { ...member, subscription: sub };
}
