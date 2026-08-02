export const ORG_ROLE = {
  ADMIN: 'admin',
  MEMBER: 'member',
} as const;

export type OrgRole = (typeof ORG_ROLE)[keyof typeof ORG_ROLE];

export type SessionUser = {
  id: number;
  email: string;
  name: string;
  emailVerified: boolean;
  locale: string;
  activeOrgId?: string;
  activeOrgName?: string;
  role?: OrgRole;
};

export const AUTH_TOKEN_TYPE = {
  EMAIL_VERIFY: 'email_verify',
  PASSWORD_RESET: 'password_reset',
} as const;

export type AuthTokenType = (typeof AUTH_TOKEN_TYPE)[keyof typeof AUTH_TOKEN_TYPE];

export const SUBSCRIPTION_STATUS = {
  ACTIVE: 'active',
  TRIALING: 'trialing',
  PAST_DUE: 'past_due',
  CANCELED: 'canceled',
  INACTIVE: 'inactive',
} as const;
