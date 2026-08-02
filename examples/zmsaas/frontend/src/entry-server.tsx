// @refresh reload
import { createHandler, StartServer, type PageEvent } from '@solidjs/start/server';
import { AppConfig } from '@/utils/AppConfig';

export default createHandler((event: PageEvent) => (
  <StartServer
    document={({ assets, children, scripts }) => (
      <html lang={event.locals.locale ?? AppConfig.i18n.defaultLocale}>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <link rel="icon" href="/favicon.ico" />
          {assets}
        </head>
        <body>
          <div id="app">{children}</div>
          {scripts}
        </body>
      </html>
    )}
  />
));
