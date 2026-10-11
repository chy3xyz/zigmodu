#!/usr/bin/env node
// zsaas generator self-check: run the generator against the example model
// into a temp dir and assert the produced module shape (no zsaas-start needed).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'zsaas-gen-'));

// Minimal project skeleton so the generator can patch nav/i18n/schema.
fs.mkdirSync(path.join(tmp, 'src/models'), { recursive: true });
fs.mkdirSync(path.join(tmp, 'src/libs'), { recursive: true });
fs.mkdirSync(path.join(tmp, 'src/routes/dashboard'), { recursive: true });
fs.mkdirSync(path.join(tmp, 'src/locales'), { recursive: true });
fs.writeFileSync(path.join(tmp, 'src/models/Schema.ts'), 'export const organizations = {} as never;\n');
fs.writeFileSync(
  path.join(tmp, 'src/routes/dashboard.tsx'),
  'const nav = [{ href: \'/dashboard/members\', label: \'x\' }];\n',
);
fs.writeFileSync(path.join(tmp, 'src/locales/en.json'), '{"DashboardLayout":{}}\n');
fs.writeFileSync(path.join(tmp, 'src/locales/zh.json'), '{"DashboardLayout":{}}\n');

execFileSync('node', [path.join(root, 'scripts/gen-business.mjs'), path.join(root, 'examples/orders.model.json'), tmp], { stdio: 'pipe' });

const expected = [
  'src/libs/zmoduApi.ts',
  'src/business/orders/index.ts',
  'src/routes/dashboard/orders/index.tsx',
  'src/routes/dashboard/orders/new.tsx',
  'src/routes/dashboard/orders/[id].tsx',
];
for (const f of expected) {
  if (!fs.existsSync(path.join(tmp, f))) {
    console.error(`MISSING ${f}`);
    process.exit(1);
  }
}

const dash = fs.readFileSync(path.join(tmp, 'src/routes/dashboard.tsx'), 'utf8');
if (!dash.includes('/dashboard/orders')) throw new Error('nav not patched');
const en = JSON.parse(fs.readFileSync(path.join(tmp, 'src/locales/en.json'), 'utf8'));
if (!en.OrdersPage || en.DashboardLayout.orders !== 'Orders') throw new Error('i18n not patched');
const actions = fs.readFileSync(path.join(tmp, 'src/business/orders/index.ts'), 'utf8');
if (!actions.includes("zmoduFetch('/orders'")) throw new Error('actions do not call the zigmodu REST API');

console.log('zsaas generator self-check OK');
