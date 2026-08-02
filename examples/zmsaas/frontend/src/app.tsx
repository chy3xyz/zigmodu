import type { RouteDefinition } from '@solidjs/router';
import { MetaProvider } from '@solidjs/meta';
import { Router } from '@solidjs/router';
import { FileRoutes } from '@solidjs/start/router';
import { Suspense } from 'solid-js';
import { querySession } from '@/auth';
import { I18nProvider } from '@/libs/I18nContext';
import '@/styles/global.css';

export const route: RouteDefinition = {
  preload: ({ location }) => querySession(location.pathname),
};

export default function App() {
  return (
    <Router
      root={props => (
        <MetaProvider>
          <I18nProvider>
            <Suspense fallback={<div class="p-8 text-center text-muted-foreground">Loading…</div>}>
              {props.children}
            </Suspense>
          </I18nProvider>
        </MetaProvider>
      )}
    >
      <FileRoutes />
    </Router>
  );
}
