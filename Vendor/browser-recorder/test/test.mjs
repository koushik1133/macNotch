// End-to-end test of the Browser Task Recorder runner (headless, local pages only).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import os from 'node:os';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RUNNER = path.join(HERE, '..', 'runner.mjs');
const NODE = process.execPath;
const { startRecording } = await import(RUNNER);

const log = (...a) => console.log('[test]', ...a);
let variant = 'v1';
const submissions = [];
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/submit') { submissions.push({ variant, ...Object.fromEntries(u.searchParams) }); res.end('ok'); return; }
  const file = path.join(HERE, 'site', variant, u.pathname === '/' ? 'index.html' : u.pathname);
  if (!fs.existsSync(file)) { res.statusCode = 404; res.end('nf'); return; }
  res.setHeader('content-type', 'text/html'); res.end(fs.readFileSync(file));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const BASE = `http://127.0.0.1:${server.address().port}`;
const out = process.env.BR_TEST_OUT || fs.mkdtempSync(path.join(os.tmpdir(), 'br-test-'));
fs.mkdirSync(out, { recursive: true });
log('output in', out);
const profile = path.join(out, 'profile');
const assert = (c, m) => { if (!c) { console.error('ASSERT FAILED:', m); process.exitCode = 1; throw new Error(m); } else log('ok -', m); };
const SECRET = 'Hunter2-SuperSecret!';

// ---------------------------------------------------------------- 1. record
const events = [];
const rec = await startRecording({ profile, url: BASE + '/index.html', headless: true, emit: (e) => events.push(e) });
const page = rec.page;
await page.waitForSelector('#email');
// sensitive-field detection beyond type=password (value never read)
const sens = await page.evaluate(() => ['api_key', 'recovery-code', 'email'].map((n) => { const i = document.createElement('input'); i.name = n; return window.__nir.sensitivity(i); }));
await page.click('#email');
await page.keyboard.type('alice@example.com', { delay: 10 });
await page.click('#pw');
await page.keyboard.type(SECRET, { delay: 5 });
// trusted keyboard selection on the <select>
await page.click('#plan');            // user opens the menu (trusted pointerdown)
await page.selectOption('#plan', 'team'); // and picks an option
await page.click('[name=ref]');
await page.keyboard.type('FRIEND10');
await page.click('#agree');
await page.locator('#avatar').setInputFiles(path.join(HERE, 'avatar.png'));
await page.mouse.wheel(0, 400); await page.waitForTimeout(900);
await page.click('#submit-btn');
await page.waitForURL(/welcome/);
await page.waitForSelector('#again');
await page.click('#again');
await page.waitForURL(/index/);
await page.waitForSelector('h1');
await page.waitForTimeout(300);
// in-page overlay: "Wait for element" pick mode, then Stop
await page.locator('nir-recorder-overlay #wait').click();
await page.click('h1');
await page.waitForTimeout(200);
await page.locator('nir-recorder-overlay #stop').click();
const flow = await rec.stopped;
assert(sens[0] === 'secret' && sens[1] === 'secret' && sens[2] === null, `API key / recovery code fields are treated as secrets (${sens})`);
assert(events.find((e) => e.type === 'flow')?.reason === 'overlay', 'overlay Stop button ends the recording');
assert(flow.steps.at(-1).type === 'waitFor' && /Create your Acme account/.test(flow.steps.at(-1).title), `overlay pick mode recorded a waitFor step (${flow.steps.at(-1).title})`);
assert(!flow.steps.some((s) => s.type === 'click' && /Acme account/.test(s.title)), 'pick-mode click was not recorded as a click');
fs.writeFileSync(path.join(out, 'flow.recorded.json'), JSON.stringify(flow, null, 2));
log('recorded steps:', flow.steps.map((s) => `${s.type}:${s.title}`).join(' | '));
const raw = JSON.stringify(flow);
assert(!raw.includes(SECRET) && !raw.includes('Hunter2'), 'password value never stored');
const pwStep = flow.steps.find((s) => s.masked);
assert(pwStep && pwStep.value === '{{password}}', 'password step masked as {{password}}');
const types = flow.steps.map((s) => s.type);
for (const t of ['navigate', 'fill', 'select', 'check', 'upload', 'scroll', 'click']) assert(types.includes(t), `recorded a ${t} step`);
const emailStep = flow.steps.find((s) => s.type === 'fill' && s.value === 'alice@example.com');
assert(emailStep, 'email typing coalesced into one fill step');
assert(emailStep.selectors[0].kind === 'role' || emailStep.selectors[0].kind === 'label', `email first selector is user-facing (${emailStep.selectors[0].kind})`);
const btn = flow.steps.find((s) => s.type === 'click' && /Create account/.test(s.title));
assert(btn && btn.selectors.length >= 3, `button has ${btn?.selectors.length} selector candidates: ${btn?.selectors.map((s) => s.kind).join(',')}`);
assert(!types.slice(1).includes('navigate') || flow.steps.filter((s) => s.type === 'navigate').length === 1, 'navigations caused by clicks are not recorded as extra steps');

// ---------------------------------------------------------------- 2. edit (what the Swift editor does)
emailStep.value = '{{email}}';
const upload = flow.steps.find((s) => s.type === 'upload');
upload.value = '{{file}}';
flow.steps.splice(flow.steps.indexOf(btn) + 1, 0, { id: 'wait-1', type: 'waitText', value: 'Signed up as', title: 'Wait for confirmation', selectors: [] });
flow.steps.splice(1, 0, { id: 'delay-1', type: 'delay', ms: 200, title: 'Delay 0.2 s', selectors: [] });
flow.name = 'Acme signup';
const flowPath = path.join(out, 'flow.json');
fs.writeFileSync(flowPath, JSON.stringify(flow, null, 2));

// ---------------------------------------------------------------- 3. replay helper (real CLI + JSON lines)
function replay(args, vars) {
  return new Promise((resolve) => {
    const p = spawn(NODE, [RUNNER, 'replay', '--flow', flowPath, '--profile', profile, '--headless', '--shots', path.join(out, 'shots'), '--step-timeout', '4000', '--vars-stdin', ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
    p.stdin.write(JSON.stringify({ vars }) + '\n');
    const evs = []; let buf = '';
    p.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); try { evs.push(JSON.parse(l)); } catch { console.log('non-json:', l); } } });
    p.stderr.on('data', (d) => process.stderr.write(d));
    p.on('exit', (code) => { p.stdin.end(); resolve({ code, evs }); });
  });
}
const vars = { email: 'bob@example.com', password: 'pw-from-stdin', file: path.join(HERE, 'avatar.png') };
const summary = (r) => r.evs.filter((e) => ['healed', 'stepFailed', 'done', 'error'].includes(e.type)).map((e) => e.type === 'healed' ? `healed#${e.index} via ${e.via}${e.score ? ' ' + e.score : ''}` : e.type === 'stepFailed' ? `FAILED#${e.index} ${e.message}` : e.type === 'done' ? `done ok=${e.ok} healed=${e.healed}` : `error ${e.code}`).join('\n   ');

for (const v of ['v1', 'v2', 'v3']) {
  variant = v; submissions.length = 0;
  const r = await replay([], vars);
  log(`replay on ${v}:\n   ${summary(r)}`);
  const done = r.evs.find((e) => e.type === 'done');
  assert(done && done.ok, `${v}: replay succeeded`);
  assert(submissions.length === 1 && submissions[0].email === 'bob@example.com' && submissions[0].plan === 'team' && submissions[0].agree === 'true' && submissions[0].file === 'avatar.png' && submissions[0].ref === 'FRIEND10' && submissions[0].pwlen === String(vars.password.length), `${v}: form submitted with replayed values ${JSON.stringify(submissions[0])}`);
  const healed = r.evs.filter((e) => e.type === 'healed');
  if (v === 'v1') assert(healed.length === 0, 'v1: no healing needed');
  else assert(healed.some((h) => h.index === flow.steps.indexOf(btn)), `${v}: renamed button was healed (${healed.map((h) => h.via).join(',')})`);
  if (v === 'v3') assert(healed.some((h) => h.via === 'fuzzy'), 'v3: fuzzy fingerprint matching used after DOM restructure');
  fs.writeFileSync(path.join(out, `events.${v}.jsonl`), r.evs.map((e) => JSON.stringify(e)).join('\n'));
}

// ---------------------------------------------------------------- 4. CSV loop
variant = 'v3'; submissions.length = 0;
const csv = path.join(out, 'rows.csv');
fs.writeFileSync(csv, 'email,password\ncarol@example.com,"p,1"\n"dave ""d"" @example.com",p2\n');
const rc = await replay(['--csv', csv], { file: vars.file });
log(`csv replay:\n   ${summary(rc)}`);
assert(rc.evs.find((e) => e.type === 'done')?.ok && submissions.map((s) => s.email).join('|') === 'carol@example.com|dave "d" @example.com', `CSV: two rows submitted (${submissions.map((s) => s.email).join('|')})`);

// ---------------------------------------------------------------- 5. missing variable
const rm = await replay([], { email: 'x@y.z' });
assert(rm.evs.some((e) => e.type === 'error' && e.code === 'missingVariables'), `missing {{password}}/{{file}} refused before launching (${rm.evs.find((e) => e.code)?.message})`);

// ---------------------------------------------------------------- 6. failure + screenshot
variant = 'v4';
const rf = await replay([], vars);
const failed = rf.evs.find((e) => e.type === 'stepFailed');
log(`v4 replay:\n   ${summary(rf)}`);
assert(failed && failed.screenshot && fs.existsSync(failed.screenshot), `v4: step failed cleanly with screenshot ${failed?.screenshot}`);
assert(rf.code === 1, 'v4: exit code 1');

// ---------------------------------------------------------------- 7. risky words
const risky = { ...flow, name: 'Delete all invoices' };
fs.writeFileSync(flowPath, JSON.stringify(risky));
variant = 'v1';
const rr = await replay([], vars);
assert(rr.evs.some((e) => e.type === 'error' && e.code === 'needsConfirmation'), 'risky flow refused without --allow-risky');
const rr2 = await replay(['--allow-risky'], vars);
assert(rr2.evs.find((e) => e.type === 'done')?.ok, 'risky flow runs with --allow-risky (after user confirmation)');


// ---------------------------------------------------------------- 8. new tab (popup) steps
variant = 'v1'; submissions.length = 0;
const rec2 = await startRecording({ profile: path.join(out, 'profile2'), url: BASE + '/popup.html', headless: true, emit: () => {} });
const [popupPage] = await Promise.all([rec2.page.context().waitForEvent('page'), rec2.page.click('#open-help')]);
await popupPage.waitForLoadState('domcontentloaded');
await popupPage.click('text=Got it');
await popupPage.waitForTimeout(300);
const flow2 = await rec2.stop('test');
assert(flow2.steps.some((s) => s.type === 'click' && s.pageIndex === 1), 'click in the new tab recorded with pageIndex 1 (' + flow2.steps.map((s) => s.type + '@' + s.pageIndex).join(',') + ')');
fs.writeFileSync(flowPath, JSON.stringify(flow2));
submissions.length = 0;
const rp = await replay([], {});
assert(rp.evs.find((e) => e.type === 'done')?.ok && submissions.some((s) => s.popup === 'clicked'), 'replay follows the new tab and clicks inside it');

// ---------------------------------------------------------------- 9. replay from a step (--from)
fs.writeFileSync(flowPath, JSON.stringify(flow));
variant = 'v1'; submissions.length = 0;
const fromStep = flow.steps.find((s) => s.type === 'fill' && /Referral/.test(s.title));
const rfrom = await replay(['--from', fromStep.id], { file: vars.file });
const startEv = rfrom.evs.find((e) => e.type === 'start');
assert(rfrom.evs.find((e) => e.type === 'done')?.ok && submissions.length === 1 && submissions[0].email === '' && submissions[0].ref === 'FRIEND10',
  `--from skips earlier steps, opens the step's page and needs only later variables (${startEv?.steps} steps, ${JSON.stringify(submissions[0])})`);

// ---------------------------------------------------------------- 10. stop during a long wait
const slowFlow = { schema: 1, id: 'slow', name: 'Slow', steps: [
  { id: 'n', type: 'navigate', url: BASE + '/index.html', pageIndex: 0, selectors: [] },
  { id: 'w', type: 'waitText', value: 'This text never appears', timeout: 60000, selectors: [] }] };
fs.writeFileSync(flowPath, JSON.stringify(slowFlow));
const shotsBefore = fs.existsSync(path.join(out, 'shots')) ? fs.readdirSync(path.join(out, 'shots')).length : 0;
const stopRun = await new Promise((resolve) => {
  const p = spawn(NODE, [RUNNER, 'replay', '--flow', flowPath, '--profile', profile, '--headless', '--shots', path.join(out, 'shots')], { stdio: ['pipe', 'pipe', 'inherit'] });
  const evs = []; let buf = ''; let stopAt = 0;
  p.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const e = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1); e.at = Date.now(); evs.push(e);
    if (e.type === 'stepStart' && e.stepId === 'w') setTimeout(() => { stopAt = Date.now(); p.stdin.write('{"cmd":"stop"}\n'); }, 800); } });
  p.on('exit', (code) => resolve({ code, evs, ms: (evs.find((e) => e.type === 'stopped')?.at ?? Date.now()) - stopAt, exitMs: Date.now() - stopAt }));
});
const stopDone = stopRun.evs.find((e) => e.type === 'done');
assert(stopDone?.stopped === true && !stopRun.evs.some((e) => e.type === 'stepFailed' || e.type === 'retry') && stopRun.ms < 1500 && stopRun.exitMs < 30000,
  `stop abandons a 60 s wait promptly (stopped after ${stopRun.ms} ms, browser closed and exited after ${stopRun.exitMs} ms) without failure/retry events`);
const shotsAfter = fs.existsSync(path.join(out, 'shots')) ? fs.readdirSync(path.join(out, 'shots')).length : 0;
assert(shotsAfter === shotsBefore, 'no failure screenshot for a user stop');

server.close();
log(process.exitCode ? 'SOME TESTS FAILED' : 'ALL TESTS PASSED');
