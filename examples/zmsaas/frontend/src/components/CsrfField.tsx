import { createAsync } from '@solidjs/router';
import type { JSX } from 'solid-js';
import { queryCsrfToken } from '@/libs/csrfActions';
import { CSRF_FIELD } from '@/libs/csrfConstants';

/** Hidden CSRF field for server actions (double-submit cookie). */
export function CsrfField(): JSX.Element {
  const token = createAsync(() => queryCsrfToken());
  return <input type="hidden" name={CSRF_FIELD} value={token() ?? ''} />;
}
