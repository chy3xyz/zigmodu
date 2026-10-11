import { defineConfig } from 'vitepress';

// Source lives in the repository's `docs/` — no copy, no sync step. Editing a
// document is the whole workflow: the next `npm run build` picks it up.
export default defineConfig({
  title: 'ZigModu',
  description: 'Documentation for the ZigModu modular framework.',
  srcDir: '../docs',
  outDir: '../site/.vitepress/dist',
  // GitHub Pages project site (chy3xyz.github.io/zigmodu/). Every asset URL and
  // router base is prefixed with this, so it must match the repo name exactly.
  base: '/zigmodu/',
  lastUpdated: true,
  cleanUrls: true,
  // A dead link is a real defect, so the check stays on — but not for links
  // that climb out of `docs/`. The documents are written to be read *in the
  // repository*, where `../AGENTS` and `../src/data.zig` resolve; a site whose
  // source root is `docs/` alone cannot follow them anywhere. Those pass here
  // (65 of them when this was written). A link broken *within* docs/ still
  // fails the build — that one is a genuine defect, not a repository-relative
  // path that only GitHub can resolve.
  //
  // VitePress takes an array here, and a function is one of the allowed entries.
  // The URL arrives prefixed (`./../AGENTS`), so match on the climb itself
  // rather than on a prefix that the `./` would hide.
  ignoreDeadLinks: [(url) => url.includes('../')],

  markdown: {
    // Two fences name languages Shiki does not ship, and each one logged a
    // "not loaded, falling back to 'txt'" warning per block on every build.
    //
    // `zon` is Zig's own object notation — a strict subset of Zig syntax, so the
    // Zig grammar highlights it correctly rather than approximately.
    //
    // `promql` has no Shiki grammar at all. PromQL is a query language with
    // SQL's shape (functions, aggregates, ranges), so the SQL grammar is the
    // closest honest fit: identifiers, numbers and durations highlight, and
    // nothing claims to be exact that is not. Worth a custom grammar someday,
    // but four code blocks do not justify carrying a vendored TextMate
    // definition for them.
    languageAlias: {
      zon: 'zig',
      promql: 'sql',
    },
  },

  themeConfig: {
    nav: [
      { text: 'Docs', link: '/README' },
      { text: 'Repository', link: 'https://github.com/chy3xyz/zigmodu' },
    ],
    sidebar: [
      {
        text: 'Start here',
        items: [
          { text: 'Quick Start', link: '/guide/QUICK-START' },
          { text: 'Architecture', link: '/reference/ARCHITECTURE' },
          { text: 'zmodu CLI', link: '/guide/ZMODU_CLI_INTEGRATION' },
        ],
      },
      {
        text: 'Core specifications',
        items: [
          { text: 'Runtime', link: '/reference/RUNTIME' },
          { text: 'Distributed', link: '/reference/DISTRIBUTED' },
          { text: 'Architecture (full)', link: '/reference/ARCHITECTURE' },
          { text: 'API Reference', link: '/reference/API' },
          { text: 'API Freeze', link: '/reference/API_FREEZE' },
          { text: 'Module Layers', link: '/guide/MODULE_LAYERS' },
          { text: 'Events & DI', link: '/guide/EVENTS_DI' },
          { text: 'Workflow', link: '/guide/WORKFLOW' },
          { text: 'Modulith', link: '/guide/MODULITH' },
        ],
      },
      {
        text: 'Routing & auth',
        items: [
          { text: 'Route Table', link: '/reference/ROUTE_TABLE' },
          { text: 'Cluster Quick Start', link: '/guide/CLUSTER-QUICKSTART' },
        ],
      },
      {
        text: 'Data',
        items: [
          { text: 'SQLx Drivers', link: '/guide/SQLX_DRIVERS' },
          { text: 'Architecture (data)', link: '/reference/ARCHITECTURE' },
        ],
      },
      {
        text: 'AI (optional)',
        items: [
          { text: 'AI Chat', link: '/ai/AI' },
          { text: 'AI Dev Guide', link: '/ai/AI_DEV_GUIDE' },
          { text: 'AI Skills', link: '/ai/AI_SKILLS' },
          { text: 'AI Orchestration', link: '/ai/AI_ORCHESTRATION' },
          { text: 'LLM Policies', link: '/ai/LLM_POLICIES' },
          { text: 'MCP bridge', link: '/ai/MCP' },
          { text: 'Agent Runtime', link: '/reference/AGENT_RUNTIME' },
          { text: 'AI Boundary', link: '/reference/AI_BOUNDARY' },
        ],
      },
      {
        text: 'Ops & observability',
        items: [
          { text: 'Observability', link: '/reference/OBSERVABILITY' },
          { text: 'Logging', link: '/guide/LOGGING' },
        ],
      },
      {
        text: 'Patterns',
        items: [
          { text: 'Best Practices', link: '/guide/BEST_PRACTICES' },
          { text: 'ZigModu × zent', link: '/reference/ZENT' },
          { text: 'Tenant Shop Blueprint', link: '/guide/MODULITH_TENANT_SHOP' },
          { text: 'Web4', link: '/reference/WEB4' },
          { text: 'Upgrading', link: '/reference/UPGRADING' },
        ],
      },
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/chy3xyz/zigmodu' },
    ],
    search: { provider: 'local' },
  },
});
