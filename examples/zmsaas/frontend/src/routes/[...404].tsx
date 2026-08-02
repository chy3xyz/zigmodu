import { A } from '@solidjs/router';
import { Title } from '@solidjs/meta';

export default function NotFound() {
  return (
    <main class="flex min-h-svh flex-col items-center justify-center gap-4 p-8">
      <Title>Not Found</Title>
      <h1 class="text-3xl font-bold">404</h1>
      <p class="text-muted-foreground">Page not found.</p>
      <A href="/" class="text-primary underline">Go home</A>
    </main>
  );
}
