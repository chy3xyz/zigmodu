/// <reference types="@solidjs/start/env" />

declare module '*.svg' {
  const src: string;
  export default src;
}

declare module '*.png' {
  const src: string;
  export default src;
}

declare module '@solidjs/start/server' {
  import type { JSX } from 'solid-js';

  export type APIEvent = {
    request: Request;
    params: Record<string, string>;
    nativeEvent?: unknown;
  };

  export type PageEvent = {
    request: Request;
    locals: {
      locale: string;
      path: string;
      [key: string]: unknown;
    };
    response: Response;
    nativeEvent?: unknown;
  };

  export type DocumentComponentProps = {
    assets: JSX.Element;
    children: JSX.Element;
    scripts: JSX.Element;
  };

  export function createHandler(
    fn: (context: PageEvent) => JSX.Element,
    options?: unknown,
  ): unknown;

  export function StartServer(props: {
    document: (props: DocumentComponentProps) => JSX.Element;
  }): JSX.Element;
}
