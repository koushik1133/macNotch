#!/usr/bin/env node
// SparkV Browser Task Recorder runner (MIT).
// Built on playwright-core (Apache-2.0, https://github.com/microsoft/playwright).
//
//   node runner.mjs check
//   node runner.mjs record --profile DIR [--url URL] [--headless] [--browser chromium|chrome]
//   node runner.mjs replay --flow FILE --profile DIR [--csv FILE] [--vars-stdin] [--allow-risky]
//                          [--shots DIR] [--step-timeout MS] [--continue-on-error] [--from STEP_ID] [--headless]
//   node runner.mjs risky --flow FILE
//
// Every stdout line is one JSON object (see PROTOCOL.md). stdin accepts JSON
// lines: {"vars":{...}} (first line, with --vars-stdin) and {"cmd":"stop"}.
// Closing stdin also stops: the runner never outlives the app that spawned it.

import { chromium } from 'playwright-core';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INJECT_PATH = path.join(HERE, 'inject.js');
export const LIMITS = { maxSteps: 2000, maxRows: 500, maxDelayMs: 120_000, maxRunMs: 60 * 60_000, attempts: 3 };
export const RISKY = /\b(buy|purchase|order|checkout|check[\s-]?out|pay|payment|place[\s-]?order|subscribe|donate|transfer|send[\s-]?money|wire|delete|remove|destroy|erase|wipe|unsubscribe|cancel[\s-]?(account|subscription)|close[\s-]?account)\b/i;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Date.now();
let stdoutEmit = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');
// stdout is an async pipe on macOS: exit only after the last line is written,
// or a large final event (`flow`, `done`) can be cut off.
function exitAfterFlush(code) {
  setTimeout(() => process.exit(code), 3000).unref();
  process.stdout.write('', () => process.exit(code));
}

// Thrown when the user stops a replay; never retried, never reported as a failure.
class StopError extends Error { constructor() { super('Stopped'); this.stopped = true; } }
// Races `promise` against the stop flag so a long wait (waitFor, delay, a slow
// locator) ends within ~150 ms of Stop. The losing promise is silenced.
async function untilStopped(promise, shouldStop) {
  promise.catch(() => {});
  let timer;
  const stop = new Promise((_, reject) => { timer = setInterval(() => { if (shouldStop()) reject(new StopError()); }, 150); });
  try { return await Promise.race([promise, stop]); } finally { clearInterval(timer); }
}

// ---------------------------------------------------------------- helpers
export function parseCSV(text) {
  text = text.replace(/^﻿/, '');
  const rows = []; let row = []; let field = ''; let q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; }
      else field += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(field); rows.push(row); row = []; field = ''; }
    else field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  const nonEmpty = rows.filter((r) => r.some((f) => f.trim() !== ''));
  if (!nonEmpty.length) return [];
  const header = nonEmpty[0].map((h) => h.trim());
  return nonEmpty.slice(1).map((r) => Object.fromEntries(header.map((h, i) => [h, r[i] ?? ''])));
}

export function substitute(s, vars) {
  if (typeof s !== 'string') return s;
  return s.replace(/\{\{\s*([\w.-]+)\s*\}\}/g, (m, k) => (Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : m));
}
export function variablesIn(flow) {
  const set = new Set();
  for (const st of flow.steps || []) {
    if (st.disabled) continue;
    for (const f of [st.value, st.url, ...(st.options || []).flatMap((o) => [o.value, o.label])]) if (typeof f === 'string') for (const m of f.matchAll(/\{\{\s*([\w.-]+)\s*\}\}/g)) set.add(m[1]);
  }
  return [...set];
}
export function riskyWords(flow) {
  const words = new Set();
  const scan = (s) => { if (typeof s !== 'string') return; const re = new RegExp(RISKY.source, 'gi'); for (const m of s.matchAll(re)) words.add(m[0].toLowerCase()); };
  scan(flow.name);
  for (const st of flow.steps || []) {
    if (st.disabled) continue;
    scan(st.title); scan(st.url); scan(st.value);
    for (const sel of st.selectors || []) { scan(sel.name); scan(sel.text); scan(sel.value); }
    if (st.fingerprint) { scan(st.fingerprint.name); scan(st.fingerprint.text); }
  }
  return [...words];
}
const hostOf = (u) => { try { return new URL(u).host; } catch { return u; } };
const targetKey = (st) => { const css = (st.selectors || []).filter((s) => s.kind === 'css'); return css.length ? css[css.length - 1].value : JSON.stringify(st.selectors?.[0] ?? null); };

function launchOptions({ headless, browser }) {
  const opts = {
    headless: !!headless,
    viewport: headless ? { width: 1280, height: 800 } : null,
    args: ['--no-first-run', '--no-default-browser-check'],
  };
  if (browser === 'chrome') opts.channel = 'chrome';
  return opts;
}

// ---------------------------------------------------------------- record
export async function startRecording({ profile, url, headless = false, browser = 'chromium', emit = stdoutEmit }) {
  fs.mkdirSync(profile, { recursive: true });
  const context = await chromium.launchPersistentContext(profile, launchOptions({ headless, browser }));
  const t0 = now();
  const steps = [];
  const pages = [];
  let lastActionAt = 0;
  let stopped = false;
  let resolveStopped;
  const stoppedPromise = new Promise((r) => { resolveStopped = r; });

  const pageIndex = (p) => { const i = pages.indexOf(p); return i < 0 ? 0 : i; };
  const push = (step) => {
    if (steps.length >= LIMITS.maxSteps) { emit({ type: 'warning', message: `Step limit (${LIMITS.maxSteps}) reached; ignoring further actions.` }); return steps.length; }
    step.id = randomUUID();
    step.t = now() - t0;
    steps.push(step);
    emit({ type: 'step', index: steps.length - 1, step });
    return steps.length;
  };

  function onNavigated(p, frameUrl) {
    if (stopped || !frameUrl || frameUrl === 'about:blank' || frameUrl.startsWith('chrome://') || frameUrl.startsWith('devtools://')) return;
    const pi = pageIndex(p);
    const last = steps[steps.length - 1];
    if (now() - lastActionAt < 2500) return; // caused by the previous click / Enter / submit
    if (last && last.type === 'navigate' && last.pageIndex === pi && now() - (t0 + last.t) < 2500) return; // redirect chain
    push({ type: 'navigate', url: frameUrl, pageIndex: pi, title: `Open ${hostOf(frameUrl)}`, selectors: [] });
  }
  function attach(p) {
    if (pages.includes(p)) return;
    pages.push(p);
    p.on('framenavigated', (frame) => { if (frame === p.mainFrame()) onNavigated(p, frame.url()); });
  }

  await context.exposeBinding('__nirEmit', (source, raw) => {
    if (stopped || !raw || typeof raw !== 'object') return steps.length;
    if (raw.type === 'control') { if (raw.action === 'stop') stop('overlay'); return steps.length; }
    const step = { ...raw, pageIndex: pageIndex(source.page) };
    // Only navigate steps need a full URL; elsewhere keep origin + path (query strings can hold tokens).
    if (step.url) { try { const u = new URL(step.url); step.pageURL = u.origin + u.pathname; } catch {} delete step.url; }
    const last = steps[steps.length - 1];
    if (step.type !== 'scroll') lastActionAt = now();
    if (step.coalesce && last && last.type === step.type && last.pageIndex === step.pageIndex &&
        (step.type === 'scroll' || targetKey(last) === targetKey(step))) {
      Object.assign(last, { value: step.value, x: step.x, y: step.y, title: step.title, masked: step.masked });
      delete last.coalesce;
      emit({ type: 'stepUpdated', index: steps.length - 1, step: last });
      return steps.length;
    }
    if (step.replacesPrevious && last && last.type === step.replacesPrevious && targetKey(last) === targetKey(step)) {
      steps.pop();
      emit({ type: 'stepRemoved', index: steps.length });
    }
    delete step.coalesce; delete step.replacesPrevious;
    if (step.masked) step.value = step.value === '{{secret}}' ? '{{secret}}' : '{{password}}'; // defense in depth
    return push(step);
  });
  await context.addInitScript({ content: 'window.__nirRecording = true;' });
  await context.addInitScript({ path: INJECT_PATH });

  context.pages().forEach(attach);
  context.on('page', attach);
  context.on('close', () => stop('browserClosed'));

  const first = context.pages()[0] ?? await context.newPage();
  attach(first);
  if (url) {
    push({ type: 'navigate', url, pageIndex: 0, title: `Open ${hostOf(url)}`, selectors: [] });
    lastActionAt = now();
    await first.goto(url, { waitUntil: 'domcontentloaded' }).catch((e) => emit({ type: 'warning', message: `Could not open ${url}: ${e.message}` }));
  }
  emit({ type: 'recording', profile, url: url || null });

  function buildFlow() {
    const startURL = steps.find((s) => s.type === 'navigate')?.url ?? null;
    const ts = now();
    return {
      schema: 1, id: randomUUID(),
      name: `${startURL ? hostOf(startURL) : 'Browser'} flow ${new Date(ts).toLocaleString()}`,
      createdAt: ts, updatedAt: ts, startURL, trigger: 'manual', defaults: {},
      steps: steps.map((s) => { const c = { ...s }; delete c.coalesce; return c; }),
    };
  }
  async function stop(reason = 'stop') {
    if (stopped) return stoppedPromise;
    stopped = true;
    const flow = buildFlow();
    emit({ type: 'flow', reason, flow });
    await context.close().catch(() => {});
    resolveStopped(flow);
    return stoppedPromise;
  }
  return { context, page: first, pages, steps, stop, stopped: stoppedPromise };
}

// ---------------------------------------------------------------- replay
function locatorFor(page, sel) {
  try {
    switch (sel.kind) {
      case 'testid': return page.locator(`[${sel.attr || 'data-testid'}=${JSON.stringify(sel.value)}]`);
      case 'role': return page.getByRole(sel.role, sel.name ? { name: sel.name, exact: true } : {});
      case 'label': return page.getByLabel(sel.text, { exact: true });
      case 'placeholder': return page.getByPlaceholder(sel.text, { exact: true });
      case 'text': return page.getByText(sel.text, { exact: true });
      case 'alt': return page.getByAltText(sel.text, { exact: true });
      case 'title': return page.getByTitle(sel.text, { exact: true });
      case 'css': return page.locator(sel.value);
      case 'xpath': return page.locator('xpath=' + sel.value);
      default: return null;
    }
  } catch { return null; }
}
const describeSel = (s) => s.kind === 'role' ? `role=${s.role}[name="${s.name}"]` : s.kind === 'css' ? `css=${s.value}` : s.kind === 'testid' ? `${s.attr}=${s.value}` : `${s.kind}="${s.text}"`;

async function ensureInjected(page) {
  const ok = await page.evaluate(() => !!window.__nir).catch(() => false);
  if (!ok) await page.addScriptTag({ path: INJECT_PATH }).catch(() => {});
}

async function waitForStable(page, timeout) {
  await page.waitForLoadState('domcontentloaded', { timeout }).catch(() => {});
  await page.waitForLoadState('networkidle', { timeout: 1500 }).catch(() => {});
  await page.evaluate(() => new Promise((resolve) => {
    let timer; const done = () => { obs.disconnect(); clearTimeout(cap); resolve(); };
    const obs = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, 300); });
    obs.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
    timer = setTimeout(done, 300);
    const cap = setTimeout(done, 3000);
  })).catch(() => {});
}

async function resolveTarget(page, step, timeout, allowHidden) {
  const sels = step.selectors || [];
  const start = now();
  const fuzzyAfter = start + Math.max(1200, timeout * 0.3);
  const deadline = start + timeout;
  let lastErr = '';
  for (;;) {
    for (let i = 0; i < sels.length; i++) {
      const loc = locatorFor(page, sels[i]);
      if (!loc) continue;
      let n = 0;
      try { n = await loc.count(); } catch (e) { lastErr = e.message; continue; }
      if (n === 1) {
        if (allowHidden || await loc.isVisible().catch(() => false)) return { loc, via: i === 0 ? 'primary' : 'fallback', selectorIndex: i };
      } else if (n > 1 && n <= 25 && step.fingerprint) {
        await ensureInjected(page);
        const scores = await loc.evaluateAll((els, fp) => els.map((el) => {
          const r = el.getBoundingClientRect();
          return (r.width > 0 && r.height > 0 && window.__nir) ? window.__nir.score(fp, el) : 0;
        }), step.fingerprint).catch(() => []);
        const order = scores.map((s, k) => [s, k]).sort((a, b) => b[0] - a[0]);
        if (order.length && order[0][0] >= 0.75 && (order.length < 2 || order[0][0] - order[1][0] >= 0.05)) {
          return { loc: loc.nth(order[0][1]), via: i === 0 ? 'primary' : 'fallback', selectorIndex: i, score: order[0][0] };
        }
      }
    }
    if (now() >= fuzzyAfter && step.fingerprint) {
      await ensureInjected(page);
      const h = await page.evaluate((fp) => window.__nir ? window.__nir.heal(fp) : null, step.fingerprint).catch(() => null);
      if (h && h.score >= 0.6 && h.score - h.second >= 0.04) {
        return { loc: page.locator(`[data-nir-heal="${h.token}"]`), via: 'fuzzy', selectorIndex: -1, score: h.score, runnerUp: h.second };
      }
    }
    if (now() >= deadline) throw new Error(`Element not found: ${step.title || step.type}${lastErr ? ` (${lastErr})` : ''}. Tried: ${sels.map(describeSel).join(' | ')}`);
    await sleep(250);
  }
}

export async function replayFlow(flow, opts) {
  const {
    profile, headless = false, browser = 'chromium', rows: csvRows = null, baseVars = {}, allowRisky = false,
    shotsDir = null, stepTimeout = 10_000, continueOnError = false, emit = stdoutEmit, shouldStop = () => false,
    fromStepId = null,
  } = opts;
  const t0 = now();
  if (!flow || !Array.isArray(flow.steps)) throw new Error('Invalid flow file');
  if (flow.steps.length > LIMITS.maxSteps) throw new Error(`Flow has more than ${LIMITS.maxSteps} steps`);
  // "Replay from here": earlier steps are skipped (and not checked for variables or risky words).
  const fromIndex = fromStepId ? flow.steps.findIndex((s) => s.id === fromStepId) : 0;
  if (fromIndex < 0) throw new Error('The step to start from is not in this flow');
  const checked = fromIndex > 0 ? { ...flow, steps: flow.steps.slice(fromIndex) } : flow;
  const words = riskyWords(checked);
  if (words.length && !allowRisky) {
    emit({ type: 'error', code: 'needsConfirmation', words, message: `Flow contains sensitive actions (${words.join(', ')}); confirm before replaying.` });
    return { ok: false, needsConfirmation: true, words };
  }
  const rows = (csvRows && csvRows.length ? csvRows : [{}]).slice(0, LIMITS.maxRows);
  const needed = variablesIn(checked);
  for (let r = 0; r < rows.length; r++) {
    const vars = { ...(flow.defaults || {}), ...baseVars, ...rows[r] };
    const missing = needed.filter((k) => !(k in vars));
    if (missing.length) {
      emit({ type: 'error', code: 'missingVariables', row: r, missing, message: `Missing values for ${missing.map((m) => `{{${m}}}`).join(', ')}${rows.length > 1 ? ` in row ${r + 1}` : ''}.` });
      return { ok: false, missing };
    }
  }

  fs.mkdirSync(profile, { recursive: true });
  const context = await chromium.launchPersistentContext(profile, launchOptions({ headless, browser }));
  await context.addInitScript({ path: INJECT_PATH });
  let pages = [];
  context.on('page', (p) => { if (!pages.includes(p)) pages.push(p); });

  const steps = flow.steps;
  const active = steps.map((s, i) => [s, i]).filter(([s, i]) => !s.disabled && i >= fromIndex);
  emit({ type: 'start', flowId: flow.id, name: flow.name, steps: active.length, rows: rows.length });
  let healedCount = 0, failedRows = 0, passedRows = 0, aborted = false;

  async function getPage(pi, create) {
    if (pages[pi] && !pages[pi].isClosed()) return pages[pi];
    if (create && pi >= pages.length) { const p = await context.newPage(); if (!pages.includes(p)) pages.push(p); return p; }
    const deadline = now() + stepTimeout;
    while (now() < deadline) { if (pages[pi] && !pages[pi].isClosed()) return pages[pi]; await sleep(100); }
    throw new Error(`Tab ${pi + 1} did not open`);
  }

  async function runStep(step, index, vars, attempt) {
    const pi = step.pageIndex || 0;
    const timeout = Math.min(step.timeout || stepTimeout, 120_000);
    const value = substitute(step.value ?? '', vars);
    if (step.type === 'delay') { await sleep(Math.max(0, Math.min(step.ms ?? 1000, LIMITS.maxDelayMs))); return {}; }
    if (step.type === 'comment') return {};
    const page = await getPage(pi, step.type === 'navigate');
    // Starting mid-flow on a fresh tab: open the page the step was recorded on.
    if (fromIndex > 0 && step.type !== 'navigate' && step.pageURL && page.url() === 'about:blank') {
      await page.goto(substitute(step.pageURL, vars), { waitUntil: 'domcontentloaded', timeout: Math.max(timeout, 30_000) });
      await waitForStable(page, timeout);
    }
    if (step.type === 'navigate') {
      await page.goto(substitute(step.url, vars), { waitUntil: 'domcontentloaded', timeout: Math.max(timeout, 30_000) });
      await waitForStable(page, timeout);
      return {};
    }
    if (step.type === 'scroll') { await page.evaluate(([x, y]) => window.scrollTo(x, y), [step.x || 0, step.y || 0]); await sleep(150); return {}; }
    if (step.type === 'waitText') { await page.getByText(value).first().waitFor({ state: 'visible', timeout }); return {}; }
    if (step.type === 'waitURL') {
      const deadline = now() + timeout;
      while (!page.url().includes(value)) { if (now() > deadline) throw new Error(`URL never contained “${value}”`); await sleep(200); }
      return {};
    }
    if (step.type === 'press' && !(step.selectors || []).length) { await page.keyboard.press(step.key || 'Enter'); await waitForStable(page, timeout); return {}; }

    const res = await resolveTarget(page, step, step.type === 'waitFor' ? timeout : Math.min(timeout, 15_000), step.type === 'upload');
    const loc = res.loc;
    const act = { timeout: Math.min(timeout, 10_000) };
    // Describe a healed target before acting on it: a click may navigate away.
    const healed = res.via === 'primary' ? null : await loc.evaluate((el) => window.__nir ? window.__nir.describe(el) : null).catch(() => null);
    switch (step.type) {
      case 'click': await loc.click({ ...act, button: ['left', 'middle', 'right'][step.button || 0] || 'left', modifiers: step.modifiers || [] }); break;
      case 'dblclick': await loc.dblclick(act); break;
      case 'hover': await loc.hover(act); break;
      case 'fill':
        if (/\{\{[\w.-]+\}\}/.test(value)) throw new Error(`No value for ${value}`);
        await loc.fill(value, act); break;
      case 'press': await loc.press(step.key || 'Enter', act); break;
      case 'select': {
        const opts2 = step.options || [];
        const subst = opts2.map((o) => ({ value: substitute(o.value, vars), label: substitute(o.label, vars) }));
        try { await loc.selectOption(subst.map((o) => ({ value: o.value })), act); }
        catch { await loc.selectOption(subst.map((o) => ({ label: o.label })), act); }
        break;
      }
      case 'check': await loc.setChecked(true, act); break;
      case 'uncheck': await loc.setChecked(false, act); break;
      case 'upload': {
        const files = value.split(/\n|\|/).map((f) => f.trim()).filter(Boolean);
        for (const f of files) if (!fs.existsSync(f)) throw new Error(`File not found: ${f}`);
        await loc.setInputFiles(files, act); break;
      }
      case 'waitFor': await loc.waitFor({ state: 'visible', timeout }); break;
      default: throw new Error(`Unknown step type ${step.type}`);
    }
    await waitForStable(page, timeout);
    if (res.via !== 'primary') {
      return { healed: { via: res.via, selectorIndex: res.selectorIndex, score: res.score ?? null, runnerUp: res.runnerUp ?? null, selectors: healed?.selectors?.filter((x) => !(x.kind === 'css' && x.value.includes('data-nir-heal'))) ?? null, fingerprint: healed?.fingerprint ?? null } };
    }
    return {};
  }

  try {
    for (let r = 0; r < rows.length && !aborted; r++) {
      const vars = { ...(flow.defaults || {}), ...baseVars, ...rows[r] };
      // Fresh tab set per row: keep the first page, close the rest.
      pages = context.pages().slice(0, 1);
      for (const p of context.pages().slice(1)) await p.close().catch(() => {});
      if (!pages.length) pages = [await context.newPage()];
      emit({ type: 'rowStart', row: r, rows: rows.length });
      let rowOK = true;
      for (const [step, index] of active) {
        if (shouldStop() || now() - t0 > LIMITS.maxRunMs) { aborted = true; rowOK = false; emit({ type: 'stopped', reason: shouldStop() ? 'user' : 'timeLimit' }); break; }
        emit({ type: 'stepStart', row: r, index, stepId: step.id, title: step.title || step.type });
        const st = now();
        let ok = false, lastError = null;
        for (let attempt = 1; attempt <= LIMITS.attempts && !shouldStop(); attempt++) {
          try {
            const out = await untilStopped(runStep(step, index, vars, attempt), shouldStop);
            if (out.healed) {
              healedCount++;
              emit({ type: 'healed', row: r, index, stepId: step.id, ...out.healed });
              if (out.healed.selectors) {
                const seen = new Set(); step.selectors = [...out.healed.selectors, ...(step.selectors || [])].filter((s) => { const k = JSON.stringify(s); if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 12);
                if (out.healed.fingerprint) step.fingerprint = out.healed.fingerprint;
              }
            }
            ok = true; break;
          } catch (e) {
            if (e?.stopped || shouldStop()) break;
            lastError = e;
            emit({ type: 'retry', row: r, index, attempt, message: String(e.message || e).split('\n')[0] });
            if (attempt < LIMITS.attempts) await sleep(400 * attempt);
          }
        }
        if (ok) { emit({ type: 'stepDone', row: r, index, stepId: step.id, ms: now() - st }); continue; }
        if (shouldStop()) { aborted = true; rowOK = false; emit({ type: 'stopped', reason: 'user' }); break; }
        let screenshot = null;
        if (shotsDir) {
          fs.mkdirSync(shotsDir, { recursive: true });
          screenshot = path.join(shotsDir, `row${r + 1}-step${index + 1}.png`);
          const p = pages[step.pageIndex || 0] || pages[0];
          await p?.screenshot({ path: screenshot, fullPage: true }).catch(() => { screenshot = null; });
        }
        emit({ type: 'stepFailed', row: r, index, stepId: step.id, title: step.title || step.type, message: String(lastError?.message || lastError || 'stopped').split('\n')[0], screenshot, optional: !!step.optional });
        if (step.optional) continue;
        rowOK = false; break;
      }
      if (rowOK) passedRows++; else failedRows++;
      emit({ type: 'rowDone', row: r, ok: rowOK });
      if (!rowOK && !continueOnError) break;
    }
  } finally {
    await context.close().catch(() => {});
  }
  const result = { ok: failedRows === 0 && !aborted, rows: rows.length, passedRows, failedRows, healed: healedCount, durationMs: now() - t0, stopped: aborted };
  emit({ type: 'done', ...result, flow: healedCount ? flow : undefined });
  return result;
}

// ---------------------------------------------------------------- CLI
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[k] = true; else { out[k] = next; i++; }
    } else out._.push(a);
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0];
  const stdinLines = [];
  let stdinWaiter = null;
  let stopRequested = false;
  let onStop = () => {};
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    let msg; try { msg = JSON.parse(line); } catch { return; }
    if (msg && msg.cmd === 'stop') { stopRequested = true; onStop(); return; }
    stdinLines.push(msg); if (stdinWaiter) { stdinWaiter(); stdinWaiter = null; }
  });
  rl.on('close', () => { if (!args['keep-alive-without-stdin']) { stopRequested = true; onStop(); } });
  process.on('SIGTERM', () => { stopRequested = true; onStop(); });
  process.on('SIGINT', () => { stopRequested = true; onStop(); });
  const nextStdin = async (ms) => { const end = now() + ms; while (!stdinLines.length && now() < end && !stopRequested) await new Promise((r) => { stdinWaiter = r; setTimeout(r, 200); }); return stdinLines.shift(); };

  if (cmd === 'check') {
    const exe = chromium.executablePath();
    const pkg = JSON.parse(fs.readFileSync(path.join(HERE, 'node_modules/playwright-core/package.json'), 'utf8'));
    stdoutEmit({ type: 'check', ok: fs.existsSync(exe), playwright: pkg.version, chromium: exe, node: process.version });
    return exitAfterFlush(0);
  }
  if (cmd === 'risky') {
    const flow = JSON.parse(fs.readFileSync(args.flow, 'utf8'));
    stdoutEmit({ type: 'risky', words: riskyWords(flow), variables: variablesIn(flow) });
    return exitAfterFlush(0);
  }
  if (!args.profile) throw new Error('--profile is required');
  if (cmd === 'record') {
    const rec = await startRecording({ profile: args.profile, url: typeof args.url === 'string' ? args.url : undefined, headless: !!args.headless, browser: args.browser || 'chromium' });
    onStop = () => rec.stop('stop');
    if (stopRequested) rec.stop('stop');
    await rec.stopped;
    return exitAfterFlush(0);
  }
  if (cmd === 'replay') {
    const flow = JSON.parse(fs.readFileSync(args.flow, 'utf8'));
    let baseVars = {};
    if (args['vars-stdin']) { const m = await nextStdin(10_000); if (m && m.vars && typeof m.vars === 'object') baseVars = m.vars; }
    if (typeof args.vars === 'string') baseVars = { ...baseVars, ...JSON.parse(fs.readFileSync(args.vars, 'utf8')) };
    const rows = typeof args.csv === 'string' ? parseCSV(fs.readFileSync(args.csv, 'utf8')) : null;
    if (rows && rows.length > LIMITS.maxRows) stdoutEmit({ type: 'warning', message: `CSV has ${rows.length} rows; only the first ${LIMITS.maxRows} run.` });
    const res = await replayFlow(flow, {
      profile: args.profile, headless: !!args.headless, browser: args.browser || 'chromium', rows, baseVars,
      allowRisky: !!args['allow-risky'], shotsDir: typeof args.shots === 'string' ? args.shots : null,
      stepTimeout: Number(args['step-timeout']) || 10_000, continueOnError: !!args['continue-on-error'],
      shouldStop: () => stopRequested, fromStepId: typeof args.from === 'string' ? args.from : null,
    });
    return exitAfterFlush(res.ok ? 0 : 1);
  }
  throw new Error(`Unknown command “${cmd ?? ''}”. Use check | record | replay | risky.`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  main().catch((e) => {
    const msg = String(e?.message || e);
    const code = /Executable doesn't exist|browserType\.launch/i.test(msg) ? 'browserMissing'
      : /ProcessSingleton|profile.*in use|SingletonLock/i.test(msg) ? 'profileInUse' : 'fatal';
    stdoutEmit({ type: 'error', code, message: msg.split('\n')[0] });
    exitAfterFlush(2);
  });
}
