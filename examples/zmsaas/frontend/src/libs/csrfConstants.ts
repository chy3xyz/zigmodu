export const CSRF_COOKIE = 'csrf_token';
export const CSRF_FIELD = 'csrf';

export function createCsrfToken(bytes = 24) {
  const arr = new Uint8Array(bytes);
  crypto.getRandomValues(arr);
  return Array.from(arr, b => b.toString(16).padStart(2, '0')).join('');
}
