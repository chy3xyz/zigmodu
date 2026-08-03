import { describe, expect, it } from 'vitest';
import { createApiClient } from '@/libs/apiClient';

function stubFetch(handler: (url: string, init?: RequestInit) => { status: number; body: unknown }) {
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input.toString();
    const { status, body } = handler(url, init);
    return Promise.resolve({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
    } as Response);
  }) as typeof fetch;
}

describe('apiClient', () => {
  it('parses the paged envelope and attaches the bearer token', async () => {
    stubFetch((url, init) => {
      expect(url).toBe('http://api.test/orders?page=1&page_size=20');
      expect(init?.headers).toMatchObject({ Authorization: 'Bearer tok' });
      return { status: 200, body: { code: 0, items: [{ id: 1 }], total: 7 } };
    });
    const client = createApiClient('http://api.test', () => 'tok');
    const result = await client.list('orders', { page: 1, page_size: 20 });
    expect(result.total).toBe(7);
    expect(result.items).toEqual([{ id: 1 }]);
  });

  it('throws on non-zero envelope code', async () => {
    stubFetch(() => ({ status: 400, body: { code: 400, msg: 'invalid body' } }));
    const client = createApiClient('http://api.test', () => null);
    await expect(client.create('orders', { customer: '' })).rejects.toThrow('invalid body');
  });

  it('throws on 401', async () => {
    stubFetch(() => ({ status: 401, body: null }));
    const client = createApiClient('http://api.test', () => null);
    await expect(client.list('orders')).rejects.toThrow('Unauthorized');
  });

  it('createMany posts an array to the bulk endpoint', async () => {
    stubFetch((url, init) => {
      expect(url).toBe('http://api.test/orders/bulk');
      const body = JSON.parse(String(init?.body));
      expect(body).toEqual([{ customer: 'a' }, { customer: 'b' }]);
      return { status: 200, body: { code: 0, ids: [7, 8] } };
    });
    const client = createApiClient('http://api.test', () => null);
    const ids = await client.createMany('orders', [{ customer: 'a' }, { customer: 'b' }]);
    expect(ids).toEqual([7, 8]);
  });
});
