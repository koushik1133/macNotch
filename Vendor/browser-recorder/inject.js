// SparkV Browser Task Recorder: in-page script (MIT).
// Injected with context.addInitScript into every page. Provides:
//   window.__nir.describe(el)   -> { selectors[], fingerprint, title }
//   window.__nir.heal(fp, kind) -> marks the best fuzzy match with data-nir-heal, returns {token, score, second}
// and, only while recording (window.__nirRecording === true and the __nirEmit
// binding exists), listens for trusted user events and emits steps.
// Password-like fields: the value is never read.
(() => {
  if (window.__nir) return;

  const TESTID_ATTRS = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-cy'];
  const OVERLAY_TAG = 'nir-recorder-overlay';
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const clip = (s, n = 80) => { s = norm(s); return s.length > n ? s.slice(0, n) : s; };
  const cssEscape = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&');

  // ---------- roles & accessible names (simplified accname) ----------
  const INPUT_ROLES = {
    button: 'button', submit: 'button', reset: 'button', image: 'button',
    checkbox: 'checkbox', radio: 'radio', range: 'slider', search: 'searchbox',
    email: 'textbox', tel: 'textbox', text: 'textbox', url: 'textbox', password: 'textbox', number: 'spinbutton',
  };
  function roleOf(el) {
    const explicit = norm(el.getAttribute('role')).split(' ')[0];
    if (explicit) return explicit;
    const tag = el.tagName.toLowerCase();
    switch (tag) {
      case 'a': return el.hasAttribute('href') ? 'link' : null;
      case 'button': return 'button';
      case 'select': return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
      case 'textarea': return 'textbox';
      case 'input': {
        const t = (el.getAttribute('type') || 'text').toLowerCase();
        if (t === 'hidden' || t === 'file') return null;
        if (t === 'password') return null; // Playwright getByRole has no role for password inputs
        if ((t === 'text' || t === 'search' || t === 'email' || t === 'tel' || t === 'url') && el.hasAttribute('list')) return 'combobox';
        return INPUT_ROLES[t] || 'textbox';
      }
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
      case 'img': return el.getAttribute('alt') === '' ? null : 'img';
      case 'li': return 'listitem';
      case 'option': return 'option';
      case 'summary': return 'button';
      case 'nav': return 'navigation';
      case 'dialog': return 'dialog';
      case 'tr': return 'row';
      case 'td': return 'cell';
      default: return null;
    }
  }
  function labelText(el) {
    const lb = el.getAttribute('aria-labelledby');
    if (lb) {
      const t = lb.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => n.innerText || n.textContent).join(' ');
      if (norm(t)) return clip(t);
    }
    if (el.labels && el.labels.length) {
      const t = Array.from(el.labels).map((l) => l.innerText || l.textContent).join(' ');
      if (norm(t)) return clip(t);
    }
    return '';
  }
  function accessibleName(el) {
    const aria = el.getAttribute('aria-label');
    if (norm(aria)) return clip(aria);
    const lbl = labelText(el);
    if (lbl) return lbl;
    const tag = el.tagName.toLowerCase();
    if (tag === 'input') {
      const t = (el.getAttribute('type') || 'text').toLowerCase();
      if (['button', 'submit', 'reset'].includes(t)) return clip(el.value || (t === 'submit' ? 'Submit' : t === 'reset' ? 'Reset' : ''));
      if (t === 'image') return clip(el.getAttribute('alt') || el.getAttribute('title') || '');
      return clip(el.getAttribute('title') || el.getAttribute('placeholder') || '');
    }
    if (tag === 'img') return clip(el.getAttribute('alt') || el.getAttribute('title') || '');
    if (tag === 'textarea' || tag === 'select') return clip(el.getAttribute('title') || el.getAttribute('placeholder') || '');
    const text = norm(el.innerText || el.textContent);
    if (text) return clip(text);
    const img = el.querySelector && el.querySelector('img[alt]');
    if (img) return clip(img.getAttribute('alt'));
    return clip(el.getAttribute('title') || '');
  }

  // ---------- sensitive fields ----------
  const SENSITIVE = /(pass(word|wd|code|phrase)?|pwd|secret|token|otp|one-time|2fa|mfa|cvv|cvc|csc|security.?code|card.?num|cc-?(number|csc|exp)|iban|ssn|social.?security|pin\b|api.?key|access.?key|private.?key|seed.?phrase|recovery.?(code|phrase))/i;
  function sensitivity(el) {
    if (!el || el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return null;
    const type = (el.getAttribute('type') || '').toLowerCase();
    if (type === 'password') return 'password';
    const hay = [el.getAttribute('autocomplete'), el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder')].filter(Boolean).join(' ');
    if (/current-password|new-password/i.test(hay)) return 'password';
    if (SENSITIVE.test(hay)) return 'secret';
    return null;
  }

  // ---------- selector candidates ----------
  function isUnique(sel) { try { return document.querySelectorAll(sel).length === 1; } catch { return false; } }
  const looksGenerated = (s) => /\d{4,}|[a-f0-9]{8,}|^(ember|react|radix|headlessui|mui|:r)/i.test(s) || s.length > 40;
  function cssPath(el) {
    const parts = [];
    let cur = el;
    while (cur && cur.nodeType === 1 && cur !== document.documentElement) {
      const tag = cur.tagName.toLowerCase();
      if (cur.id && !looksGenerated(cur.id) && isUnique('#' + cssEscape(cur.id))) { parts.unshift('#' + cssEscape(cur.id)); break; }
      let part = tag;
      const parent = cur.parentElement;
      if (parent) {
        const same = Array.from(parent.children).filter((c) => c.tagName === cur.tagName);
        if (same.length > 1) part += `:nth-of-type(${same.indexOf(cur) + 1})`;
      }
      parts.unshift(part);
      cur = parent;
    }
    return parts.join(' > ');
  }
  function textOf(el) {
    const tag = el.tagName.toLowerCase();
    if (['input', 'textarea', 'select'].includes(tag)) return '';
    return clip(el.innerText || el.textContent, 120);
  }
  function selectorsFor(el) {
    const out = [];
    const push = (c) => { if (!out.some((o) => JSON.stringify(o) === JSON.stringify(c))) out.push(c); };
    for (const a of TESTID_ATTRS) {
      const v = el.getAttribute(a);
      if (v) { push({ kind: 'testid', attr: a, value: v }); break; }
    }
    const role = roleOf(el);
    const name = accessibleName(el);
    if (role && name) push({ kind: 'role', role, name });
    const lbl = labelText(el) || (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) ? norm(el.getAttribute('aria-label')) : '');
    if (lbl) push({ kind: 'label', text: lbl });
    const ph = norm(el.getAttribute('placeholder'));
    if (ph) push({ kind: 'placeholder', text: ph });
    const text = textOf(el);
    if (text && text.length <= 60 && !['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)) push({ kind: 'text', text });
    const alt = norm(el.getAttribute('alt'));
    if (alt) push({ kind: 'alt', text: alt });
    const title = norm(el.getAttribute('title'));
    if (title) push({ kind: 'title', text: title });
    if (el.id && !looksGenerated(el.id) && isUnique('#' + cssEscape(el.id))) push({ kind: 'css', value: '#' + cssEscape(el.id) });
    const nm = el.getAttribute('name');
    if (nm) { const s = `${el.tagName.toLowerCase()}[name="${nm.replace(/"/g, '\\"')}"]`; if (isUnique(s)) push({ kind: 'css', value: s }); }
    const cls = Array.from(el.classList).filter((c) => !looksGenerated(c)).slice(0, 3);
    if (cls.length) { const s = el.tagName.toLowerCase() + cls.map((c) => '.' + cssEscape(c)).join(''); if (isUnique(s)) push({ kind: 'css', value: s }); }
    push({ kind: 'css', value: cssPath(el) });
    return out;
  }
  function fingerprint(el) {
    const attrs = {};
    for (const a of ['name', 'type', 'href', 'placeholder', 'aria-label', 'title', 'alt', 'for', ...TESTID_ATTRS]) {
      const v = el.getAttribute(a);
      if (v != null && v !== '') attrs[a] = a === 'href' ? v.replace(/^https?:\/\/[^/]+/, '') : clip(v, 120);
    }
    const path = [];
    for (let p = el.parentElement; p && p !== document.body && path.length < 12; p = p.parentElement) path.unshift(p.tagName.toLowerCase());
    const r = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      role: roleOf(el) || '',
      name: accessibleName(el),
      text: textOf(el),
      label: labelText(el),
      id: el.id || '',
      classes: Array.from(el.classList).slice(0, 8),
      attrs,
      path,
      rect: { x: Math.round(r.x + scrollX), y: Math.round(r.y + scrollY), w: Math.round(r.width), h: Math.round(r.height) },
    };
  }

  // ---------- similarity (Healenium-inspired weighted scoring) ----------
  function lev(a, b) {
    if (a === b) return 0;
    if (!a.length) return b.length; if (!b.length) return a.length;
    let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
    for (let i = 1; i <= a.length; i++) {
      const cur = [i];
      for (let j = 1; j <= b.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
      prev = cur;
    }
    return prev[b.length];
  }
  function strSim(a, b) {
    a = norm(a).toLowerCase(); b = norm(b).toLowerCase();
    if (!a && !b) return 1; if (!a || !b) return 0;
    if (a === b) return 1;
    const l = 1 - lev(a.slice(0, 120), b.slice(0, 120)) / Math.max(Math.min(a.length, 120), Math.min(b.length, 120));
    const ta = new Set(a.split(/[^a-z0-9]+/).filter(Boolean)), tb = new Set(b.split(/[^a-z0-9]+/).filter(Boolean));
    const inter = [...ta].filter((t) => tb.has(t)).length;
    const jac = (ta.size || tb.size) ? inter / new Set([...ta, ...tb]).size : 0;
    const contains = (a.includes(b) || b.includes(a)) ? 0.85 : 0;
    return Math.max(l, jac, contains);
  }
  function lcsRatio(a, b) {
    if (!a.length && !b.length) return 1;
    const dp = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
    for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++) dp[i][j] = a[i - 1] === b[j - 1] ? dp[i - 1][j - 1] + 1 : Math.max(dp[i - 1][j], dp[i][j - 1]);
    return dp[a.length][b.length] / Math.max(a.length, b.length);
  }
  function score(fp, el) {
    const cur = fingerprint(el);
    let total = 0, got = 0;
    const add = (w, s, present = true) => { if (!present) return; total += w; got += w * s; };
    add(1.5, cur.tag === fp.tag ? 1 : 0);
    add(1.5, cur.role === fp.role ? 1 : 0, !!fp.role);
    add(3, strSim(fp.name, cur.name), !!fp.name);
    add(2, strSim(fp.text, cur.text), !!fp.text);
    add(2, strSim(fp.label, cur.label), !!fp.label);
    add(1, strSim(fp.id, cur.id), !!fp.id);
    if (fp.classes && fp.classes.length) {
      const a = new Set(fp.classes), b = new Set(cur.classes);
      add(1, [...a].filter((c) => b.has(c)).length / new Set([...a, ...b]).size);
    }
    for (const [k, v] of Object.entries(fp.attrs || {})) add(k === 'type' ? 1 : 1.5, strSim(v, cur.attrs[k] || ''));
    add(1, lcsRatio(fp.path || [], cur.path));
    if (fp.rect && fp.rect.w) {
      const d = Math.hypot(fp.rect.x - cur.rect.x, fp.rect.y - cur.rect.y);
      add(0.5, Math.max(0, 1 - d / 800));
    }
    return total ? got / total : 0;
  }
  function visible(el) {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const st = getComputedStyle(el);
    return st.visibility !== 'hidden' && st.display !== 'none' && Number(st.opacity) > 0.01;
  }
  const CANDIDATE_SEL = 'a,button,input,select,textarea,label,summary,[role],[onclick],[tabindex],[contenteditable=""],[contenteditable="true"],h1,h2,h3,h4,h5,h6,li,td,img,span,div,p';
  function heal(fp) {
    let best = null, bestScore = 0, second = 0;
    const els = document.querySelectorAll(fp.tag && ['input', 'select', 'textarea'].includes(fp.tag) ? 'input,select,textarea,[contenteditable]' : CANDIDATE_SEL);
    for (const el of els) {
      if (el.closest(OVERLAY_TAG) || !visible(el)) continue;
      // Skip big containers whose text just includes the target's text.
      if (el.tagName === 'DIV' || el.tagName === 'SPAN' || el.tagName === 'P') { if (el.children.length > 3) continue; }
      const s = score(fp, el);
      if (s > bestScore) { second = bestScore; bestScore = s; best = el; } else if (s > second) second = s;
    }
    if (!best) return null;
    document.querySelectorAll('[data-nir-heal]').forEach((n) => n.removeAttribute('data-nir-heal'));
    const token = Math.random().toString(36).slice(2, 10);
    best.setAttribute('data-nir-heal', token);
    return { token, score: Number(bestScore.toFixed(3)), second: Number(second.toFixed(3)) };
  }

  function titleFor(type, el, extra) {
    const n = accessibleName(el) || norm(el.getAttribute('placeholder')) || el.tagName.toLowerCase();
    switch (type) {
      case 'click': return `Click “${clip(n, 40)}”`;
      case 'dblclick': return `Double-click “${clip(n, 40)}”`;
      case 'fill': return `Type into “${clip(n, 40)}”`;
      case 'select': return `Select “${clip(extra || '', 30)}” in “${clip(n, 30)}”`;
      case 'check': return `Check “${clip(n, 40)}”`;
      case 'uncheck': return `Uncheck “${clip(n, 40)}”`;
      case 'upload': return `Upload to “${clip(n, 40)}”`;
      case 'press': return `Press ${extra} in “${clip(n, 30)}”`;
      case 'waitFor': return `Wait for “${clip(n, 40)}”`;
      default: return type;
    }
  }
  function describe(el) { return { selectors: selectorsFor(el), fingerprint: fingerprint(el), title: titleFor('click', el) }; }

  window.__nir = { describe, heal, score, fingerprint, selectorsFor, accessibleName, sensitivity, version: 1 };

  // ---------------------------------------------------------------------
  // Recording (top frame only)
  // ---------------------------------------------------------------------
  if (window !== window.top || window.__nirRecording !== true) return;

  let overlay = null, countEl = null, pickMode = false, hoverBox = null;
  const emit = async (step) => {
    if (typeof window.__nirEmit !== 'function') return;
    try { const n = await window.__nirEmit(step); if (countEl && typeof n === 'number') countEl.textContent = `${n} step${n === 1 ? '' : 's'}`; } catch {}
  };
  const inOverlay = (e) => e.composedPath().some((n) => n && n.tagName && n.tagName.toLowerCase() === OVERLAY_TAG);
  const isTextField = (el) => {
    if (el.isContentEditable) return true;
    if (el.tagName === 'TEXTAREA') return true;
    if (el.tagName !== 'INPUT') return false;
    const t = (el.getAttribute('type') || 'text').toLowerCase();
    return !['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'file', 'range', 'color', 'hidden'].includes(t);
  };
  const actionable = (el) => {
    const hit = el.closest('a,button,input,select,textarea,label,summary,[role=button],[role=link],[role=menuitem],[role=tab],[role=option],[role=checkbox],[role=radio],[role=switch],[onclick],[tabindex]');
    return hit || el;
  };
  function base(type, el, extra) {
    const d = describe(el);
    return { type, selectors: d.selectors, fingerprint: d.fingerprint, title: titleFor(type, el, extra), url: location.href };
  }

  document.addEventListener('click', (e) => {
    if (!e.isTrusted || inOverlay(e)) return;
    let el = e.target instanceof Element ? e.target : null;
    if (!el) return;
    if (pickMode) {
      e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
      setPick(false);
      emit({ ...base('waitFor', el), timeout: 15000 });
      return;
    }
    el = actionable(el);
    if (isTextField(el)) return;                       // covered by fill
    if (el.tagName === 'SELECT' || el.tagName === 'OPTION') return; // covered by select
    if (el.tagName === 'INPUT' && ['checkbox', 'radio', 'file'].includes((el.type || '').toLowerCase())) return; // change handler
    if (el.tagName === 'LABEL' && el.control) return; // focusing / toggling its control is recorded by input/change
    if (e.detail === 2) return; // dblclick handler records it
    emit({ ...base('click', el), button: e.button, modifiers: [e.altKey && 'Alt', e.ctrlKey && 'Control', e.metaKey && 'Meta', e.shiftKey && 'Shift'].filter(Boolean) });
  }, true);

  document.addEventListener('dblclick', (e) => {
    if (!e.isTrusted || inOverlay(e) || pickMode) return;
    const el = e.target instanceof Element ? actionable(e.target) : null;
    if (!el || isTextField(el)) return;
    emit({ ...base('dblclick', el), replacesPrevious: 'click' });
  }, true);

  document.addEventListener('input', (e) => {
    if (!e.isTrusted || inOverlay(e)) return;
    const el = e.target;
    if (!(el instanceof Element) || !isTextField(el)) return;
    const sens = sensitivity(el);
    const step = base('fill', el);
    if (sens) { step.masked = true; step.value = sens === 'password' ? '{{password}}' : '{{secret}}'; }
    else step.value = el.isContentEditable ? (el.innerText || '') : el.value; // never read for masked fields
    step.coalesce = true;
    emit(step);
  }, true);

  // A native <select> popup (macOS) may commit its choice with an untrusted
  // change event; accept it only for the control the user just touched.
  let touched = null, touchedAt = 0;
  for (const type of ['pointerdown', 'keydown', 'focusin']) {
    document.addEventListener(type, (e) => { if (e.isTrusted && e.target instanceof Element) { touched = e.target; touchedAt = Date.now(); } }, true);
  }
  document.addEventListener('change', (e) => {
    const el = e.target;
    if (!(el instanceof Element) || inOverlay(e)) return;
    const userTouched = el.tagName === 'SELECT' && touched && (touched === el || el.contains(touched)) && Date.now() - touchedAt < 15000;
    if (!e.isTrusted && !userTouched) return;
    if (el.tagName === 'SELECT') {
      const opts = Array.from(el.selectedOptions);
      const step = base('select', el, opts.map((o) => norm(o.label || o.text)).join(', '));
      step.options = opts.map((o) => ({ value: o.value, label: norm(o.label || o.text) }));
      emit(step);
    } else if (el.tagName === 'INPUT' && ['checkbox', 'radio'].includes((el.type || '').toLowerCase())) {
      emit({ ...base(el.checked ? 'check' : 'uncheck', el), checked: !!el.checked });
    } else if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'file') {
      const names = Array.from(el.files || []).map((f) => f.name);
      emit({ ...base('upload', el), fileNames: names, value: names.length > 1 ? '{{files}}' : '{{file}}' });
    }
  }, true);

  document.addEventListener('keydown', (e) => {
    if (!e.isTrusted || inOverlay(e)) return;
    if (!['Enter', 'Tab', 'Escape'].includes(e.key)) return;
    if (e.key === 'Escape' && pickMode) { setPick(false); return; }
    const el = e.target instanceof Element ? e.target : document.body;
    if (e.key === 'Enter' && el.tagName === 'TEXTAREA') return;
    if (e.key === 'Tab' && !isTextField(el)) return;
    const step = el === document.body ? { type: 'press', selectors: [], title: `Press ${e.key}`, url: location.href } : base('press', el, e.key);
    step.key = e.key;
    emit(step);
  }, true);

  let scrollTimer = null;
  window.addEventListener('scroll', (e) => {
    if (!e.isTrusted) return;
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => emit({ type: 'scroll', x: Math.round(scrollX), y: Math.round(scrollY), title: `Scroll to ${Math.round(scrollY)}`, url: location.href, coalesce: true, selectors: [] }), 600);
  }, { capture: true, passive: true });

  // ---------- overlay toolbar ----------
  function setPick(on) {
    pickMode = on;
    if (overlay) overlay.shadowRoot.querySelector('#wait').textContent = on ? 'Click an element… (Esc)' : 'Wait for element';
    if (!on && hoverBox) hoverBox.style.display = 'none';
  }
  document.addEventListener('mousemove', (e) => {
    if (!pickMode || !hoverBox || inOverlay(e)) return;
    const el = e.target instanceof Element ? e.target : null;
    if (!el) return;
    const r = el.getBoundingClientRect();
    Object.assign(hoverBox.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
  }, true);
  function mountOverlay() {
    if (overlay || !document.documentElement) return;
    overlay = document.createElement(OVERLAY_TAG);
    const root = overlay.attachShadow({ mode: 'open' });
    root.innerHTML = `<style>
      .bar{position:fixed;right:16px;bottom:16px;z-index:2147483647;display:flex;gap:6px;align-items:center;
        font:12px -apple-system,system-ui,sans-serif;color:#fff;background:rgba(20,20,24,.88);border:1px solid rgba(255,255,255,.15);
        border-radius:999px;padding:6px 8px 6px 12px;box-shadow:0 6px 24px rgba(0,0,0,.35);backdrop-filter:blur(12px)}
      .dot{width:8px;height:8px;border-radius:50%;background:#ff453a;animation:p 1.2s infinite}
      @keyframes p{50%{opacity:.35}}
      button{font:inherit;color:#fff;background:rgba(255,255,255,.12);border:0;border-radius:999px;padding:4px 10px;cursor:pointer}
      button:hover{background:rgba(255,255,255,.22)} #stop{background:#ff453a}
      .box{position:fixed;pointer-events:none;border:2px solid #0a84ff;background:rgba(10,132,255,.12);z-index:2147483646;display:none;border-radius:3px}
    </style><div class="box"></div><div class="bar"><span class="dot"></span><span>Recording</span><span id="count" style="opacity:.7">0 steps</span>
      <button id="wait">Wait for element</button><button id="stop">Stop</button></div>`;
    countEl = root.querySelector('#count');
    hoverBox = root.querySelector('.box');
    root.querySelector('#wait').addEventListener('click', () => setPick(!pickMode));
    root.querySelector('#stop').addEventListener('click', () => { if (typeof window.__nirEmit === 'function') window.__nirEmit({ type: 'control', action: 'stop' }); });
    document.documentElement.appendChild(overlay);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mountOverlay); else mountOverlay();
})();
