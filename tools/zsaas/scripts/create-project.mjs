#!/usr/bin/env node
// zsaas one-click project creator — scaffold BOTH sides from one model:
//   1. zigmodu backend project  (zmodu new + zmodu saas business modules)
//   2. SolidStart frontend      (saas-solidjs template copy + gen-business pages)
//
// Usage:
//   node zsaas/scripts/create-project.mjs <model.json> [options]
//
// Options:
//   --name <app>               backend project name (default: saas-app)
//   --backend <dir>            backend project dir  (default: ./<name>-backend)
//   --frontend <dir>           frontend project dir (default: ./<name>-frontend)
//   --zmodu <path>             zmodu CLI binary (default: zigmodu repo zig-out/bin/zmodu)
//   --frontend-template <path> saas-solidjs template dir (default: $ZSAAS_START_PATH
//                              or ~/w4_proj/dev_machine/saas_admin_ui/zsaas-start)
//   --skip-backend | --skip-frontend
//   --help

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..');
const DEFAULT_TEMPLATE = path.join(os.homedir(), 'w4_proj/dev_machine/saas_admin_ui/zsaas-start');

function args(processArgs) {
  const out = { name: 'saas-app', backend: null, frontend: null, zmodu: null, template: process.env.ZSAAS_START_PATH ?? DEFAULT_TEMPLATE, skipBackend: false, skipFrontend: false, help: false, model: null };
  const rest = [...processArgs];
  while (rest.length) {
    const a = rest.shift();
    if (a === '--help' || a === '-h') out.help = true;
    else if (a === '--name') out.name = rest.shift();
    else if (a === '--backend') out.backend = rest.shift();
    else if (a === '--frontend') out.frontend = rest.shift();
    else if (a === '--zmodu') out.zmodu = rest.shift();
    else if (a === '--frontend-template') out.template = rest.shift();
    else if (a === '--skip-backend') out.skipBackend = true;
    else if (a === '--skip-frontend') out.skipFrontend = true;
    else if (a.startsWith('-')) { console.error(`unknown option: ${a}`); process.exit(2); }
    else if (!out.model) out.model = a;
    else { console.error(`unexpected argument: ${a}`); process.exit(2); }
  }
  return out;
}

function run(bin, argv, cwd) {
  return execFileSync(bin, argv, cwd ? { cwd, stdio: 'inherit' } : { stdio: 'inherit' });
}

function main() {
  const o = args(process.argv.slice(2));
  if (o.help || !o.model) {
    console.log(`usage: node zsaas/scripts/create-project.mjs <model.json> [options]

One-click SaaS project creator — generates BOTH:
  1. a zigmodu backend project (zmodu new + zmodu saas business modules)
  2. a SolidStart frontend project (saas-solidjs template + gen-business pages)

Options:
  --name <app>               backend project name (default: saas-app)
  --backend <dir>            backend project dir  (default: ./<name>-backend)
  --frontend <dir>           frontend project dir (default: ./<name>-frontend)
  --zmodu <path>             zmodu CLI binary (default: zigmodu repo zig-out/bin/zmodu)
  --frontend-template <path> saas-solidjs template dir (default: $ZSAAS_START_PATH
                             or ~/w4_proj/dev_machine/saas_admin_ui/zsaas-start)
  --skip-backend | --skip-frontend
  --help`);
    process.exit(o.help ? 0 : 2);
  }

  const modelPath = path.resolve(o.model);
  if (!fs.existsSync(modelPath)) {
    console.error(`model not found: ${modelPath}`);
    process.exit(1);
  }

  const backendDir = path.resolve(o.backend ?? `./${o.name}-backend`);
  const frontendDir = path.resolve(o.frontend ?? `./${o.name}-frontend`);

  // ── 1. Backend ──────────────────────────────────────────────────────────
  if (!o.skipBackend) {
    let zmodu = o.zmodu ?? path.join(REPO_ROOT, 'zig-out', 'bin', 'zmodu');
    if (!fs.existsSync(zmodu)) {
      console.log('[zsaas] building zmodu CLI...');
      run('zig', ['build'], REPO_ROOT);
      zmodu = path.join(REPO_ROOT, 'zig-out', 'bin', 'zmodu');
    }
    if (fs.existsSync(backendDir)) {
      console.error(`backend dir already exists: ${backendDir}`);
      process.exit(1);
    }
    console.log(`[zsaas] backend: zmodu new ${o.name} -> ${backendDir}`);
    // Build in a temp sibling dir (same filesystem) so the project always
    // lands at the requested backendDir without colliding with leftovers.
    const parent = path.dirname(backendDir);
    fs.mkdirSync(parent, { recursive: true });
    const tmpParent = fs.mkdtempSync(path.join(parent, '.zsaas-new-'));
    run(zmodu, ['new', o.name], tmpParent);
    fs.renameSync(path.join(tmpParent, o.name), backendDir);
    fs.rmdirSync(tmpParent);
    if (!fs.existsSync(path.join(backendDir, 'build.zig.zon'))) {
      console.error(`backend project missing build.zig.zon at ${backendDir}`);
      process.exit(1);
    }
    // Point the zigmodu dependency at the local framework repo (zmodu new
    // scaffolds a stale tag URL with a placeholder hash).
    const zonPath = path.join(backendDir, 'build.zig.zon');
    const zon = fs.readFileSync(zonPath, 'utf8');
    const rel = path.relative(fs.realpathSync(backendDir), fs.realpathSync(REPO_ROOT)) || '.';
    const patched = zon.replace(/\.zigmodu = \.\{[^}]*\},/, `.zigmodu = .{ .path = "${rel}" },`);
    fs.writeFileSync(zonPath, patched);
    console.log(`[zsaas] backend: zigmodu dependency -> ${rel}`);
    run(zmodu, ['saas', modelPath, '--out', path.join(backendDir, 'src', 'modules')]);
    console.log(`[zsaas] backend done: ${backendDir}`);
  }

  // ── 2. Frontend ─────────────────────────────────────────────────────────
  if (!o.skipFrontend) {
    const tpl = o.template;
    if (!fs.existsSync(tpl)) {
      console.error(`frontend template not found: ${tpl}
  set ZSAAS_START_PATH or pass --frontend-template <saas-solidjs dir>
  (e.g. git clone https://github.com/chy3xyz/saas-solidjs)`);
      process.exit(1);
    }
    if (fs.existsSync(frontendDir)) {
      console.error(`frontend dir already exists: ${frontendDir}`);
      process.exit(1);
    }
    const skip = new Set(['node_modules', '.git', '.output', 'test-results', '.data', '.DS_Store', '.zig-cache']);
    fs.cpSync(tpl, frontendDir, {
      recursive: true,
      filter: (src) => !skip.has(path.basename(src)),
    });
    console.log(`[zsaas] frontend: copied template -> ${frontendDir}`);
    run(process.execPath, [path.join(__dirname, 'gen-business.mjs'), modelPath, frontendDir]);
    console.log(`[zsaas] frontend done: ${frontendDir}`);
  }

  // ── Summary ─────────────────────────────────────────────────────────────
  console.log(`
== zsaas project created ==
backend : ${o.skipBackend ? '(skipped)' : backendDir}
frontend: ${o.skipFrontend ? '(skipped)' : frontendDir}

backend wiring (docs/ROUTE_TABLE.md §7):
  cd ${backendDir}
  - mount modules with jwtAuthFromCatalogWithPermissions + permissionGateWith(.rbac)
    + Router.scope.mountAll (see examples/tenant-mgmt for a reference app)
  - apply schema: src/modules/saas-schema.sql (each entity is org-scoped)
  zig build && zig build run

frontend:
  cd ${frontendDir}
  npm install
  cp .env.example .env
  export PUBLIC_ZMODU_API_URL=http://127.0.0.1:8080   # zigmodu backend
  export ZMODU_API_TOKEN='<a zigmodu JWT>'            # dev; production: session exchange
  npm run dev                                          # /dashboard/<entities>
`);
}

main();
