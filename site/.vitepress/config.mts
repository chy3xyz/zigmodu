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
          { text: 'Quick Start', link: '/QUICK-START' },
          { text: 'Architecture', link: '/ARCHITECTURE' },
          { text: 'zmodu CLI', link: '/ZMODU_CLI_INTEGRATION' },
        ],
      },
      {
        text: 'Core specifications',
        items: [
          { text: 'Runtime', link: '/RUNTIME' },
          { text: 'Distributed', link: '/DISTRIBUTED' },
          { text: 'Architecture (full)', link: '/ARCHITECTURE' },
          { text: 'API Reference', link: '/API' },
          { text: 'API Freeze', link: '/API_FREEZE' },
          { text: 'Module Layers', link: '/MODULE_LAYERS' },
          { text: 'Events & DI', link: '/EVENTS_DI' },
          { text: 'Workflow', link: '/WORKFLOW' },
          { text: 'Modulith', link: '/MODULITH' },
        ],
      },
      {
        text: 'Routing & auth',
        items: [
          { text: 'Route Table', link: '/ROUTE_TABLE' },
          { text: 'Cluster Quick Start', link: '/CLUSTER-QUICKSTART' },
        ],
      },
      {
        text: 'Data',
        items: [
          { text: 'SQLx Drivers', link: '/SQLX_DRIVERS' },
          { text: 'Architecture (data)', link: '/ARCHITECTURE' },
        ],
      },
      {
        text: 'AI (optional)',
        items: [
          { text: 'AI Chat', link: '/AI' },
          { text: 'AI Dev Guide', link: '/AI_DEV_GUIDE' },
          { text: 'AI Skills', link: '/AI_SKILLS' },
          { text: 'AI Orchestration', link: '/AI_ORCHESTRATION' },
          { text: 'LLM Policies', link: '/LLM_POLICIES' },
          { text: 'MCP bridge', link: '/MCP' },
          { text: 'Agent Runtime', link: '/AGENT_RUNTIME' },
          { text: 'AI Methodology', link: '/AI_METHODOLOGY' },
          { text: 'AI Boundary', link: '/AI_BOUNDARY' },
        ],
      },
      {
        text: 'Ops & observability',
        items: [
          { text: 'Observability', link: '/OBSERVABILITY' },
          { text: 'Logging', link: '/LOGGING' },
          { text: 'Production Roadmap', link: '/PRODUCTION_ROADMAP' },
          { text: 'Framework Backlog', link: '/FRAMEWORK_BACKLOG' },
        ],
      },
      {
        text: 'Patterns',
        items: [
          { text: 'Best Practices', link: '/BEST_PRACTICES' },
          { text: 'Elegant Code Patterns', link: '/elegant-code-patterns' },
          { text: 'Heysen Lessons', link: '/best-practices-heysen-lessons' },
          { text: 'ZigModu × zent', link: '/ZENT' },
          { text: 'Tenant Shop Blueprint', link: '/MODULITH_TENANT_SHOP' },
          { text: 'Web4', link: '/WEB4' },
          { text: 'Upgrading', link: '/UPGRADING' },
        ],
      },
      {
        text: 'Status & history',
        items: [
          { text: 'Evaluation (current)', link: '/EVALUATION_2026-10' },
          { text: 'Field Notes', link: '/ZIGMODU_NOTES' },
          { text: 'Issues from zapi', link: '/ISSUES_FROM_ZAPI' },
          { text: 'Issues from zigshop', link: '/ISSUES_FROM_ZIGSHOP' },
        ],
      },
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/chy3xyz/zigmodu' },
    ],
    search: { provider: 'local' },
  },
});
