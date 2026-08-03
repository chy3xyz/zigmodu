// Typed client for the zigmodu backend envelopes:
//   list:  { code: 0, items: [...], total: N }
//   get:   { code: 0, data: {...} }
//   write: { code: 0, id: N } / { code: 0 }
// The backend is JWT-protected; supply a token provider (e.g. after
// POST /api/v1/auth/login) and the client attaches it as a Bearer header.

export type ApiEnvelope<T = unknown> = {
  code: number;
  msg?: string;
  items?: T[];
  total?: number;
  data?: T;
  id?: number;
  ids?: number[];
};

export type PagedResult<T> = {
  items: T[];
  total: number;
};

export type ApiClient = {
  baseUrl: string;
  list: <T>(path: string, params?: Record<string, string | number>) => Promise<PagedResult<T>>;
  get: <T>(path: string, id: string | number) => Promise<T>;
  create: (path: string, body: unknown) => Promise<number>;
  createMany: (path: string, items: unknown[]) => Promise<number[]>;
  update: (path: string, id: string | number, body: unknown) => Promise<void>;
  remove: (path: string, id: string | number) => Promise<void>;
};

export function createApiClient(baseUrl: string, getToken: () => string | null): ApiClient {
  const root = baseUrl.replace(/\/+$/, '');

  function url(path: string): string {
    return `${root}/${path.replace(/^\/+/, '')}`;
  }

  async function request<T>(path: string, init?: RequestInit): Promise<T> {
    const headers: Record<string, string> = { ...(init?.headers as Record<string, string> | undefined) };
    headers['Content-Type'] = headers['Content-Type'] ?? 'application/json';
    const token = getToken();
    if (token) headers.Authorization = `Bearer ${token}`;

    const res = await fetch(url(path), { ...init, headers });
    if (res.status === 401) throw new Error('Unauthorized — 请先登录');
    const body = (await res.json().catch(() => null)) as ApiEnvelope<T> | null;
    if (!res.ok || (body && typeof body.code === 'number' && body.code !== 0)) {
      throw new Error(body?.msg ?? `Request failed (${res.status})`);
    }
    return body as T;
  }

  function query(params?: Record<string, string | number>): string {
    if (!params) return '';
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) q.set(k, String(v));
    const s = q.toString();
    return s ? `?${s}` : '';
  }

  return {
    baseUrl,
    async list<T>(path: string, params?: Record<string, string | number>): Promise<PagedResult<T>> {
      const env = await request<ApiEnvelope<T>>(`${path}${query(params)}`);
      return { items: env.items ?? [], total: env.total ?? (env.items?.length ?? 0) };
    },
    async get<T>(path: string, id: string | number): Promise<T> {
      const env = await request<ApiEnvelope<T>>(`${path}/${id}`);
      if (env.data === undefined) throw new Error('Not found');
      return env.data;
    },
    async create(path: string, body: unknown): Promise<number> {
      const env = await request<ApiEnvelope>(path, { method: 'POST', body: JSON.stringify(body) });
      return env.id ?? 0;
    },
    async createMany(path: string, items: unknown[]): Promise<number[]> {
      const env = await request<ApiEnvelope>(`${path}/bulk`, { method: 'POST', body: JSON.stringify(items) });
      return env.ids ?? [];
    },
    async update(path: string, id: string | number, body: unknown): Promise<void> {
      await request<ApiEnvelope>(`${path}/${id}`, { method: 'PUT', body: JSON.stringify(body) });
    },
    async remove(path: string, id: string | number): Promise<void> {
      await request<ApiEnvelope>(`${path}/${id}`, { method: 'DELETE' });
    },
  };
}

export async function login(baseUrl: string): Promise<string> {
  const root = baseUrl.replace(/\/+$/, '');
  const res = await fetch(`${root}/auth/login`, { method: 'POST' });
  const body = (await res.json().catch(() => null)) as { token?: string } | null;
  if (!res.ok || !body?.token) throw new Error('Login failed');
  return body.token;
}
