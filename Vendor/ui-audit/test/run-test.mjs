// Self-check for the UI audit runner. Serves the planted-issue fixture site
// on 127.0.0.1, runs the audit headless twice and asserts:
//   1. local host (127.0.0.1, submission allowed): every planted issue is found;
//   2. "remote" host ([::ffff:127.0.0.1], not a test host, submission off):
//      no POST reaches the server, page-initiated writes are blocked.
// In both runs: /logout and /account/delete are never requested, the
// external link is never visited, and dangerous buttons are never clicked.
// Usage: node test/run-test.mjs   (exit code 0 = all passed)
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const AUDIT = path.join(HERE, '..', 'audit.mjs');
const PORT = 4900 + Math.floor(Math.random() * 90);
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ui-audit-test-'));

function run(cmd, args) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('close', (code) => resolve({ code, out, err }));
  });
}

const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok, detail }); };

async function audit(url, outDir) {
  const r = await run(process.execPath, [AUDIT, '--url', url, '--mode', 'full', '--headless', '--max-pages', '10', '--rate-ms', '200', '--out', outDir]);
  if (r.code !== 0) throw new Error(`audit exited ${r.code}: ${r.err.slice(-500)}`);
  return JSON.parse(fs.readFileSync(path.join(outDir, 'report.json'), 'utf8'));
}

const has = (report, rule, page, selector) => report.findings.some((f) => (f.rule === rule || f.axeId === rule)
  && (!page || new URL(f.page).pathname === page || (f.alsoOn || []).some((p) => new URL(p).pathname === page))
  && (!selector || f.selector === selector));
const hits = (file) => fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));

const server = spawn(process.execPath, [path.join(HERE, 'server.mjs'), String(PORT), path.join(TMP, 'hits-local.jsonl')], { stdio: 'ignore' });
await new Promise((r) => setTimeout(r, 600));
try {
  // ---- Run 1: local host
  const local = await audit(`http://127.0.0.1:${PORT}/`, path.join(TMP, 'local'));
  const planted = [
    ['email type=text accepts "not-an-email"', 'field-accepts-invalid', '/signup', '#email'],
    ['tel field accepts letters', 'field-accepts-invalid', '/signup', '#phone'],
    ['email should be type=email', 'wrong-input-type', '/signup', '#email'],
    ['"*" marker without required', 'required-marker-not-enforced', '/signup', '#fullname'],
    ['placeholder says email on phone field', 'placeholder-misleading', '/signup', '#phone'],
    ['placeholder example fails pattern', 'placeholder-pattern-mismatch', '/signup', '#pin'],
    ['placeholder used as label', 'placeholder-as-label', '/signup', 'input[name="city"]'],
    ['pattern without format hint', 'format-hint-missing', '/signup', '#ref'],
    ['valid submit returns 500', 'submit-server-error', '/signup', null],
    ['novalidate form sends empty required fields', 'empty-required-submitted', '/contact', '#contact'],
    ['url field invalid, no feedback (novalidate)', 'validation-no-feedback', '/contact', '#cweb'],
    ['vague "Invalid" message', 'validation-vague-message', '/contact', '#cemail'],
    ['error message not associated', 'validation-message-not-associated', '/contact', '#cemail'],
    ['axe: image-alt', 'image-alt', '/', null],
    ['axe: color-contrast', 'color-contrast', '/a11y', null],
    ['axe: button-name', 'button-name', '/a11y', '#iconbtn'],
    ['axe: label (input without name)', 'label', '/a11y', '#noname'],
    ['axe: html-has-lang', 'html-has-lang', '/a11y', null],
    ['broken link to /old-page', 'broken-link', '/', 'a[href="/old-page"]'],
    ['broken in-page anchor', 'broken-anchor', '/', null],
    ['broken image', 'img-broken', '/', null],
    ['console.error', 'console-error', '/', null],
    ['fetch 500', 'request-failed', '/', null],
    ['404 page', 'page-http-error', '/old-page', null],
    ['horizontal overflow (390 and 1440)', 'horizontal-overflow', '/overflow', '#pricing-table'],
    ['clipped text', 'text-clipped', '/a11y', '#cliptext'],
    ['overlapping text', 'text-overlap', '/a11y', '#ov1'],
    ['tiny tap target', 'tap-target-small', '/a11y', '#tiny'],
    ['outline:none focus', 'focus-not-visible', '/a11y', '#iconbtn'],
    ['keyboard trap', 'keyboard-trap', '/a11y', '#trap'],
    ['positive tabindex', 'positive-tabindex', '/a11y', null],
    ['clickable div not focusable', 'clickable-not-focusable', '/a11y', '#fakelink'],
    ['dead button', 'dead-button', '/buttons', '#dead'],
    ['dead href="#" link', 'dead-button', '/buttons', '#deadlink'],
  ];
  for (const [name, rule, page, sel] of planted) check(`found: ${name}`, has(local, rule, page, sel), `${rule} ${page} ${sel || ''}`);
  check('no false keyboard trap on date input', !has(local, 'keyboard-trap', '/signup', '#dob'));
  check('working toggle button not reported dead', !has(local, 'dead-button', '/buttons', '#works'));
  check('card number field left empty', local.safety.sensitiveFields.some((s) => s.selector === '#card'));
  check('dangerous buttons skipped', ['Delete my account', 'Pay now', 'Remove account'].every((t) => local.safety.skippedDangerous.some((d) => d.text === t)));
  check('external link not visited', local.safety.externalLinks.some((l) => l.includes('external.example.org')));
  const h1 = hits(path.join(TMP, 'hits-local.jsonl'));
  check('local: /logout never requested', !h1.some((h) => h.path === '/logout'));
  check('local: /account/delete never requested', !h1.some((h) => h.path === '/account/delete'));
  check('local: valid signup was submitted', h1.some((h) => h.method === 'POST' && h.path === '/api/signup'));
  check('screenshots written', local.findings.filter((f) => f.screenshot).every((f) => fs.existsSync(path.join(TMP, 'local', f.screenshot))));

  // ---- Run 2: non-test host, submission off
  fs.writeFileSync(path.join(TMP, 'hits-local.jsonl'), '');
  const remote = await audit(`http://[::ffff:127.0.0.1]:${PORT}/`, path.join(TMP, 'remote'));
  const h2 = hits(path.join(TMP, 'hits-local.jsonl'));
  check('remote: submission policy is off', /^off/.test(remote.meta.submitPolicy), remote.meta.submitPolicy);
  check('remote: no POST reached the server', !h2.some((h) => h.method !== 'GET' && h.method !== 'HEAD'), JSON.stringify(h2.filter((h) => h.method === 'POST')));
  check('remote: page-initiated POST was blocked', remote.safety.blocked.some((b) => b.method === 'POST'));
  check('remote: /logout never requested', !h2.some((h) => h.path === '/logout'));
  check('remote: forms still validated (email accepts invalid)', has(remote, 'field-accepts-invalid', '/signup', '#email'));
} catch (e) {
  check('runner completed', false, e.message);
} finally {
  server.kill();
}

let failed = 0;
for (const r of results) {
  if (!r.ok) failed++;
  console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.ok ? '' : `  (${r.detail})`}`);
}
console.log(`\n${results.length - failed}/${results.length} passed · reports in ${TMP}`);
process.exit(failed ? 1 : 0);
