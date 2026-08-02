import { and, eq, gt, isNull } from 'drizzle-orm';
import { db } from '@/libs/DB';
import {
  authTokens,
  invitations,
  memberships,
  organizations,
  stripeWebhookEvents,
  subscriptions,
  users,
} from '@/models/Schema';
import { AUTH_TOKEN_TYPE, ORG_ROLE, type AuthTokenType, type OrgRole } from '@/types/Auth';

export async function createUser(data: {
  email: string;
  name: string;
  passwordHash: string;
  locale?: string;
}) {
  const [user] = await db
    .insert(users)
    .values({
      email: data.email,
      name: data.name,
      passwordHash: data.passwordHash,
      locale: data.locale ?? 'en',
    })
    .returning();
  return user!;
}

export async function findUserByEmail(email: string) {
  const [user] = await db.select().from(users).where(eq(users.email, email)).limit(1);
  return user;
}

export async function findUserById(id: number) {
  const [user] = await db.select().from(users).where(eq(users.id, id)).limit(1);
  return user;
}

export async function updateUser(
  id: number,
  patch: Partial<{
    name: string;
    passwordHash: string;
    emailVerifiedAt: Date | null;
    locale: string;
  }>,
) {
  const [user] = await db.update(users).set(patch).where(eq(users.id, id)).returning();
  return user;
}

export async function createOrganization(ownerId: number, name: string) {
  const id = `org_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const [org] = await db.insert(organizations).values({ id, name }).returning();
  await db.insert(memberships).values({
    userId: ownerId,
    orgId: id,
    role: ORG_ROLE.ADMIN,
  });
  await db.insert(subscriptions).values({
    orgId: id,
    status: 'inactive',
  });
  return org!;
}

export async function findOrganization(orgId: string) {
  const [org] = await db.select().from(organizations).where(eq(organizations.id, orgId)).limit(1);
  return org;
}

export async function updateOrganization(
  orgId: string,
  patch: Partial<{ name: string; stripeCustomerId: string | null }>,
) {
  const [org] = await db.update(organizations).set(patch).where(eq(organizations.id, orgId)).returning();
  return org;
}

export async function listOrganizationsForUser(userId: number) {
  return db
    .select({
      id: organizations.id,
      name: organizations.name,
      role: memberships.role,
      stripeCustomerId: organizations.stripeCustomerId,
    })
    .from(memberships)
    .innerJoin(organizations, eq(memberships.orgId, organizations.id))
    .where(eq(memberships.userId, userId));
}

export async function getMembership(userId: number, orgId: string) {
  const [row] = await db
    .select()
    .from(memberships)
    .where(and(eq(memberships.userId, userId), eq(memberships.orgId, orgId)))
    .limit(1);
  return row;
}

export async function listMembers(orgId: string) {
  return db
    .select({
      membershipId: memberships.id,
      userId: users.id,
      email: users.email,
      name: users.name,
      role: memberships.role,
      joinedAt: memberships.createdAt,
    })
    .from(memberships)
    .innerJoin(users, eq(memberships.userId, users.id))
    .where(eq(memberships.orgId, orgId));
}

export async function removeMember(orgId: string, userId: number) {
  await db
    .delete(memberships)
    .where(and(eq(memberships.orgId, orgId), eq(memberships.userId, userId)));
}

export async function addMembership(userId: number, orgId: string, role: OrgRole) {
  const [row] = await db
    .insert(memberships)
    .values({ userId, orgId, role })
    .returning();
  return row!;
}

export async function createInvitation(data: {
  orgId: string;
  email: string;
  role: OrgRole;
  tokenHash: string;
  invitedBy: number;
  expiresAt: Date;
}) {
  const [row] = await db.insert(invitations).values(data).returning();
  return row!;
}

export async function findInvitationByTokenHash(tokenHash: string) {
  const [row] = await db
    .select()
    .from(invitations)
    .where(
      and(
        eq(invitations.tokenHash, tokenHash),
        isNull(invitations.acceptedAt),
        gt(invitations.expiresAt, new Date()),
      ),
    )
    .limit(1);
  return row;
}

export async function listInvitations(orgId: string) {
  return db
    .select()
    .from(invitations)
    .where(and(eq(invitations.orgId, orgId), isNull(invitations.acceptedAt)));
}

export async function acceptInvitation(id: number) {
  const [row] = await db
    .update(invitations)
    .set({ acceptedAt: new Date() })
    .where(eq(invitations.id, id))
    .returning();
  return row;
}

export async function revokeInvitation(orgId: string, invitationId: number) {
  await db
    .delete(invitations)
    .where(
      and(
        eq(invitations.id, invitationId),
        eq(invitations.orgId, orgId),
        isNull(invitations.acceptedAt),
      ),
    );
}

export async function findInvitationById(orgId: string, invitationId: number) {
  const [row] = await db
    .select()
    .from(invitations)
    .where(
      and(
        eq(invitations.id, invitationId),
        eq(invitations.orgId, orgId),
        isNull(invitations.acceptedAt),
      ),
    )
    .limit(1);
  return row;
}

export async function refreshInvitationToken(
  invitationId: number,
  tokenHash: string,
  expiresAt: Date,
) {
  const [row] = await db
    .update(invitations)
    .set({ tokenHash, expiresAt })
    .where(eq(invitations.id, invitationId))
    .returning();
  return row;
}

export async function countAdmins(orgId: string) {
  const rows = await db
    .select({ id: memberships.id })
    .from(memberships)
    .where(and(eq(memberships.orgId, orgId), eq(memberships.role, ORG_ROLE.ADMIN)));
  return rows.length;
}

export async function deleteOrganization(orgId: string) {
  await db.delete(organizations).where(eq(organizations.id, orgId));
}

export async function claimWebhookEvent(id: string, type: string) {
  try {
    await db.insert(stripeWebhookEvents).values({ id, type });
    return true;
  }
  catch {
    return false; // already processed (unique PK)
  }
}

export async function createAuthToken(data: {
  userId: number;
  type: AuthTokenType;
  tokenHash: string;
  expiresAt: Date;
}) {
  const [row] = await db.insert(authTokens).values(data).returning();
  return row!;
}

export async function findValidAuthToken(tokenHash: string, type: AuthTokenType) {
  const [row] = await db
    .select()
    .from(authTokens)
    .where(
      and(
        eq(authTokens.tokenHash, tokenHash),
        eq(authTokens.type, type),
        isNull(authTokens.usedAt),
        gt(authTokens.expiresAt, new Date()),
      ),
    )
    .limit(1);
  return row;
}

export async function markAuthTokenUsed(id: number) {
  await db.update(authTokens).set({ usedAt: new Date() }).where(eq(authTokens.id, id));
}

export async function getSubscription(orgId: string) {
  const [row] = await db.select().from(subscriptions).where(eq(subscriptions.orgId, orgId)).limit(1);
  return row;
}

export async function upsertSubscription(data: {
  orgId: string;
  stripeSubscriptionId?: string | null;
  stripePriceId?: string | null;
  status: string;
  currentPeriodEnd?: Date | null;
}) {
  const existing = await getSubscription(data.orgId);
  if (existing) {
    const [row] = await db
      .update(subscriptions)
      .set({
        stripeSubscriptionId: data.stripeSubscriptionId ?? existing.stripeSubscriptionId,
        stripePriceId: data.stripePriceId ?? existing.stripePriceId,
        status: data.status,
        currentPeriodEnd: data.currentPeriodEnd ?? existing.currentPeriodEnd,
      })
      .where(eq(subscriptions.orgId, data.orgId))
      .returning();
    return row!;
  }
  const [row] = await db.insert(subscriptions).values(data).returning();
  return row!;
}

export { AUTH_TOKEN_TYPE, ORG_ROLE };
