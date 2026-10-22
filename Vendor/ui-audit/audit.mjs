#!/usr/bin/env node
// SparkV UI / frontend audit runner.
//
// Opens a visible Chromium window (Playwright), crawls the user's own site
// breadth-first inside the allowed origins, and audits each page: forms
// (fills synthetic, type-correct test data and probes validation),
// accessibility (axe-core), console errors, failed requests, broken links,
// images, layout overflow at 1440/390, clipped/overlapping text, tap
// targets, keyboard focus, and dead buttons. Progress is streamed on stdout
// as JSON lines; report.json / report.md / report.html and screenshots go to
// the output directory.
//
// Usage:
//   node audit.mjs --config run.json [--stdin-control]
//   node audit.mjs --url http://localhost:3000 [--mode full|ui|forms|a11y] [--max-pages 12]
//                  [--max-depth 3] [--allow-submit] [--allow-dangerous] [--headless] [--out DIR]
//                  [--allow-origin https://api.example.com]...
// stdin (one command per line): pause | resume | stop
//
// Safety: main-frame navigation outside the allowed origins is aborted;
// non-GET requests are aborted unless submission is allowed for the target
// host (always allowed on localhost / 127.0.0.1 / ::1 / *.localhost / *.test /
// *.local, otherwise only with --allow-submit) and the
// target is an allowed origin; destructive/financial controls (pay, checkout,
// delete, logout, transfer, ...) are never clicked unless --allow-dangerous;
// payment/bank/government-ID fields are never filled; passwords are generated
// test values; JS dialogs are dismissed; downloads are refused.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { chromium } from 'playwright-core';
import { installHelpers } from './lib/page-helpers.mjs';
import {
  inferPurpose, purposeFromText, compatiblePurposes, SENSITIVE, makeRandom, patternRegex,
  textValue, numberValue, dateValue, invalidProbe, fixtureFor,
} from './lib/testdata.mjs';
import { RULES, axeSeverity } from './lib/rules.mjs';
import { writeReport, summarize, sortFindings } from './lib/report.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const FIXTURES = path.join(HERE, 'fixtures');
const VERSION = '0.1.0';

const MODES = {
  ui: { label: 'UI audit', checks: ['console', 'network', 'links', 'images', 'layout', 'tap', 'dead'] },
  forms: { label: 'Forms only', checks: ['console', 'network', 'forms'] },
  a11y: { label: 'Accessibility', checks: ['axe', 'images', 'keyboard', 'tap', 'formsStatic'] },
  full: { label: 'Full frontend', checks: ['console', 'network', 'links', 'images', 'layout', 'tap', 'keyboard', 'axe', 'forms', 'dead'] },
};

const DEFAULTS = {
  startURL: '', mode: 'full', maxPages: 12, maxDepth: 3, allowSubmit: false, allowDangerous: false,
  headless: false, rateLimitMs: 600, navTimeoutMs: 25000, maxRunSeconds: 900, maxScreenshots: 150,
  maxLinkChecks: 80, maxLinkChecksPerPage: 25, maxButtonsPerPage: 12, maxTabStops: 60, maxFormsPerPage: 4,
  allowedOrigins: [], outDir: '', executablePath: '', extraBrowserArgs: [], slowMoMs: 0,
  viewports: [{ width: 1440, height: 900, label: 'desktop' }, { width: 390, height: 844, label: 'mobile' }],
};

// ---------------------------------------------------------------------------
// Output

function emit(event) {
  try { process.stdout.write(JSON.stringify({ ...event, t: Date.now() }) + '\n'); } catch { /* stdout closed */ }
}
const log = (message, level = 'info') => emit({ type: 'log', level, message });

// ---------------------------------------------------------------------------
// Config

function parseArgs(argv) {
  const out = {};
  const extraOrigins = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case '--config': Object.assign(out, JSON.parse(fs.readFileSync(next(), 'utf8'))); break;
      case '--url': out.startURL = next(); break;
      case '--mode': out.mode = next(); break;
      case '--max-pages': out.maxPages = +next(); break;
      case '--max-depth': out.maxDepth = +next(); break;
      case '--allow-submit': out.allowSubmit = true; break;
      case '--allow-dangerous': out.allowDangerous = true; break;
      case '--headless': out.headless = true; break;
      case '--out': out.outDir = next(); break;
      case '--allow-origin': extraOrigins.push(next()); break;
      case '--rate-ms': out.rateLimitMs = +next(); break;
      case '--max-seconds': out.maxRunSeconds = +next(); break;
      case '--browser-arg': (out.extraBrowserArgs ||= []).push(next()); break;
      case '--stdin-control': out.stdinControl = true; break;
      default: if (a.startsWith('--')) throw new Error(`Unknown option ${a}`);
    }
  }
  if (extraOrigins.length) out.allowedOrigins = [...(out.allowedOrigins || []), ...extraOrigins];
  return out;
}

function loadConfig() {
  const cfg = { ...DEFAULTS, ...parseArgs(process.argv.slice(2)) };
  if (!MODES[cfg.mode]) throw new Error(`Unknown mode "${cfg.mode}" (use ui, forms, a11y or full)`);
  let start;
  try { start = new URL(cfg.startURL); } catch { throw new Error('A valid start URL is required (--url).'); }
  if (!/^https?:$/.test(start.protocol)) throw new Error('Only http(s) URLs can be audited.');
  start.hash = '';
  cfg.startURL = start.href;
  const origins = new Set([start.origin]);
  for (const o of cfg.allowedOrigins || []) {
    try { const u = new URL(o.includes('://') ? o : `https://${o}`); if (/^https?:$/.test(u.protocol)) origins.add(u.origin); } catch { /* ignore */ }
  }
  cfg.allowedOrigins = [...origins];
  cfg.maxPages = clamp(cfg.maxPages, 1, 200);
  cfg.maxDepth = clamp(cfg.maxDepth, 0, 10);
  cfg.rateLimitMs = clamp(cfg.rateLimitMs, 200, 10000);
  cfg.maxRunSeconds = clamp(cfg.maxRunSeconds, 30, 7200);
  if (!cfg.outDir) {
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    cfg.outDir = path.join(os.tmpdir(), 'sparkv-ui-audit', `${stamp}-${start.hostname}`);
  }
  cfg.outDir = path.resolve(cfg.outDir);
  cfg.checks = new Set(MODES[cfg.mode].checks);
  return cfg;
}

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, Number.isFinite(+v) ? +v : lo));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Hosts where form submission is always allowed: this machine and reserved
 * local-only names. Remote hosts (including staging.* / dev.*, which can be
 * real public sites such as dev.to) need the per-run --allow-submit opt-in.
 */
export function isTestHost(hostname) {
  const h = String(hostname).toLowerCase().replace(/^\[|\]$/g, '');
  return h === 'localhost' || h === '::1' || /^127\.\d+\.\d+\.\d+$/.test(h) || h.endsWith('.localhost')
    || h.endsWith('.test') || h.endsWith('.local');
}

// ---------------------------------------------------------------------------
// State

class StopError extends Error {}

const S = {
  cfg: null,
  findings: [],
  byKey: new Map(),
  pages: [],
  shots: 0,
  blocked: [],
  skippedDangerous: [],
  externalLinks: new Set(),
  sensitiveFields: [],
  formSignatures: new Set(),
  linkStatus: new Map(),
  linkChecks: 0,
  stopping: false,
  stopReason: '',
  paused: false,
  deadline: 0,
  requests: 0,
  dialogs: 0,
  popups: 0,
  current: null,
  page: null,
  context: null,
  browser: null,
  rand: makeRandom(Date.now() & 0xffffffff),
  tag: '',
  startedAt: new Date(),
  axeSource: '',
};

function stop(reason) {
  if (S.stopping) return;
  S.stopping = true;
  S.stopReason = reason;
  log(`Stopping: ${reason}`);
}

async function gate() {
  if (S.stopping) throw new StopError(S.stopReason);
  if (Date.now() > S.deadline) { stop('time limit reached'); throw new StopError(S.stopReason); }
  if (S.paused) {
    emit({ type: 'state', state: 'paused' });
    while (S.paused && !S.stopping) await sleep(200);
    if (S.stopping) throw new StopError(S.stopReason);
    emit({ type: 'state', state: 'running' });
  }
}

const isAllowedOrigin = (url) => { try { return S.cfg.allowedOrigins.includes(new URL(url).origin); } catch { return false; } };
const writeAllowed = (url) => { try { const u = new URL(url); return isAllowedOrigin(url) && (S.cfg.allowSubmit || isTestHost(u.hostname)); } catch { return false; } };
const submitAllowedFor = (url) => { try { return S.cfg.allowSubmit || isTestHost(new URL(url).hostname); } catch { return false; } };

function normURL(href) {
  try { const u = new URL(href); u.hash = ''; return u.href; } catch { return null; }
}
const SKIP_EXT = /\.(pdf|zip|gz|tgz|rar|7z|png|jpe?g|gif|svg|webp|avif|ico|mp4|webm|mov|mp3|wav|dmg|exe|pkg|msi|docx?|xlsx?|pptx?|csv|json|xml|txt|rss|atom|woff2?|ttf)$/i;
const DANGER_URL = /\b(log-?out|sign-?out|signoff|delete|remove|destroy|unsubscribe|cancel|checkout|payment|pay|purchase|billing|transfer|withdraw|deactivate)\b/i;

// ---------------------------------------------------------------------------
// Findings

let findingSeq = 0;

function vpLabel() {
  const v = S.page?.viewportSize();
  return v ? `${v.width}×${v.height}` : '';
}

/**
 * Adds a finding. Identical findings (same rule, element and key) on later
 * pages are folded into `alsoOn` of the first one. Returns the stored finding
 * when it is new, else null.
 */
function addFinding(input) {
  const meta = RULES[input.rule] || RULES.axe;
  const f = {
    id: '', rule: input.rule, category: input.category || meta.category, severity: input.severity || meta.severity,
    title: input.title || meta.title, page: input.page || S.current?.url || '', viewport: input.viewport ?? vpLabel(),
    selector: input.selector || '', locator: input.locator || '', evidence: input.evidence || '',
    expected: input.expected || '', actual: input.actual || '', steps: input.steps || [],
    fix: input.fix || meta.fix, acceptance: input.acceptance || meta.acceptance || [], helpUrl: input.helpUrl || '',
    screenshot: null, alsoOn: [], axeId: input.axeId || undefined,
  };
  const key = [f.rule, f.axeId || '', f.selector, input.key || ''].join('|');
  const existing = S.byKey.get(key);
  if (existing) {
    if (existing.page !== f.page && !existing.alsoOn.includes(f.page)) existing.alsoOn.push(f.page);
    return null;
  }
  f.id = `F${String(++findingSeq).padStart(3, '0')}`;
  S.byKey.set(key, f);
  S.findings.push(f);
  return f;
}

async function record(input, { shot = null } = {}) {
  const f = addFinding(input);
  if (!f) return null;
  if (shot !== false && S.page && !S.page.isClosed()) {
    const target = shot === 'viewport' ? null : shot === true || shot === null ? (f.selector || null) : shot;
    f.screenshot = await screenshot(target, `${f.id}-${f.rule}`);
  }
  emit({ type: 'finding', finding: f, counts: liveCounts() });
  return f;
}

function liveCounts() {
  const s = summarize(S.findings);
  return { issues: s.issues, ...s.bySeverity };
}

async function screenshot(selector, label) {
  if (S.shots >= S.cfg.maxScreenshots) return null;
  const rel = `screenshots/${String(++S.shots).padStart(3, '0')}-${label.replace(/[^a-z0-9-]+/gi, '-').slice(0, 60)}.png`;
  const abs = path.join(S.cfg.outDir, rel);
  const page = S.page;
  try {
    let clip;
    if (selector) {
      const box = await page.evaluate((sel) => window.__uia.highlight(sel), selector).catch(() => null);
      if (box) {
        const vp = page.viewportSize();
        const pad = 90;
        const x = Math.max(0, Math.floor(box.x - pad));
        const y = Math.max(0, Math.floor(box.y - pad));
        const w = Math.min(vp.width - x, Math.ceil(box.width + pad * 2));
        const hgt = Math.min(vp.height - y, Math.ceil(box.height + pad * 2));
        if (w > 20 && hgt > 20) clip = { x, y, width: w, height: hgt };
      }
    }
    await page.screenshot({ path: abs, clip, animations: 'disabled', timeout: 6000, scale: 'css' });
    return rel;
  } catch (e) {
    log(`Screenshot failed: ${e.message.split('\n')[0]}`, 'warn');
    return null;
  } finally {
    await page.evaluate(() => window.__uia && window.__uia.unhighlight()).catch(() => {});
  }
}

const openStep = (url) => `Open ${url} in a ${vpLabel()} viewport`;

// ---------------------------------------------------------------------------
// Browser setup

async function launch() {
  const cfg = S.cfg;
  const args = ['--no-first-run', '--no-default-browser-check', '--disable-features=Translate,AutofillServerCommunication',
    '--deny-permission-prompts', `--window-size=${cfg.viewports[0].width + 16},${cfg.viewports[0].height + 120}`, ...cfg.extraBrowserArgs];
  S.browser = await chromium.launch({
    headless: !!cfg.headless, args, slowMo: cfg.slowMoMs || 0,
    executablePath: cfg.executablePath || undefined,
  });
  S.browser.on('disconnected', () => { if (!S.closing) stop('browser window closed'); });
  S.context = await S.browser.newContext({
    viewport: { width: cfg.viewports[0].width, height: cfg.viewports[0].height },
    bypassCSP: true, acceptDownloads: false, serviceWorkers: 'block', locale: 'en-US',
    permissions: [],
  });
  S.context.setDefaultTimeout(8000);
  S.context.setDefaultNavigationTimeout(cfg.navTimeoutMs);
  await S.context.addInitScript(installHelpers);
  await S.context.route('**/*', guardRoute);
  S.context.on('page', (p) => {
    if (S.page && p !== S.page) {
      S.popups++;
      log(`Closed a new tab/window opened by the page (${p.url() || 'about:blank'})`);
      setTimeout(() => p.close().catch(() => {}), 800);
    }
  });
  S.page = await S.context.newPage();
  S.page.on('close', () => { if (!S.stopping && !S.closing) stop('browser tab closed'); });
  attachPageListeners(S.page);
}

async function guardRoute(route) {
  const req = route.request();
  const url = req.url();
  if (!/^https?:/i.test(url)) return route.continue().catch(() => {});
  const method = req.method().toUpperCase();
  let mainFrameNav = false;
  try { mainFrameNav = req.isNavigationRequest() && req.frame() === req.frame().page().mainFrame(); } catch { /* worker */ }
  if (mainFrameNav && !isAllowedOrigin(url)) {
    S.blocked.push({ reason: 'navigation outside allowed origins', method, url: url.slice(0, 300) });
    log(`Blocked navigation to ${new URL(url).origin} (not an allowed origin)`, 'warn');
    return route.abort('blockedbyclient').catch(() => {});
  }
  if (!['GET', 'HEAD', 'OPTIONS'].includes(method) && !writeAllowed(url)) {
    S.blocked.push({ reason: S.cfg.allowSubmit || isTestHost(new URL(url).hostname) ? 'write to a non-allowed origin' : 'write while submission is off', method, url: url.slice(0, 300) });
    log(`Blocked ${method} ${url.slice(0, 120)} (form submission is off for this host)`, 'warn');
    return route.abort('blockedbyclient').catch(() => {});
  }
  return route.continue().catch(() => {});
}

function attachPageListeners(page) {
  page.on('console', (m) => {
    if (m.type() !== 'error' || !S.current) return;
    const text = m.text();
    if (/ERR_BLOCKED_BY_CLIENT/.test(text)) return;
    const loc = m.location();
    S.current.console.push({ text: text.slice(0, 500), where: loc?.url ? `${loc.url}:${loc.lineNumber}` : '' });
  });
  page.on('pageerror', (err) => {
    if (S.current) S.current.exceptions.push({ text: `${err.name}: ${err.message}`.slice(0, 500), stack: (err.stack || '').split('\n').slice(1, 3).join(' ').trim() });
  });
  page.on('request', () => { S.requests++; });
  page.on('response', (resp) => {
    if (!S.current) return;
    const status = resp.status();
    if (status >= 400) {
      const req = resp.request();
      S.current.failed.push({ url: resp.url(), status, method: req.method(), type: req.resourceType(), nav: req.isNavigationRequest() });
    }
  });
  page.on('requestfailed', (req) => {
    if (!S.current) return;
    const failure = req.failure()?.errorText || 'failed';
    if (/ERR_BLOCKED_BY_CLIENT|ERR_ABORTED/.test(failure)) return;
    S.current.failed.push({ url: req.url(), status: 0, method: req.method(), type: req.resourceType(), failure, nav: req.isNavigationRequest() });
  });
  page.on('dialog', (d) => {
    S.dialogs++;
    const accept = d.type() === 'beforeunload';
    log(`${accept ? 'Accepted' : 'Dismissed'} a ${d.type()} dialog: ${d.message().slice(0, 100)}`);
    (accept ? d.accept() : d.dismiss()).catch(() => {});
  });
}

async function settle(page, ms = 4000) {
  await page.waitForLoadState('networkidle', { timeout: ms }).catch(() => {});
}

async function setViewport(vp) {
  await S.page.setViewportSize({ width: vp.width, height: vp.height });
  await S.page.waitForTimeout(300);
}

async function evaluate(fn, arg) {
  return S.page.evaluate(fn, arg);
}

// ---------------------------------------------------------------------------
// Crawl

const queue = [];
const seen = new Set();

function enqueue(href, depth, from) {
  const n = normURL(href);
  if (!n || seen.has(n)) return;
  const u = new URL(n);
  if (!/^https?:$/.test(u.protocol)) return;
  if (!isAllowedOrigin(n)) { S.externalLinks.add(n); return; }
  if (SKIP_EXT.test(u.pathname) || DANGER_URL.test(u.pathname + u.search)) return;
  if (depth > S.cfg.maxDepth) return;
  seen.add(n);
  queue.push({ url: n, depth, from });
}

async function crawl() {
  enqueue(S.cfg.startURL, 0, null);
  while (queue.length && S.pages.length < S.cfg.maxPages) {
    await gate();
    const item = queue.shift();
    try {
      await auditPage(item);
    } catch (e) {
      if (e instanceof StopError || S.stopping) throw e;
      log(`Page ${item.url} aborted: ${e.message.split('\n')[0]}`, 'warn');
      flushPageSignals();
    }
    if (queue.length && S.pages.length < S.cfg.maxPages) await sleep(S.cfg.rateLimitMs);
  }
}

async function auditPage(item) {
  const cfg = S.cfg;
  const page = S.page;
  const rec = { url: item.url, depth: item.depth, from: item.from, status: null, title: '', issues: 0, durationMs: 0 };
  const started = Date.now();
  S.pages.push(rec);
  S.current = { url: item.url, console: [], exceptions: [], failed: [] };
  const total = Math.min(cfg.maxPages, S.pages.length + queue.length);
  emit({ type: 'page', index: S.pages.length, total, url: item.url, depth: item.depth });

  await setViewport(cfg.viewports[0]);
  let resp = null;
  try {
    resp = await page.goto(item.url, { waitUntil: 'domcontentloaded' });
  } catch (e) {
    if (S.stopping) throw new StopError(S.stopReason);
    await record({ rule: 'page-load-failed', page: item.url, evidence: e.message.split('\n')[0], steps: [openStep(item.url)],
      expected: 'The page loads', actual: e.message.split('\n')[0] }, { shot: false });
    finishPage(rec, started);
    return;
  }
  rec.status = resp ? resp.status() : null;
  await settle(page);
  rec.finalUrl = page.url();
  rec.title = await page.title().catch(() => '');
  if (rec.status >= 400) {
    await record({ rule: 'page-http-error', page: item.url, evidence: `HTTP ${rec.status}${item.from ? ` (linked from ${item.from})` : ''}`,
      steps: [openStep(item.url)], expected: 'HTTP 2xx', actual: `HTTP ${rec.status}`, severity: rec.status >= 500 ? 'high' : 'medium' }, { shot: true });
  }
  S.linkStatus.set(normURL(item.url), rec.status ?? 0);
  if (!isAllowedOrigin(page.url())) { log(`Redirected outside the allowed origins; skipping ${item.url}`, 'warn'); finishPage(rec, started); return; }

  emit({ type: 'step', message: 'Scrolling through the page' });
  const locale = await evaluate(() => window.__uia.locale()).catch(() => ({ indian: false }));
  await evaluate((n) => window.__uia.scrollThrough(n), 40).catch(() => {});
  await gate();

  // Links: crawl queue, link checks, anchors.
  const links = await evaluate(() => window.__uia.collectLinks()).catch(() => []);
  for (const l of links) {
    if (l.dangerous || l.download) continue;
    if (/^(mailto|tel|javascript|sms|data):/i.test(l.raw)) continue;
    enqueue(l.href, item.depth + 1, item.url);
  }
  // The page count known so far, now that this page's links are queued.
  emit({ type: 'step', message: `Found ${links.length} link(s); ${queue.length} page(s) queued`, total: Math.min(cfg.maxPages, S.pages.length + queue.length) });
  if (cfg.checks.has('links')) await checkLinks(item.url, links);

  if (cfg.checks.has('images')) await auditImages(item.url);
  if (cfg.checks.has('axe')) await runAxe(item.url);
  if (cfg.checks.has('layout')) await auditLayout(item.url);
  else if (cfg.checks.has('tap')) await auditTapTargetsOnly(item.url);
  if (cfg.checks.has('keyboard')) await auditKeyboard(item.url);
  if (cfg.checks.has('forms') || cfg.checks.has('formsStatic')) await auditForms(item.url, locale, cfg.checks.has('forms'));
  if (cfg.checks.has('dead')) await auditDeadButtons(item.url, item.depth);
  finishPage(rec, started);
}

function finishPage(rec, started) {
  flushPageSignals();
  rec.durationMs = Date.now() - started;
  rec.issues = S.findings.filter((f) => (f.page === rec.url || f.alsoOn.includes(rec.url)) && f.severity !== 'info').length;
  emit({ type: 'page-done', url: rec.url, status: rec.status, issues: rec.issues, counts: liveCounts() });
}

/** Turns console/network signals collected for the current page into findings. */
function flushPageSignals() {
  const cur = S.current;
  if (!cur || cur.flushed) return;
  cur.flushed = true;
  const cfg = S.cfg;
  const emitPlain = (input) => { const f = addFinding({ ...input, viewport: '' }); if (f) emit({ type: 'finding', finding: f, counts: liveCounts() }); };
  if (cfg.checks.has('console')) {
    const seenText = new Set();
    for (const c of cur.console) {
      if (cfg.checks.has('network') && /^Failed to load resource:/.test(c.text)) continue; // reported as request-failed
      const key = c.text.replace(/\d+/g, '#').slice(0, 160);
      if (seenText.has(key) || seenText.size >= 10) continue;
      seenText.add(key);
      emitPlain({ rule: 'console-error', page: cur.url, key, evidence: c.text + (c.where ? ` (at ${c.where})` : ''),
        steps: [`Open ${cur.url}`, 'Open DevTools > Console', 'Interact with the page as described in other findings (fill forms, click buttons)'],
        expected: 'No console errors', actual: c.text.slice(0, 200) });
    }
    for (const x of cur.exceptions.slice(0, 10)) {
      emitPlain({ rule: 'page-exception', page: cur.url, key: x.text.slice(0, 160), evidence: `${x.text}${x.stack ? ` — ${x.stack}` : ''}`,
        steps: [`Open ${cur.url}`, 'Open DevTools > Console'], expected: 'No uncaught exceptions', actual: x.text.slice(0, 200) });
    }
  }
  if (cfg.checks.has('network')) {
    const seenReq = new Set();
    for (const r of cur.failed) {
      const key = `${r.method} ${normURL(r.url)} ${r.status}`;
      if (seenReq.has(key) || seenReq.size >= 15) continue;
      if (r.nav) continue; // page-http-error / broken-link / submit-server-error cover navigations
      seenReq.add(key);
      const sameOrigin = isAllowedOrigin(r.url);
      const severity = r.status >= 500 ? 'high' : !sameOrigin ? 'low' : 'medium';
      emitPlain({ rule: 'request-failed', page: cur.url, key, severity,
        evidence: `${r.method} ${r.url} → ${r.status ? `HTTP ${r.status}` : r.failure} (${r.type}${sameOrigin ? '' : ', third-party'})`,
        steps: [`Open ${cur.url}`, 'Open DevTools > Network', `Find ${r.method} ${r.url.slice(0, 120)}`],
        expected: 'The request succeeds (2xx/3xx)', actual: r.status ? `HTTP ${r.status}` : r.failure });
    }
  }
}

// ---------------------------------------------------------------------------
// Links & images

async function checkLinks(pageURL, links) {
  const cfg = S.cfg;
  const anchors = await evaluate(() => window.__uia.brokenAnchors()).catch(() => []);
  for (const a of anchors.slice(0, 5)) {
    await gate();
    await record({ rule: 'broken-anchor', page: pageURL, selector: a.selector, locator: a.locator, evidence: `href="${a.raw}" but no element has id "${a.raw.slice(1)}"`,
      steps: [openStep(pageURL), `Click the link "${a.text}"`], expected: 'The page scrolls to the referenced section', actual: 'Nothing happens: the id does not exist' });
  }
  let checkedHere = 0;
  for (const l of links) {
    if (S.linkChecks >= cfg.maxLinkChecks || checkedHere >= cfg.maxLinkChecksPerPage) break;
    if (l.dangerous || l.download || /^(mailto|tel|javascript|sms|data|#)/i.test(l.raw)) continue;
    const href = normURL(l.href);
    if (!href || !isAllowedOrigin(href)) continue;
    if (DANGER_URL.test(new URL(href).pathname)) continue;
    let status = S.linkStatus.get(href);
    if (status === undefined) {
      await gate();
      checkedHere++;
      S.linkChecks++;
      status = await probeURL(href);
      S.linkStatus.set(href, status);
      await sleep(Math.min(400, cfg.rateLimitMs));
    }
    if (status === 0 || status >= 400) {
      await record({ rule: 'broken-link', page: pageURL, selector: l.selector, locator: l.locator, key: href,
        evidence: `Link "${l.text || l.raw}" → ${href} returns ${status ? `HTTP ${status}` : 'a network error'}`,
        steps: [openStep(pageURL), `Click the link "${l.text || l.raw}" (${l.selector})`],
        expected: 'The link opens a working page', actual: status ? `HTTP ${status}` : 'Network error' });
    }
  }
}

async function probeURL(href) {
  try {
    let resp = await S.context.request.fetch(href, { method: 'HEAD', timeout: 10000, maxRedirects: 5, failOnStatusCode: false });
    if ([403, 405, 501].includes(resp.status())) {
      resp = await S.context.request.fetch(href, { method: 'GET', timeout: 12000, maxRedirects: 5, failOnStatusCode: false });
    }
    return resp.status();
  } catch {
    return 0;
  }
}

async function auditImages(pageURL) {
  const issues = await evaluate(() => window.__uia.imageIssues()).catch(() => []);
  let n = 0;
  for (const img of issues) {
    if (n++ >= 10) break;
    await gate();
    const rule = img.kind === 'broken' ? 'img-broken' : img.kind === 'role-img-no-name' ? 'role-img-no-name' : 'img-missing-alt';
    if (rule !== 'img-broken' && S.cfg.checks.has('axe')) continue; // axe image-alt / role-img-alt cover these
    await record({ rule, page: pageURL, selector: img.selector, locator: img.locator, key: img.src,
      evidence: `${img.tag} src=${img.src || '(none)'}${img.visible ? '' : ' (not visible)'}`,
      steps: [openStep(pageURL), `Inspect ${img.selector}`],
      expected: rule === 'img-broken' ? 'The image loads' : 'The image has alt text (or alt="" if decorative)',
      actual: rule === 'img-broken' ? 'The image failed to load' : 'No alt attribute' }, { shot: img.visible ? true : false });
  }
}

// ---------------------------------------------------------------------------
// axe-core

async function runAxe(pageURL) {
  await gate();
  emit({ type: 'step', message: 'Running axe-core accessibility checks' });
  const ok = await evaluate((src) => {
    if (window.axe) return true;
    const savedDefine = window.define;
    try { window.define = undefined; (0, eval)(src); } finally { window.define = savedDefine; }
    return !!window.axe;
  }, S.axeSource).catch((e) => { log(`axe injection failed: ${e.message.split('\n')[0]}`, 'warn'); return false; });
  if (!ok) return;
  const violations = await evaluate(async () => {
    const r = await window.axe.run(document, {
      runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa', 'best-practice'] },
      resultTypes: ['violations'],
    });
    return r.violations.map((v) => ({
      id: v.id, impact: v.impact, help: v.help, description: v.description, helpUrl: v.helpUrl, tags: v.tags,
      count: v.nodes.length,
      nodes: v.nodes.slice(0, 3).map((n) => ({ target: n.target, html: (n.html || '').slice(0, 300), failureSummary: n.failureSummary || '', impact: n.impact })),
    }));
  }).catch((e) => { log(`axe run failed: ${e.message.split('\n')[0]}`, 'warn'); return []; });
  for (const v of violations) {
    for (const [i, n] of v.nodes.entries()) {
      await gate();
      const selector = n.target.map((t) => (Array.isArray(t) ? t.join(' >>> ') : t)).join(' >>> ');
      const more = i === v.nodes.length - 1 && v.count > v.nodes.length ? ` (+${v.count - v.nodes.length} more elements with this problem)` : '';
      const wcag = v.tags.filter((t) => /^wcag\d/.test(t)).join(', ');
      // failureSummary is "Fix any of the following:\n  reason\n  reason…".
      const lines = n.failureSummary.split('\n').map((x) => x.trim()).filter(Boolean);
      const reasons = lines.filter((x) => !/^Fix (any|all) of the following:?$/i.test(x));
      const header = lines.find((x) => /^Fix (any|all) of the following/i.test(x)) || 'Fix';
      await record({
        rule: 'axe', axeId: v.id, category: 'a11y', severity: axeSeverity(n.impact || v.impact), title: `${v.help} (axe: ${v.id})`,
        page: pageURL, selector, evidence: `${n.html}${more}`, helpUrl: v.helpUrl,
        expected: v.description, actual: reasons.slice(0, 3).join('; ').slice(0, 400),
        steps: [openStep(pageURL), `Run axe-core (rule "${v.id}"${wcag ? `, ${wcag}` : ''}) or inspect ${selector}`],
        fix: `${v.help}. ${header.replace(/:$/, '')}: ${reasons.slice(0, 4).join('; ')}`.slice(0, 500),
        acceptance: [`axe-core reports no "${v.id}" violation for ${selector}.`],
      }, { shot: selector.includes('>>>') ? null : true });
    }
  }
}

// ---------------------------------------------------------------------------
// Layout

async function auditLayout(pageURL) {
  const cfg = S.cfg;
  const meta = await evaluate(() => !!document.querySelector('meta[name=viewport]')).catch(() => true);
  if (!meta) {
    await record({ rule: 'horizontal-overflow', severity: 'medium', title: 'No <meta name="viewport"> tag: phones will render a zoomed-out desktop layout',
      page: pageURL, key: 'meta-viewport', evidence: 'document has no meta[name=viewport]', viewport: '',
      fix: 'Add <meta name="viewport" content="width=device-width, initial-scale=1"> to <head>.',
      acceptance: ['The page has a width=device-width viewport meta tag.'], steps: [`View the source of ${pageURL}`],
      expected: 'A responsive viewport meta tag', actual: 'Missing' }, { shot: false });
  }
  for (const vp of cfg.viewports) {
    await gate();
    emit({ type: 'step', message: `Checking layout at ${vp.width}px` });
    await setViewport(vp);
    await evaluate(() => window.scrollTo(0, 0)).catch(() => {});
    const ov = await evaluate(() => window.__uia.overflow()).catch(() => null);
    if (ov && ov.overflows) {
      const culprit = ov.culprits[0];
      await record({
        rule: 'horizontal-overflow', page: pageURL, severity: vp.width < 600 ? 'high' : 'medium', key: String(vp.width),
        selector: culprit?.selector || '', locator: culprit?.locator || '',
        evidence: `scrollWidth ${ov.scrollWidth}px > viewport ${ov.clientWidth}px. Widest causes: ${ov.culprits.map((c) => `${c.selector} (right edge ${c.right}px, width ${c.width}px)`).join('; ') || 'unknown'}`,
        steps: [openStep(pageURL), 'Scroll horizontally'], expected: `No horizontal scrolling at ${vp.width}px`,
        actual: `Page is ${ov.scrollWidth - ov.clientWidth}px wider than the viewport`,
      }, { shot: 'viewport' });
    }
    const text = await evaluate(() => window.__uia.textLayout()).catch(() => ({ clipped: [], overlaps: [] }));
    for (const c of text.clipped.slice(0, 5)) {
      await gate();
      await record({ rule: 'text-clipped', page: pageURL, selector: c.selector, locator: c.locator,
        evidence: `"${c.text.slice(0, 80)}" needs ${c.scrollWidth}×${c.scrollHeight}px but has ${c.clientWidth}×${c.clientHeight}px (overflow hidden, no ellipsis)`,
        steps: [openStep(pageURL), `Look at ${c.selector}`], expected: 'All text is visible', actual: 'Part of the text is cut off' });
    }
    for (const o of text.overlaps.slice(0, 5)) {
      await gate();
      await record({ rule: 'text-overlap', page: pageURL, selector: o.a.selector, locator: o.a.locator, key: o.b.selector,
        evidence: `"${o.a.text.slice(0, 50)}" (${o.a.selector}) overlaps "${o.b.text.slice(0, 50)}" (${o.b.selector}) by ${o.percent}%`,
        steps: [openStep(pageURL), `Look at ${o.a.selector} and ${o.b.selector}`], expected: 'Text blocks do not overlap', actual: `${o.percent}% of the smaller text box is covered` });
    }
    if (vp.width < 600 && cfg.checks.has('tap')) await auditTapTargets(pageURL);
  }
  await setViewport(cfg.viewports[0]);
}

async function auditTapTargetsOnly(pageURL) {
  const mobile = S.cfg.viewports.find((v) => v.width < 600);
  if (!mobile) return;
  await setViewport(mobile);
  await auditTapTargets(pageURL);
  await setViewport(S.cfg.viewports[0]);
}

async function auditTapTargets(pageURL) {
  const small = await evaluate(() => window.__uia.tapTargets()).catch(() => []);
  for (const t of small.slice(0, 8)) {
    await gate();
    await record({ rule: 'tap-target-small', page: pageURL, selector: t.selector, locator: t.locator, severity: t.width < 16 || t.height < 16 || t.crowded ? 'medium' : 'low',
      evidence: `${t.tag} "${t.text.slice(0, 40)}" is ${t.width}×${t.height}px${t.crowded ? ' and sits within 24px of another target' : ''}`,
      steps: [openStep(pageURL), `Try to tap ${t.selector} on a phone`], expected: 'Target at least 24×24 CSS px (44×44 recommended)', actual: `${t.width}×${t.height}px` });
  }
}

// ---------------------------------------------------------------------------
// Keyboard

async function auditKeyboard(pageURL) {
  const cfg = S.cfg;
  const page = S.page;
  await gate();
  emit({ type: 'step', message: 'Walking the page with the Tab key' });
  await evaluate(() => window.scrollTo(0, 0)).catch(() => {});
  const prep = await evaluate(() => window.__uia.prepareFocusAudit()).catch(() => null);
  if (!prep) return;
  if (prep.positive.length) {
    const p = prep.positive[0];
    await record({ rule: 'positive-tabindex', page: pageURL, selector: p.selector, locator: p.locator,
      evidence: `${prep.positive.length} element(s) with tabindex > 0: ${prep.positive.map((x) => x.selector).join(', ')}`,
      steps: [openStep(pageURL), 'Press Tab from the top of the page'], expected: 'Focus follows DOM order', actual: 'Focus jumps to tabindex>0 elements first' });
  }
  for (const el of prep.pointerOnly.slice(0, 5)) {
    await gate();
    await record({ rule: 'clickable-not-focusable', page: pageURL, selector: el.selector, locator: el.locator,
      evidence: `<${el.tag}> "${el.text.slice(0, 60)}" has cursor:pointer but is not a link/button and has no tabindex`,
      steps: [openStep(pageURL), 'Press Tab repeatedly', `Notice ${el.selector} never receives focus`], expected: 'Reachable with Tab, operable with Enter/Space', actual: 'Mouse-only' });
  }
  const seq = [];
  let prev = null;
  let repeats = 0;
  let noIndicator = 0;
  let hidden = 0;
  let noneRuns = 0;
  for (let i = 0; i < cfg.maxTabStops; i++) {
    await gate();
    await page.keyboard.press('Tab');
    await page.waitForTimeout(60);
    const info = await evaluate(() => window.__uia.focusInfo()).catch(() => null);
    if (!info) break; // navigated
    if (info.inIframe) { prev = info.selector; continue; }
    if (info.none) { if (seq.length || ++noneRuns >= 6) break; continue; }
    if (info.selector === prev) {
      // Date/time inputs have several segments that each take a Tab stop.
      if (++repeats >= (/^(date|time|datetime-local|month|week)$/.test(info.inputType) ? 7 : 3)) {
        await record({ rule: 'keyboard-trap', page: pageURL, selector: info.selector, locator: info.locator,
          evidence: `Focus stayed on ${info.selector} for ${repeats + 1} consecutive Tab presses`,
          steps: [openStep(pageURL), `Tab to ${info.selector}`, 'Press Tab again several times'], expected: 'Focus moves on', actual: 'Focus does not leave the element' });
        break;
      }
      continue;
    }
    repeats = 0;
    prev = info.selector;
    if (seq.length && info.selector === seq[0].selector) break; // wrapped around
    seq.push(info);
    if (info.indicator === 'none' && info.visible && info.onScreen && noIndicator < 6) {
      noIndicator++;
      await record({ rule: 'focus-not-visible', page: pageURL, selector: info.selector, locator: info.locator,
        evidence: `No change in outline, box-shadow, border, background or color when ${info.tag} "${info.text.slice(0, 40)}" is focused (Tab stop ${seq.length})`,
        steps: [openStep(pageURL), `Press Tab ${seq.length} time(s) from the top`, `Look at ${info.selector}`],
        expected: 'A visible focus ring', actual: 'Focused and unfocused states look identical' });
    } else if ((!info.visible || !info.onScreen) && hidden < 4) {
      hidden++;
      await record({ rule: 'focus-invisible-element', page: pageURL, selector: info.selector, locator: info.locator,
        evidence: `Tab stop ${seq.length}: ${info.tag} "${info.text.slice(0, 40)}" is ${info.visible ? 'off-screen' : 'hidden'} (${info.w}×${info.h} at ${info.x},${info.y})`,
        steps: [openStep(pageURL), `Press Tab ${seq.length} time(s)`, 'Notice focus disappears'], expected: 'Focus lands on visible controls', actual: 'Focus is on an invisible element' }, { shot: false });
    }
  }
  const jumps = [];
  for (let i = 1; i < seq.length; i++) {
    const a = seq[i - 1], b = seq[i];
    if (b.visible && a.visible && b.y + b.h < a.y - 150) jumps.push(`${a.selector} (y=${a.y}) → ${b.selector} (y=${b.y})`);
  }
  if (jumps.length >= 2) {
    await record({ rule: 'focus-order', page: pageURL, selector: '', key: 'order', evidence: `${jumps.length} backward jumps: ${jumps.slice(0, 3).join('; ')}`,
      steps: [openStep(pageURL), 'Press Tab repeatedly from the top and watch where focus goes'], expected: 'Top-to-bottom order', actual: 'Focus jumps back up the page' }, { shot: false });
  }
  emit({ type: 'step', message: `Keyboard: ${seq.length} Tab stops checked` });
  await evaluate(() => document.activeElement && document.activeElement.blur && document.activeElement.blur()).catch(() => {});
}

// ---------------------------------------------------------------------------
// Forms

const TEXTLIKE = new Set(['text', 'email', 'tel', 'url', 'search', 'password', 'number', 'textarea', 'date', 'datetime-local', 'month', 'week', 'time']);
const AUTOCOMPLETE_FOR = { email: 'email', phone: 'tel', firstName: 'given-name', lastName: 'family-name', fullName: 'name',
  address: 'street-address', city: 'address-level2', postalCode: 'postal-code', country: 'country-name', username: 'username', company: 'organization' };

function fieldLabel(f) {
  return f.label || f.ariaLabel || f.accName || f.placeholder || f.name || f.id || f.type;
}

async function auditForms(pageURL, locale, dynamic) {
  await gate();
  let forms = await evaluate(() => window.__uia.collectForms()).catch(() => []);
  forms = forms.filter((f) => f.visible && f.fields.some((x) => x.visible || x.labelVisible));
  if (!forms.length) return;
  emit({ type: 'step', message: `Auditing ${forms.length} form(s)` });

  const structural = await evaluate(() => {
    const badFor = Array.from(document.querySelectorAll('label[for]')).filter((l) => !document.getElementById(l.htmlFor))
      .map((l) => ({ selector: window.__uia.selectorFor(l), for: l.htmlFor, text: (l.textContent || '').trim().slice(0, 60) }));
    const ids = {};
    for (const el of document.querySelectorAll('input[id], select[id], textarea[id]')) (ids[el.id] ||= []).push(window.__uia.selectorFor(el));
    const dup = Object.entries(ids).filter(([, v]) => v.length > 1).map(([id, v]) => ({ id, selectors: v }));
    return { badFor: badFor.slice(0, 5), dup: dup.slice(0, 5) };
  }).catch(() => ({ badFor: [], dup: [] }));
  for (const b of structural.badFor) {
    await record({ rule: 'label-for-missing-target', page: pageURL, selector: b.selector, evidence: `<label for="${b.for}"> "${b.text}" — no element has id "${b.for}"`,
      steps: [openStep(pageURL), `Click the label "${b.text}"`], expected: 'Clicking the label focuses its field', actual: 'Nothing is focused' });
  }
  for (const d of structural.dup) {
    await record({ rule: 'duplicate-id', page: pageURL, selector: d.selectors[0], key: d.id, evidence: `id="${d.id}" is used by ${d.selectors.join(', ')}`,
      steps: [openStep(pageURL), `Run document.querySelectorAll('#${d.id}') in the console`], expected: 'One element per id', actual: `${d.selectors.length} elements` }, { shot: false });
  }

  const nameCheck = !S.cfg.checks.has('axe');
  for (const form of forms.slice(0, S.cfg.maxFormsPerPage)) {
    await gate();
    for (const f of form.fields) await staticFieldChecks(pageURL, form, f, nameCheck);
    if (!dynamic) continue;
    const sig = `${form.action}|${form.fields.map((f) => `${f.name || f.id}:${f.type}`).join(',')}`;
    if (S.formSignatures.has(sig)) { log(`Form already exercised on an earlier page; skipping fill on ${pageURL}`); continue; }
    S.formSignatures.add(sig);
    try {
      await exerciseForm(pageURL, form, locale);
    } catch (e) {
      if (e instanceof StopError || S.stopping) throw e;
      log(`Form ${form.selector || '#' + form.index} aborted: ${e.message.split('\n')[0]}`, 'warn');
    }
    await reloadIfNeeded(pageURL, true);
  }
}

async function staticFieldChecks(pageURL, form, f, nameCheck) {
  if (f.disabled || (!f.visible && !f.labelVisible)) return;
  const { purpose, source } = inferPurpose(f);
  const textLike = TEXTLIKE.has(f.type);
  const label = fieldLabel(f);
  const base = { page: pageURL, selector: f.selector, locator: f.locator };
  const step0 = openStep(pageURL);

  if (nameCheck && !f.accName) {
    await record({ ...base, rule: 'field-no-accessible-name', evidence: `<${f.tag} type="${f.type}" name="${f.name}"> has no label, aria-label, aria-labelledby, title or placeholder`,
      steps: [step0, `Focus ${f.selector} with VoiceOver on`], expected: 'The field is announced with a name', actual: 'Announced as an unnamed field' });
  }
  if (textLike && !f.label && !f.ariaLabel && f.accSource === 'placeholder') {
    await record({ ...base, rule: 'placeholder-as-label', evidence: `Only the placeholder "${f.placeholder}" names this field; it disappears as soon as the user types`,
      steps: [step0, `Type into ${f.selector}`, 'Notice the field\'s description is gone'], expected: 'A persistent visible label', actual: 'Placeholder only' });
  }
  if (textLike && f.hasPlaceholderAttr && !f.placeholder.trim()) {
    await record({ ...base, rule: 'placeholder-empty', evidence: `placeholder="" on ${label}`, steps: [step0, `Inspect ${f.selector}`], expected: 'A helpful example or no attribute', actual: 'Empty placeholder' }, { shot: false });
  }
  if (textLike && f.placeholder.trim()) {
    const fromPlaceholder = purposeFromText(f.placeholder);
    const fromLabel = purposeFromText([f.label, f.ariaLabel, f.name, f.id].join(' ')) || ({ email: 'email', tel: 'phone', url: 'url' })[f.type] || null;
    if (fromPlaceholder && fromLabel && !compatiblePurposes(fromPlaceholder, fromLabel)) {
      await record({ ...base, rule: 'placeholder-misleading', evidence: `Label/name suggest ${fromLabel} ("${(f.label || f.name || f.id).slice(0, 40)}") but the placeholder says "${f.placeholder}" (${fromPlaceholder})`,
        steps: [step0, `Look at ${f.selector}`], expected: `Placeholder describes ${fromLabel}`, actual: `Placeholder describes ${fromPlaceholder}` });
    }
    const re = patternRegex(f.pattern);
    const example = f.placeholder.replace(/^\s*(e\.?\s?g\.?|eg|ex(ample)?|like|format|for example)[:,\s]*/i, '').trim();
    const looksLikeValue = /[\d@]/.test(example) && !/^(enter|type|your|add|write|please)\b/i.test(example);
    if (re && looksLikeValue && !re.test(example)) {
      await record({ ...base, rule: 'placeholder-pattern-mismatch', evidence: `Placeholder example "${example}" does not match pattern="${f.pattern}"`,
        steps: [step0, `Type "${example}" into ${f.selector}`, 'Try to submit'], expected: 'The example value is accepted', actual: 'It fails the pattern' }, { shot: false });
    }
  }
  const formatted = f.pattern || (f.type === 'text' && ['phone', 'dob', 'date', 'postalCode'].includes(purpose));
  if (textLike && formatted && !f.placeholder.trim() && !f.describedBy && !f.title) {
    await record({ ...base, rule: 'format-hint-missing', evidence: `${label}: ${f.pattern ? `pattern="${f.pattern}"` : `expects a ${purpose}`} but shows no example, title or help text`,
      steps: [step0, `Look at ${f.selector} before typing`], expected: 'The expected format is visible', actual: 'No hint' }, { shot: false });
  }
  if (f.requiredMarker && !f.required && !f.ariaRequired && !['checkbox', 'radio'].includes(f.type)) {
    await record({ ...base, rule: 'required-marker-not-enforced', evidence: `Label "${f.markerText.slice(0, 60)}" marks the field required, but it has neither required nor aria-required${form.noValidate ? ' (form has novalidate)' : ''}`,
      steps: [step0, `Leave ${f.selector} empty`, 'Submit the form'], expected: 'Submission blocked with an error on this field', actual: 'The browser treats the field as optional' });
  }
  if ((f.required || f.ariaRequired) && !f.requiredMarker && f.visible && !['checkbox', 'radio', 'hidden'].includes(f.type)) {
    await record({ ...base, rule: 'required-not-indicated', evidence: `${label} is required but its label "${(f.markerText || '').slice(0, 60)}" has no * / "required"`,
      steps: [step0, `Look at the label of ${f.selector}`], expected: 'Required fields are visibly marked', actual: 'No indicator' }, { shot: false });
  }
  if (AUTOCOMPLETE_FOR[purpose] && !f.autocomplete && textLike && f.type !== 'password') {
    await record({ ...base, rule: 'autocomplete-missing', evidence: `${label} looks like ${purpose} (from ${source}); add autocomplete="${AUTOCOMPLETE_FOR[purpose]}"`,
      steps: [step0, `Inspect ${f.selector}`], expected: `autocomplete="${AUTOCOMPLETE_FOR[purpose]}"`, actual: 'No autocomplete attribute' }, { shot: false });
  }
  const wantType = purpose === 'email' && f.type === 'text' ? 'type="email"'
    : purpose === 'phone' && f.type === 'text' && !f.inputMode ? 'type="tel"'
      : purpose === 'url' && f.type === 'text' ? 'type="url"'
        : ['age', 'quantity'].includes(purpose) && f.type === 'text' && !f.inputMode ? 'type="number" or inputmode="numeric"' : null;
  if (wantType) {
    await record({ ...base, rule: 'wrong-input-type', evidence: `${label} (${purpose}, from ${source}) is <input type="text">; use ${wantType}`,
      steps: [step0, `Inspect ${f.selector}`, 'On a phone, focus it and look at the keyboard'], expected: wantType, actual: 'type="text"' }, { shot: false });
  }
}

async function reloadIfNeeded(pageURL, force = false) {
  const page = S.page;
  if (!force && normURL(page.url()) === normURL(pageURL)) return;
  await gate();
  await page.goto(pageURL, { waitUntil: 'domcontentloaded' }).catch(() => {});
  await settle(page, 3000);
}

async function fillField(f, ctx, radioGroups) {
  const page = S.page;
  const loc = page.locator(f.selector).first();
  const { purpose } = inferPurpose(f);
  if (SENSITIVE.has(purpose)) {
    S.sensitiveFields.push({ page: S.current.url, selector: f.selector, purpose });
    return { skipped: 'sensitive', purpose };
  }
  const t = f.type;
  try {
    if (t === 'checkbox') {
      if (f.dangerous) return { skipped: 'dangerous', purpose };
      if (!f.checked) await loc.check({ timeout: 2000 }).catch(() => loc.evaluate((el) => { if (!el.checked) el.click(); }));
      return { value: 'checked', purpose };
    }
    if (t === 'radio') {
      if (radioGroups.has(f.name)) return { skipped: 'group done', purpose };
      radioGroups.add(f.name);
      await loc.check({ timeout: 2000 }).catch(() => loc.evaluate((el) => el.click()));
      return { value: 'checked', purpose };
    }
    if (t === 'file') {
      const file = fixtureFor(f.accept, FIXTURES);
      await loc.setInputFiles(file, { timeout: 3000 });
      return { value: path.basename(file), purpose };
    }
    if (f.tag === 'select') {
      const opt = (f.options || []).find((o) => !o.disabled && o.value !== '' && !/^\s*(select|choose|pick|please|--|—|-)/i.test(o.text));
      if (!opt) return { skipped: 'no valid option', purpose };
      await loc.selectOption(opt.value, { timeout: 2000 });
      return { value: opt.text || opt.value, purpose };
    }
    let value;
    if (t === 'number' || t === 'range') value = numberValue(f, purpose);
    else if (['date', 'datetime-local', 'month', 'week', 'time'].includes(t)) value = dateValue(f, purpose);
    else if (t === 'color') value = '#3366ff';
    else value = textValue(purpose, f, ctx).value;
    await loc.fill(value, { timeout: 3000 });
    await loc.blur().catch(() => {});
    return { value, purpose };
  } catch (e) {
    await record({ rule: 'fill-failed', page: S.current.url, selector: f.selector, locator: f.locator,
      evidence: `${fieldLabel(f)}: ${e.message.split('\n')[0].slice(0, 160)}`, steps: [openStep(S.current.url), `Fill ${f.selector}`] }, { shot: false });
    return { failed: true, purpose };
  }
}

const state = (sel) => evaluate((s) => window.__uia.fieldState(s), sel).catch(() => null);

function newText(before, after) {
  const parts = [];
  const diff = (a, b) => (b && b !== a ? b.replace(a || '', '').trim() || b : '');
  parts.push(diff(before?.error.associated, after.error.associated));
  parts.push(diff(before?.error.near, after.error.near));
  parts.push(diff(before?.alerts, after.alerts));
  return parts.filter(Boolean).join(' ').trim();
}

async function exerciseForm(pageURL, form, locale) {
  const page = S.page;
  const ctx = { rand: S.rand, tag: S.tag, indian: !!locale.indian };
  const canSubmit = submitAllowedFor(pageURL);
  const submit = form.submits.find((s) => s.visible && !s.disabled);
  const formName = form.heading || form.selector || `form #${form.index + 1}`;
  const fields = form.fields.filter((f) => !f.disabled && !f.readOnly && (f.visible || (['checkbox', 'radio'].includes(f.type) && f.labelVisible)));
  const hasRequired = fields.some((f) => f.required || f.ariaRequired || f.requiredMarker);
  emit({ type: 'step', message: `Form "${formName}": ${fields.length} field(s), submission ${canSubmit ? 'allowed' : 'off'}` });

  if (submit && submit.dangerous && !S.cfg.allowDangerous) {
    S.skippedDangerous.push({ page: pageURL, selector: submit.selector, text: submit.text });
    log(`Not submitting "${formName}": its button "${submit.text}" looks destructive/financial`, 'warn');
  }
  const submitUsable = canSubmit && submit && form.selector && (!submit.dangerous || S.cfg.allowDangerous);

  // 1. Empty submit: required fields must block it.
  if (submitUsable && hasRequired) {
    await gate();
    const r = await submitAndObserve(form, submit);
    if (r.sent && r.validityBefore && !r.validityBefore.valid) {
      await record({ rule: 'empty-required-submitted', page: pageURL, selector: form.selector,
        evidence: `Submitting "${formName}" with all fields empty sent ${r.sent}${r.status ? ` (HTTP ${r.status})` : ''}; invalid fields: ${r.validityBefore.invalid.map((x) => x.selector).join(', ')}`,
        steps: [openStep(pageURL), `Leave every field in ${form.selector} empty`, `Click "${submit.text}"`],
        expected: 'Submission blocked with field errors', actual: `Request sent: ${r.sent}` }, { shot: false });
    } else if (!r.sent && form.noValidate && r.mutations === 0 && !r.navigated) {
      await record({ rule: 'validation-no-feedback', page: pageURL, selector: submit.selector, locator: submit.locator, key: 'empty-submit',
        evidence: `"${formName}" has novalidate; clicking "${submit.text}" with required fields empty changed nothing on the page`,
        steps: [openStep(pageURL), `Click "${submit.text}" without filling the form`], expected: 'Errors next to the required fields', actual: 'No visible reaction' });
    }
    await reloadIfNeeded(pageURL, true);
  }

  // 2. Fill every field with realistic, type-correct data.
  const filled = new Map();
  const radioGroups = new Set();
  for (const f of fields) {
    await gate();
    const r = await fillField(f, ctx, radioGroups);
    filled.set(f.selector, r);
    if (r.value) emit({ type: 'step', message: `Filled ${fieldLabel(f).slice(0, 40)} → ${f.type === 'password' ? '••••••' : String(r.value).slice(0, 40)}` });
  }

  // 3. Probe each field with a wrong-type value, then restore.
  let probes = 0;
  for (const f of fields) {
    const r = filled.get(f.selector);
    if (!r || !r.value || probes >= 12) continue;
    const probe = invalidProbe(r.purpose, f);
    if (!probe) continue;
    await gate();
    probes++;
    await probeField(pageURL, form, f, r, probe);
  }

  // 4. Realistic data must pass constraint validation (no submit).
  for (const f of fields) {
    const r = filled.get(f.selector);
    if (!r || !r.value || ['checkbox', 'radio', 'file'].includes(f.type)) continue;
    const st = await state(f.selector);
    if (st && !st.valid) {
      await record({ rule: 'rejects-valid-data', page: pageURL, selector: f.selector, locator: f.locator,
        evidence: `${fieldLabel(f)} rejected "${f.type === 'password' ? '(generated password)' : r.value}" (${st.flags.join(', ')}): ${st.validationMessage}`,
        steps: [openStep(pageURL), `Type "${f.type === 'password' ? 'a strong password' : r.value}" into ${f.selector}`],
        expected: 'Realistic value accepted', actual: st.validationMessage || st.flags.join(', ') }, { shot: true });
    }
  }

  // 5. Submit realistic data (only where allowed).
  if (!submitUsable) {
    const v = form.selector ? await evaluate((s) => window.__uia.formValidity(s), form.selector).catch(() => null) : null;
    emit({ type: 'step', message: `Not submitting "${formName}" (${!submit ? 'no submit button' : !canSubmit ? 'submission is off for this host' : 'button looks destructive'}); constraint validation ${v ? (v.valid ? 'passes' : `fails on ${v.invalid.length} field(s)`) : 'n/a'}` });
    return;
  }
  await gate();
  const r = await submitAndObserve(form, submit);
  if (r.validityBefore && !r.validityBefore.valid) {
    await record({ rule: 'submit-blocked-valid', page: pageURL, selector: r.validityBefore.invalid[0]?.selector || form.selector,
      evidence: `With realistic test data the browser blocked submission: ${r.validityBefore.invalid.map((x) => `${x.selector}: ${x.message}`).join('; ').slice(0, 300)}`,
      steps: [openStep(pageURL), 'Fill the form with realistic data', `Click "${submit.text}"`], expected: 'The form submits', actual: 'Blocked by validation' }, { shot: false });
  } else if (r.status >= 400) {
    await record({ rule: 'submit-server-error', page: pageURL, selector: submit.selector, locator: submit.locator, severity: r.status >= 500 ? 'high' : 'medium',
      evidence: `${r.sent} → HTTP ${r.status}`, steps: [openStep(pageURL), 'Fill the form with realistic data', `Click "${submit.text}"`],
      expected: 'A 2xx/3xx response and a success state', actual: `HTTP ${r.status}` }, { shot: false });
  } else if (!r.sent && !r.navigated && r.mutations === 0 && r.dialogs === 0) {
    await record({ rule: 'submit-no-feedback', page: pageURL, selector: submit.selector, locator: submit.locator,
      evidence: `Clicking "${submit.text}" with valid data sent nothing and changed nothing`,
      steps: [openStep(pageURL), 'Fill the form with realistic data', `Click "${submit.text}"`], expected: 'Confirmation, navigation or errors', actual: 'No reaction' });
  } else {
    emit({ type: 'step', message: `Submitted "${formName}": ${r.sent || 'no request'}${r.status ? ` → HTTP ${r.status}` : ''}` });
  }
}

async function probeField(pageURL, form, f, filled, probe) {
  const page = S.page;
  const loc = page.locator(f.selector).first();
  const before = await state(f.selector);
  try {
    await loc.fill(probe.value, { timeout: 2000 });
    await loc.blur().catch(() => {});
  } catch {
    return; // input type rejected the characters outright: fine
  }
  await page.waitForTimeout(350);
  const after = await state(f.selector);
  if (!after) return;
  const message = newText(before, after);
  const appFeedback = after.ariaInvalid === 'true' || !!message;
  const nativeRejects = !after.valid;
  const label = fieldLabel(f);
  const steps = [openStep(pageURL), `Type "${probe.value}" into ${label} (${f.selector})`, 'Press Tab to leave the field'];
  const caveat = submitAllowedFor(pageURL) ? '' : ' (submission was off, so submit-time/server validation was not exercised)';
  if (!nativeRejects && !appFeedback) {
    const strong = ['email', 'phone', 'url'].includes(filled.purpose);
    await record({ rule: 'field-accepts-invalid', page: pageURL, selector: f.selector, locator: f.locator, severity: strong ? 'high' : 'medium', key: probe.value,
      title: `${label.slice(0, 40)} accepts "${probe.value}"`,
      evidence: `${label} (${filled.purpose}, type="${f.type}") accepted "${probe.value}": validity.valid=true, no aria-invalid, no error text${caveat}`,
      steps, expected: `Rejected: ${probe.expect}`, actual: 'Accepted silently' }, { shot: true });
  } else if (nativeRejects && !appFeedback && form.noValidate) {
    await record({ rule: 'validation-no-feedback', page: pageURL, selector: f.selector, locator: f.locator, key: probe.value,
      evidence: `${label} is invalid (${after.flags.join(', ')}) but the form has novalidate and shows no error text${caveat}`,
      steps, expected: 'Visible error next to the field', actual: 'No message' }, { shot: true });
  } else if (message) {
    const vague = message.length < 12 || /^(invalid|error|wrong|required|not valid|invalid (input|value|field|data)|this field is invalid|please check( this field)?|check (this|your) input|field error)[.!]?$/i.test(message);
    if (vague) {
      await record({ rule: 'validation-vague-message', page: pageURL, selector: f.selector, locator: f.locator, key: message,
        evidence: `Error shown for "${probe.value}" in ${label}: "${message.slice(0, 120)}"`, steps,
        expected: 'Message says what is wrong and how to fix it', actual: `"${message.slice(0, 80)}"` }, { shot: true });
    }
    if (!after.error.associated && !after.error.live && !after.error.associatedNear) {
      await record({ rule: 'validation-message-not-associated', page: pageURL, selector: f.selector, locator: f.locator,
        evidence: `"${message.slice(0, 100)}" appears near ${label} but is not referenced by aria-describedby/aria-errormessage and is not a live region${after.ariaInvalid === 'true' ? '' : '; aria-invalid is not set'}`,
        steps: [...steps, 'With VoiceOver on, move focus back to the field'], expected: 'The error is announced', actual: 'Screen readers do not announce it' }, { shot: false });
    }
  }
  // Restore the realistic value.
  try {
    await loc.fill(String(filled.value), { timeout: 2000 });
    await loc.blur().catch(() => {});
  } catch { /* ignore */ }
}

async function submitAndObserve(form, submit) {
  const page = S.page;
  const sent = [];
  const onReq = (req) => {
    if (req.method() !== 'GET' || (req.isNavigationRequest() && req.frame() === page.mainFrame())) sent.push(req);
  };
  page.on('request', onReq);
  const validityBefore = await evaluate((s) => window.__uia.formValidity(s), form.selector).catch(() => null);
  const startURL = page.url();
  const dialogs = S.dialogs;
  await evaluate(() => window.__uia.startWatch()).catch(() => {});
  let navigated = false;
  const nav = page.waitForEvent('framenavigated', { predicate: (fr) => fr === page.mainFrame(), timeout: 4000 }).then(() => { navigated = true; }).catch(() => {});
  try {
    await page.locator(submit.selector).first().click({ timeout: 3000 });
  } catch (e) {
    log(`Could not click submit ${submit.selector}: ${e.message.split('\n')[0]}`, 'warn');
  }
  await Promise.race([nav, sleep(2500)]);
  await settle(page, 3000);
  const after = await evaluate(() => window.__uia.stopWatch()).catch(() => null);
  page.off('request', onReq);
  let status = 0;
  for (const req of sent) {
    const resp = await req.response().catch(() => null);
    if (resp) status = Math.max(status, resp.status());
  }
  const first = sent[0];
  return {
    validityBefore, navigated: navigated || page.url() !== startURL || !after, mutations: after ? after.mutations : 1,
    dialogs: S.dialogs - dialogs, status, sent: first ? `${first.method()} ${first.url().slice(0, 160)}` : '',
  };
}

// ---------------------------------------------------------------------------
// Dead buttons

async function auditDeadButtons(pageURL, depth) {
  const page = S.page;
  await reloadIfNeeded(pageURL);
  const cands = await evaluate(() => window.__uia.buttonCandidates()).catch(() => []);
  if (!cands.length) return;
  emit({ type: 'step', message: `Clicking up to ${Math.min(cands.length, S.cfg.maxButtonsPerPage)} button(s)` });
  let tested = 0;
  for (const c of cands) {
    if (tested >= S.cfg.maxButtonsPerPage) break;
    if (c.dangerous && !S.cfg.allowDangerous) { S.skippedDangerous.push({ page: pageURL, selector: c.selector, text: c.text }); continue; }
    if (!c.selector) continue;
    await gate();
    await reloadIfNeeded(pageURL);
    const loc = page.locator(c.selector).first();
    if (!(await loc.isVisible().catch(() => false))) continue;
    tested++;
    const before = await evaluate(() => window.__uia.startWatch()).catch(() => null);
    if (!before) continue;
    const req0 = S.requests, dlg0 = S.dialogs, pop0 = S.popups;
    try {
      await loc.click({ timeout: 2500 });
    } catch (e) {
      log(`Skipped ${c.selector}: ${e.message.split('\n')[0].slice(0, 100)}`);
      continue;
    }
    await page.waitForTimeout(700);
    const after = await evaluate(() => window.__uia.stopWatch()).catch(() => null);
    const urlNow = page.url();
    // A bare hash change (href="#") is not a reaction by itself.
    const navigated = !after || normURL(after.url) !== normURL(before.url);
    const changed = navigated || after.mutations > 0 || after.scrollY !== before.scrollY || after.dialogs !== before.dialogs
      || S.requests > req0 || S.dialogs > dlg0 || S.popups > pop0;
    if (!changed) {
      await record({ rule: 'dead-button', page: pageURL, selector: c.selector, locator: c.locator,
        evidence: `Clicked ${c.tag} "${c.text.slice(0, 60)}": no DOM change, navigation, scroll, dialog, request or new tab within 700ms`,
        steps: [openStep(pageURL), `Click "${c.text.slice(0, 60)}" (${c.selector})`], expected: 'Something happens', actual: 'Nothing happens' });
    }
    if (navigated && normURL(urlNow) !== normURL(pageURL)) {
      enqueue(urlNow, depth + 1, pageURL);
      await reloadIfNeeded(pageURL);
    } else {
      await page.keyboard.press('Escape').catch(() => {});
    }
  }
}

// ---------------------------------------------------------------------------
// Report

function buildReport() {
  const cfg = S.cfg;
  const finished = new Date();
  const findings = sortFindings(S.findings);
  return {
    meta: {
      tool: 'SparkV UI audit', version: VERSION, playwright: require('playwright-core/package.json').version,
      axe: require('axe-core/package.json').version,
      startURL: cfg.startURL, mode: cfg.mode, modeLabel: MODES[cfg.mode].label, allowedOrigins: cfg.allowedOrigins,
      maxPages: cfg.maxPages, maxDepth: cfg.maxDepth, viewports: cfg.viewports,
      submitPolicy: cfg.allowSubmit ? 'allowed (user enabled)' : isTestHost(new URL(cfg.startURL).hostname) ? 'allowed (local/test host)' : 'off (fields filled and validated, nothing submitted)',
      dangerousClicks: cfg.allowDangerous ? 'allowed (user enabled)' : 'blocked',
      startedAt: S.startedAt.toISOString(), finishedAt: finished.toISOString(), durationMs: finished - S.startedAt,
      stopped: S.stopping && S.stopReason !== 'done', stopReason: S.stopReason, outDir: cfg.outDir,
    },
    summary: summarize(findings),
    pages: S.pages,
    findings,
    safety: {
      blocked: S.blocked, skippedDangerous: S.skippedDangerous, externalLinks: [...S.externalLinks].slice(0, 200),
      sensitiveFields: S.sensitiveFields, dialogsDismissed: S.dialogs, popupsClosed: S.popups,
    },
  };
}

// ---------------------------------------------------------------------------

function listenForCommands() {
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    const cmd = line.trim().toLowerCase();
    if (cmd === 'pause' || cmd === 'takeover') { S.paused = true; log('Paused: you have control of the browser window. Resume when done.'); emit({ type: 'state', state: 'paused' }); }
    else if (cmd === 'resume') { S.paused = false; emit({ type: 'state', state: 'running' }); }
    else if (cmd === 'stop') stop('stopped by user');
  });
  // With --stdin-control the app owns this process: if it goes away (stdin
  // closes), stop and write what we have instead of crawling on alone.
  rl.on('close', () => { if (S.cfg.stdinControl) stop('controller closed'); });
}

async function main() {
  let cfg;
  try {
    cfg = loadConfig();
  } catch (e) {
    emit({ type: 'error', fatal: true, message: e.message });
    process.exitCode = 2;
    return;
  }
  S.cfg = cfg;
  S.tag = S.rand.tag();
  S.deadline = Date.now() + cfg.maxRunSeconds * 1000;
  S.axeSource = fs.readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8');
  fs.mkdirSync(path.join(cfg.outDir, 'screenshots'), { recursive: true });

  const finalize = async () => {
    const report = buildReport();
    const paths = writeReport(cfg.outDir, report);
    emit({ type: 'done', ...paths, outDir: cfg.outDir, summary: report.summary, pages: report.pages.length,
      stopped: report.meta.stopped, stopReason: report.meta.stopReason, durationMs: report.meta.durationMs });
  };
  let finalized = false;
  const onSignal = (sig) => {
    stop(`stopped by user (${sig})`);
    setTimeout(async () => {
      if (!finalized) { finalized = true; try { await finalize(); } catch { /* ignore */ } }
      process.exit(130);
    }, 4000).unref();
  };
  process.on('SIGTERM', () => onSignal('SIGTERM'));
  process.on('SIGINT', () => onSignal('SIGINT'));
  listenForCommands();

  const host = new URL(cfg.startURL).hostname;
  emit({
    type: 'plan', startURL: cfg.startURL, mode: cfg.mode, modeLabel: MODES[cfg.mode].label, checks: [...cfg.checks],
    allowedOrigins: cfg.allowedOrigins, maxPages: cfg.maxPages, maxDepth: cfg.maxDepth, outDir: cfg.outDir,
    submission: cfg.allowSubmit || isTestHost(host) ? 'allowed' : 'off', dangerousClicks: cfg.allowDangerous ? 'allowed' : 'blocked',
    headless: !!cfg.headless,
  });

  // Hard cap: gate() enforces the deadline between actions, but a hung
  // browser call must not keep the run (and its window) alive past it.
  setTimeout(() => {
    stop('time limit reached');
    setTimeout(async () => {
      if (!finalized) { finalized = true; try { await finalize(); } catch { /* ignore */ } }
      S.closing = true;
      await S.browser?.close().catch(() => {});
      process.exit(0);
    }, 15000).unref();
  }, cfg.maxRunSeconds * 1000 + 30000).unref();

  try {
    await launch();
  } catch (e) {
    // No browser, nothing audited: report a fatal error instead of an empty
    // "0 pages" report that would replace the last real one.
    emit({ type: 'error', fatal: true, message: `Couldn't start the browser: ${e.message.split('\n')[0]}` });
    S.closing = true;
    await S.browser?.close().catch(() => {});
    process.exit(3);
  }
  try {
    emit({ type: 'state', state: 'running' });
    await crawl();
    if (!S.stopping) S.stopReason = 'done';
  } catch (e) {
    if (!(e instanceof StopError) && !S.stopping) {
      emit({ type: 'error', fatal: false, message: e.message.split('\n')[0] });
      S.stopping = true;
      S.stopReason = `error: ${e.message.split('\n')[0].slice(0, 120)}`;
    }
  } finally {
    flushPageSignals();
    if (!finalized) { finalized = true; await finalize().catch((e) => emit({ type: 'error', fatal: true, message: `Report failed: ${e.message}` })); }
    S.closing = true;
    await S.browser?.close().catch(() => {});
  }
  process.exit(0);
}

main();
