// In-page helpers, installed into every document with context.addInitScript.
// Everything here is read-only inspection of the DOM, except highlight()
// (a temporary outline for screenshots) and the mutation counter used to
// decide whether a button did anything.

export function installHelpers() {
  if (window.__uia) return;
  const DANGER = /\b(pay|payment|purchase|buy( now)?|checkout|check out|place order|order now|confirm order|subscribe now|delete|remove|destroy|erase|cancel (my )?(subscription|plan|account|membership)|unsubscribe|deactivate|close (my )?account|transfer|send money|withdraw|wire|logout|log out|log-out|sign out|signout|sign-out)\b/i;

  const cssEscape = (s) => (window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c));
  const quote = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const isUnique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch { return false; } };
  const looksGenerated = (id) => /\d{5,}|^[a-f0-9-]{10,}$|^(ember|react-|radix-|headlessui-|mui-|:r|v-|ng-)/i.test(id) || id.includes(':');
  const textOf = (el) => (el ? (el.innerText || el.textContent || '') : '').replace(/\s+/g, ' ').trim();

  function selectorFor(el) {
    if (!(el instanceof Element)) return '';
    if (el.id && !looksGenerated(el.id)) { const s = '#' + cssEscape(el.id); if (isUnique(s)) return s; }
    for (const attr of ['data-testid', 'data-test', 'data-cy', 'data-qa']) {
      const v = el.getAttribute(attr);
      if (v) { const s = `[${attr}="${quote(v)}"]`; if (isUnique(s)) return s; }
    }
    const tag = el.tagName.toLowerCase();
    const name = el.getAttribute('name');
    if (name && /^(input|select|textarea|button|form|iframe)$/.test(tag)) {
      const s = `${tag}[name="${quote(name)}"]`;
      if (isUnique(s)) return s;
      if (tag === 'input' && el.type === 'radio') { const r = `${s}[value="${quote(el.value)}"]`; if (isUnique(r)) return r; }
    }
    if (tag === 'a' && el.getAttribute('href')) { const s = `a[href="${quote(el.getAttribute('href'))}"]`; if (isUnique(s)) return s; }
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && node !== document.documentElement) {
      let part = node.tagName.toLowerCase();
      if (node !== el && node.id && !looksGenerated(node.id) && isUnique('#' + cssEscape(node.id))) {
        parts.unshift('#' + cssEscape(node.id));
        const s = parts.join(' > ');
        if (isUnique(s)) return s;
        break;
      }
      const parent = node.parentElement;
      if (parent) {
        const same = Array.from(parent.children).filter((c) => c.tagName === node.tagName);
        if (same.length > 1) part += `:nth-of-type(${same.indexOf(node) + 1})`;
      }
      parts.unshift(part);
      const s = parts.join(' > ');
      if (isUnique(s)) return s;
      node = parent;
    }
    return parts.join(' > ');
  }

  function labelText(el) {
    const labels = el.labels ? Array.from(el.labels) : [];
    return labels.map((l) => {
      // A label wrapping the input also contains the input's own text (select options).
      const clone = l.cloneNode(true);
      clone.querySelectorAll('select, textarea, option').forEach((n) => n.remove());
      return (clone.textContent || '').replace(/\s+/g, ' ').trim();
    }).filter(Boolean).join(' ');
  }

  function accessibleName(el) {
    const lb = el.getAttribute('aria-labelledby');
    if (lb) {
      const t = lb.split(/\s+/).map((id) => textOf(document.getElementById(id))).join(' ').trim();
      if (t) return { name: t, source: 'aria-labelledby' };
    }
    const al = (el.getAttribute('aria-label') || '').trim();
    if (al) return { name: al, source: 'aria-label' };
    const tag = el.tagName.toLowerCase();
    if (/^(input|select|textarea|meter|progress|output)$/.test(tag)) {
      const l = labelText(el);
      if (l) return { name: l, source: 'label' };
      if (tag === 'input' && /^(submit|reset)$/.test(el.type)) return { name: el.value || (el.type === 'submit' ? 'Submit' : 'Reset'), source: 'value' };
      if (tag === 'input' && el.type === 'button' && el.value) return { name: el.value, source: 'value' };
      if (tag === 'input' && el.type === 'image' && el.getAttribute('alt')) return { name: el.getAttribute('alt'), source: 'alt' };
    } else if (tag === 'img') {
      const a = el.getAttribute('alt');
      if (a && a.trim()) return { name: a.trim(), source: 'alt' };
    } else {
      const t = textOf(el);
      if (t) return { name: t.slice(0, 120), source: 'content' };
      const img = el.querySelector('img[alt]:not([alt=""])');
      if (img) return { name: img.getAttribute('alt'), source: 'content' };
      const st = el.querySelector('svg title');
      if (st && textOf(st)) return { name: textOf(st), source: 'content' };
    }
    const title = (el.getAttribute('title') || '').trim();
    if (title) return { name: title, source: 'title' };
    const ph = (el.getAttribute('placeholder') || '').trim();
    if (ph && /^(input|textarea)$/.test(tag)) return { name: ph, source: 'placeholder' };
    return { name: '', source: '' };
  }

  function roleOf(el) {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit.split(/\s+/)[0];
    const tag = el.tagName.toLowerCase();
    if (tag === 'a' && el.hasAttribute('href')) return 'link';
    if (tag === 'button' || tag === 'summary') return 'button';
    if (tag === 'select') return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
    if (tag === 'textarea') return 'textbox';
    if (tag === 'img') return 'img';
    if (tag === 'input') {
      const t = (el.getAttribute('type') || 'text').toLowerCase();
      return ({ checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox',
        submit: 'button', button: 'button', reset: 'button', image: 'button' })[t] || 'textbox';
    }
    return '';
  }

  /** Playwright-style locator a coding agent can paste into a test. */
  function locatorFor(el) {
    const role = roleOf(el);
    const { name } = accessibleName(el);
    if (role && name) return `getByRole('${role}', { name: '${name.slice(0, 60).replace(/'/g, "\\'")}' })`;
    if (role) return `getByRole('${role}')`;
    return '';
  }

  function isVisible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none';
  }

  function isDangerous(el) {
    const bits = [textOf(el).slice(0, 200), el.getAttribute('aria-label'), el.getAttribute('title'),
      el.getAttribute('value'), el.id, el.getAttribute('name'), el.getAttribute('href'), el.getAttribute('formaction'),
      el.getAttribute('data-action')].filter(Boolean).join(' ').replace(/[_-]+/g, ' ');
    return DANGER.test(bits);
  }

  function describe(el) {
    return { selector: selectorFor(el), locator: locatorFor(el), tag: el.tagName.toLowerCase(), text: accessibleName(el).name.slice(0, 100) };
  }

  // ---- forms ---------------------------------------------------------------

  function markerText(f) {
    const parts = [labelText(f)];
    const lb = f.getAttribute('aria-labelledby');
    if (lb) parts.push(lb.split(/\s+/).map((id) => textOf(document.getElementById(id))).join(' '));
    // Text right before the field (common "Email *" + bare input layouts).
    const prev = f.previousElementSibling;
    if (prev && !/^(INPUT|SELECT|TEXTAREA|LABEL)$/.test(prev.tagName) && !(f.labels && Array.from(f.labels).includes(prev))) parts.push(textOf(prev).slice(0, 80));
    return Array.from(new Set(parts.map((x) => x.trim()).filter(Boolean))).join(' ');
  }

  function describeField(f) {
    const tag = f.tagName.toLowerCase();
    const type = tag === 'input' ? (f.getAttribute('type') || 'text').toLowerCase() : tag;
    const acc = accessibleName(f);
    const describedBy = (f.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean)
      .map((id) => textOf(document.getElementById(id))).join(' ').trim();
    const marker = markerText(f);
    return {
      selector: selectorFor(f), locator: locatorFor(f), tag, type,
      name: f.getAttribute('name') || '', id: f.id || '',
      label: labelText(f), accName: acc.name, accSource: acc.source,
      ariaLabel: f.getAttribute('aria-label') || '',
      placeholder: f.getAttribute('placeholder') || '', hasPlaceholderAttr: f.hasAttribute('placeholder'),
      autocomplete: f.getAttribute('autocomplete') || '', pattern: f.getAttribute('pattern') || '',
      min: f.getAttribute('min') || '', max: f.getAttribute('max') || '', step: f.getAttribute('step') || '',
      minLength: typeof f.minLength === 'number' ? f.minLength : -1, maxLength: typeof f.maxLength === 'number' ? f.maxLength : -1,
      required: !!f.required, ariaRequired: f.getAttribute('aria-required') === 'true',
      requiredMarker: /(^|\s|\S)\*|\brequired\b|\(req\.?\)/i.test(marker), markerText: marker.slice(0, 160),
      inputMode: f.getAttribute('inputmode') || '', title: f.getAttribute('title') || '',
      accept: f.getAttribute('accept') || '', multiple: !!f.multiple,
      disabled: !!f.disabled, readOnly: !!f.readOnly, visible: isVisible(f),
      labelVisible: f.labels ? Array.from(f.labels).some(isVisible) : false,
      describedBy,
      options: tag === 'select' ? Array.from(f.options).slice(0, 60).map((o) => ({ value: o.value, text: textOf(o) || o.label || '', disabled: o.disabled })) : null,
      checked: !!f.checked,
      dangerous: isDangerous(f) || (f.labels && Array.from(f.labels).some(isDangerous)),
    };
  }

  function isSubmitter(el) {
    const tag = el.tagName;
    if (tag === 'BUTTON') return (el.getAttribute('type') || 'submit').toLowerCase() === 'submit';
    return tag === 'INPUT' && /^(submit|image)$/i.test(el.type);
  }

  function collectForms() {
    const forms = Array.from(document.forms);
    const groups = forms.map((form) => ({ form, controls: Array.from(form.elements) }));
    const orphans = Array.from(document.querySelectorAll('input, select, textarea')).filter((f) => !f.form);
    if (orphans.length) groups.push({ form: null, controls: orphans });
    return groups.map(({ form, controls }, index) => {
      const fields = controls.filter((f) => /^(INPUT|SELECT|TEXTAREA)$/.test(f.tagName)
        && !(f.tagName === 'INPUT' && /^(hidden|submit|button|reset|image)$/i.test(f.type))).slice(0, 60);
      const submits = form ? controls.filter(isSubmitter) : [];
      const heading = form ? (form.getAttribute('aria-label') || textOf(form.querySelector('legend, h1, h2, h3, h4')) || '') : '';
      return {
        index, selector: form ? selectorFor(form) : null,
        action: form ? form.getAttribute('action') || '' : '', method: form ? (form.getAttribute('method') || 'get').toLowerCase() : '',
        noValidate: form ? form.noValidate : false, visible: form ? isVisible(form) : fields.some(isVisible),
        heading: heading.slice(0, 80),
        fields: fields.map(describeField),
        submits: submits.map((b) => ({ ...describe(b), disabled: !!b.disabled, dangerous: isDangerous(b), visible: isVisible(b) })),
      };
    });
  }

  function errorTextNear(f) {
    const ids = [...(f.getAttribute('aria-describedby') || '').split(/\s+/), ...(f.getAttribute('aria-errormessage') || '').split(/\s+/)].filter(Boolean);
    const associated = ids.map((id) => document.getElementById(id)).filter((e) => e && isVisible(e)).map(textOf).join(' ').trim();
    // The field's own wrapper: climb while it still contains only this control.
    let container = f.parentElement;
    for (let k = 0; k < 3 && container && container.parentElement; k++) {
      if (container.parentElement.querySelectorAll('input, select, textarea').length > 1) break;
      container = container.parentElement;
    }
    if (container && container.querySelectorAll('input, select, textarea').length > 1) container = null;
    // All visible text in the wrapper except labels and the control itself, so
    // a message appearing after a bad value is caught whatever its class name.
    let nearText = '';
    const nearEls = [];
    if (container) {
      const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
      const bits = [];
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        const parent = n.parentElement;
        if (!parent || !n.textContent.trim()) continue;
        if (parent.closest('label, option, select, textarea, script, style')) continue;
        if (f.labels && Array.from(f.labels).some((l) => l.contains(parent))) continue;
        if (!isVisible(parent)) continue;
        bits.push(n.textContent.trim());
        nearEls.push(parent);
      }
      nearText = bits.join(' ').replace(/\s+/g, ' ').trim();
    }
    const live = nearEls.some((e) => e.closest('[role=alert], [aria-live]'));
    const associatedNear = nearEls.some((e) => { const host = e.closest('[id]'); return host && ids.includes(host.id); });
    return { associated, near: nearText.slice(0, 300), live, associatedNear };
  }

  function fieldState(sel) {
    const f = document.querySelector(sel);
    if (!f) return null;
    const v = f.validity || {};
    const flags = ['valueMissing', 'typeMismatch', 'patternMismatch', 'rangeOverflow', 'rangeUnderflow', 'tooLong', 'tooShort', 'stepMismatch', 'badInput']
      .filter((k) => v[k]);
    return {
      valid: v.valid !== false, flags, validationMessage: f.validationMessage || '',
      ariaInvalid: f.getAttribute('aria-invalid') || '', value: f.type === 'password' ? '' : String(f.value ?? '').slice(0, 120),
      error: errorTextNear(f), alerts: alertsText(),
    };
  }

  function alertsText() {
    return Array.from(document.querySelectorAll('[role=alert], [aria-live=assertive], [aria-live=polite]')).filter(isVisible).map(textOf).join(' | ').slice(0, 400);
  }

  function formValidity(sel) {
    const form = sel ? document.querySelector(sel) : null;
    if (!form) return null;
    const invalid = Array.from(form.elements).filter((e) => e.willValidate && !e.checkValidity())
      .map((e) => ({ selector: selectorFor(e), message: e.validationMessage }));
    return { valid: invalid.length === 0, invalid };
  }

  // ---- page-level ------------------------------------------------------------

  function collectLinks() {
    return Array.from(document.querySelectorAll('a[href], area[href]')).slice(0, 800).map((a) => ({
      href: a.href, raw: a.getAttribute('href') || '', ...describe(a), dangerous: isDangerous(a), visible: isVisible(a),
      target: a.getAttribute('target') || '', download: a.hasAttribute('download'),
    }));
  }

  function brokenAnchors() {
    const out = [];
    for (const a of document.querySelectorAll('a[href^="#"]')) {
      const raw = a.getAttribute('href');
      if (!raw || raw === '#' || raw.startsWith('#!') || raw.startsWith('#/')) continue;
      const id = decodeURIComponent(raw.slice(1));
      if (!document.getElementById(id) && !document.getElementsByName(id).length) out.push({ ...describe(a), raw });
    }
    return out.slice(0, 20);
  }

  function imageIssues() {
    const out = [];
    for (const img of document.querySelectorAll('img, input[type=image], [role=img]')) {
      const hiddenFromAT = img.closest('[aria-hidden=true]') || /^(presentation|none)$/.test(img.getAttribute('role') || '');
      if (img.tagName === 'IMG') {
        if (!img.hasAttribute('alt') && !hiddenFromAT && !img.getAttribute('aria-label') && !img.getAttribute('aria-labelledby')) {
          out.push({ kind: 'missing-alt', ...describe(img), src: (img.currentSrc || img.src || '').slice(0, 200), visible: isVisible(img) });
        }
        if (img.complete && img.naturalWidth === 0 && (img.currentSrc || img.src) && !(img.currentSrc || img.src).startsWith('data:')) {
          out.push({ kind: 'broken', ...describe(img), src: (img.currentSrc || img.src).slice(0, 200), visible: isVisible(img) });
        }
      } else if (img.tagName === 'INPUT') {
        if (!img.getAttribute('alt') && !img.getAttribute('aria-label')) out.push({ kind: 'missing-alt', ...describe(img), src: img.src || '', visible: isVisible(img) });
      } else if (!accessibleName(img).name && !hiddenFromAT) {
        out.push({ kind: 'role-img-no-name', ...describe(img), src: '', visible: isVisible(img) });
      }
    }
    return out.slice(0, 40);
  }

  function inScrollContainer(el) {
    for (let p = el.parentElement; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
      const ox = getComputedStyle(p).overflowX;
      if (ox === 'hidden' || ox === 'auto' || ox === 'scroll' || ox === 'clip') return true;
    }
    return false;
  }

  function fixedOrSticky(el) {
    for (let p = el, k = 0; p && p !== document.body && k < 12; p = p.parentElement, k++) {
      const pos = getComputedStyle(p).position;
      if (pos === 'fixed' || pos === 'sticky') return true;
    }
    return false;
  }

  function overflow() {
    const de = document.documentElement;
    const cw = de.clientWidth;
    const sw = Math.max(de.scrollWidth, document.body ? document.body.scrollWidth : 0);
    const result = { clientWidth: cw, scrollWidth: sw, overflows: sw > cw + 1, culprits: [] };
    if (!result.overflows) return result;
    const all = Array.from(document.body ? document.body.querySelectorAll('*') : []).slice(0, 5000);
    const sx = window.scrollX;
    const flagged = new Set();
    for (const el of all) {
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) continue;
      if (r.right + sx > cw + 1 || r.left + sx < -1) {
        if (getComputedStyle(el).position === 'fixed' || inScrollContainer(el)) continue;
        flagged.add(el);
      }
    }
    for (const el of flagged) {
      if (flagged.has(el.parentElement)) continue; // keep the outermost cause
      const r = el.getBoundingClientRect();
      result.culprits.push({ ...describe(el), right: Math.round(r.right + sx), width: Math.round(r.width) });
      if (result.culprits.length >= 5) break;
    }
    return result;
  }

  function ownTextRects(el) {
    const rects = [];
    for (const n of el.childNodes) {
      if (n.nodeType !== 3 || !n.textContent.trim()) continue;
      const range = document.createRange();
      range.selectNodeContents(n);
      for (const r of range.getClientRects()) if (r.width > 1 && r.height > 1) rects.push(r);
    }
    return rects;
  }

  function textLayout() {
    const clipped = [];
    const leaves = [];
    const all = Array.from(document.body ? document.body.querySelectorAll('*') : []).slice(0, 5000);
    for (const el of all) {
      if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|OPTION|SELECT|TEXTAREA|INPUT)$/i.test(el.tagName)) continue;
      const hasOwnText = Array.from(el.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim());
      if (!hasOwnText || !isVisible(el)) continue;
      const cs = getComputedStyle(el);
      const hidesX = /hidden|clip/.test(cs.overflowX), hidesY = /hidden|clip/.test(cs.overflowY);
      const intendedTruncation = cs.textOverflow === 'ellipsis' || (cs.webkitLineClamp && cs.webkitLineClamp !== 'none');
      if ((hidesX && el.scrollWidth > el.clientWidth + 2) || (hidesY && el.scrollHeight > el.clientHeight + 2)) {
        if (!intendedTruncation && clipped.length < 15) clipped.push({ ...describe(el), scrollWidth: el.scrollWidth, clientWidth: el.clientWidth, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight });
      }
      if (leaves.length < 400 && !fixedOrSticky(el)) {
        const rects = ownTextRects(el);
        if (rects.length) leaves.push({ el, rects });
      }
    }
    const overlaps = [];
    const inter = (a, b) => Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left)) * Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
    for (let i = 0; i < leaves.length && overlaps.length < 10; i++) {
      for (let j = i + 1; j < leaves.length && overlaps.length < 10; j++) {
        const A = leaves[i], B = leaves[j];
        if (A.el.contains(B.el) || B.el.contains(A.el)) continue;
        let hit = null;
        for (const ra of A.rects) {
          for (const rb of B.rects) {
            const area = inter(ra, rb);
            const smaller = Math.min(ra.width * ra.height, rb.width * rb.height);
            if (area > 40 && area > 0.3 * smaller) { hit = Math.round((area / smaller) * 100); break; }
          }
          if (hit) break;
        }
        if (hit) overlaps.push({ a: describe(A.el), b: describe(B.el), percent: hit });
      }
    }
    return { clipped, overlaps };
  }

  const INTERACTIVE = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=checkbox], [role=radio], [role=switch], [role=tab], [role=menuitem], [onclick], [tabindex]:not([tabindex="-1"])';

  function tapTargets() {
    const els = Array.from(document.querySelectorAll(INTERACTIVE)).filter(isVisible).slice(0, 600);
    const rects = els.map((el) => el.getBoundingClientRect());
    const small = [];
    els.forEach((el, i) => {
      const r = rects[i];
      if (r.width >= 24 && r.height >= 24) return;
      if (el.tagName === 'INPUT' && /^(checkbox|radio)$/.test(el.type) && el.labels && el.labels.length) return;
      // WCAG 2.5.8 inline exception: a link inside a sentence.
      if (el.tagName === 'A') {
        const block = el.closest('p, li, td, dd, blockquote, figcaption, span');
        if (block && textOf(block).length > textOf(el).length + 15) return;
      }
      // Spacing exception: no other target centre within 24px.
      const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      const crowded = rects.some((o, k) => k !== i && !el.contains(els[k]) && !els[k].contains(el)
        && Math.hypot(o.left + o.width / 2 - cx, o.top + o.height / 2 - cy) < 24);
      if (r.width < 24 || r.height < 24) {
        if (!crowded && (r.width >= 16 && r.height >= 16)) return;
        small.push({ ...describe(el), width: Math.round(r.width), height: Math.round(r.height), crowded });
      }
    });
    return small.slice(0, 25);
  }

  // ---- keyboard ------------------------------------------------------------

  const styleKeys = ['outlineStyle', 'outlineWidth', 'outlineColor', 'boxShadow', 'borderTopColor', 'borderBottomColor', 'borderTopWidth', 'backgroundColor', 'color', 'textDecorationLine', 'transform', 'opacity'];
  const signature = (el) => {
    const parts = [];
    for (const target of [el, el.parentElement]) {
      if (!target) continue;
      const cs = getComputedStyle(target);
      parts.push(styleKeys.map((k) => cs[k]).join('|'));
      for (const pseudo of ['::before', '::after']) {
        const ps = getComputedStyle(target, pseudo);
        if (ps.content && ps.content !== 'none') parts.push([ps.content, ps.boxShadow, ps.backgroundColor, ps.borderTopColor, ps.outlineStyle, ps.opacity, ps.transform].join('|'));
      }
    }
    return parts.join('#');
  };
  let unfocused = new WeakMap();

  function prepareFocusAudit() {
    unfocused = new WeakMap();
    if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    const els = Array.from(document.querySelectorAll(INTERACTIVE)).slice(0, 400);
    for (const el of els) unfocused.set(el, signature(el));
    const positive = Array.from(document.querySelectorAll('[tabindex]')).filter((e) => parseInt(e.getAttribute('tabindex'), 10) > 0).slice(0, 10).map(describe);
    // Pointer-only widgets: look clickable but can't be reached with Tab.
    const pointerOnly = [];
    for (const el of Array.from(document.body ? document.body.querySelectorAll('div, span, li, img, i, svg, td, p') : []).slice(0, 4000)) {
      if (pointerOnly.length >= 10) break;
      if (el.closest('a, button, label, summary, [role=button], [role=link], [tabindex], select, input, textarea')) continue;
      if (getComputedStyle(el).cursor !== 'pointer' || !isVisible(el)) continue;
      if (el.parentElement && getComputedStyle(el.parentElement).cursor === 'pointer' && !el.hasAttribute('onclick')) continue;
      if (!el.hasAttribute('onclick') && !el.hasAttribute('role') && el.children.length > 8) continue;
      pointerOnly.push(describe(el));
    }
    return { focusable: els.length, positive, pointerOnly };
  }

  function focusInfo() {
    const el = document.activeElement;
    if (!el || el === document.body || el === document.documentElement) return { none: true };
    const r = el.getBoundingClientRect();
    const before = unfocused.get(el);
    const after = signature(el);
    const vw = document.documentElement.clientWidth, vh = window.innerHeight;
    const onScreen = r.width >= 1 && r.height >= 1 && r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw;
    return {
      none: false, ...describe(el), x: Math.round(r.left + window.scrollX), y: Math.round(r.top + window.scrollY),
      w: Math.round(r.width), h: Math.round(r.height), onScreen, visible: isVisible(el),
      indicator: before === undefined ? 'unknown' : before !== after ? 'visible' : 'none',
      inIframe: el.tagName === 'IFRAME', inputType: el.tagName === 'INPUT' ? (el.getAttribute('type') || 'text').toLowerCase() : '',
    };
  }

  // ---- dead-button detection -----------------------------------------------

  let mutations = 0;
  let observer = null;
  function startWatch() {
    mutations = 0;
    if (observer) observer.disconnect();
    observer = new MutationObserver((list) => { mutations += list.length; });
    observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
    return { url: location.href, scrollY: window.scrollY, dialogs: document.querySelectorAll('dialog[open], [role=dialog], [aria-modal=true]').length };
  }
  function stopWatch() {
    if (observer) observer.disconnect();
    observer = null;
    return { mutations, url: location.href, scrollY: window.scrollY, dialogs: document.querySelectorAll('dialog[open], [role=dialog], [aria-modal=true]').length };
  }

  function buttonCandidates() {
    const els = Array.from(document.querySelectorAll('button, [role=button], input[type=button], a[href="#"], a[href^="javascript:"], a:not([href])[onclick]'))
      .filter((el) => !(el.tagName === 'BUTTON' && el.form && (el.getAttribute('type') || 'submit') === 'submit'))
      .filter((el) => isVisible(el) && !el.disabled && el.getAttribute('aria-disabled') !== 'true');
    return els.slice(0, 40).map((el) => ({ ...describe(el), dangerous: isDangerous(el), expanded: el.getAttribute('aria-expanded') }));
  }

  // ---- screenshots -----------------------------------------------------------

  let overlay = null;
  function highlight(sel) {
    unhighlight();
    let el = null;
    try { el = document.querySelector(sel); } catch { return null; }
    if (!el) return null;
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = el.getBoundingClientRect();
    if (r.width < 1 && r.height < 1) return null;
    overlay = document.createElement('div');
    overlay.setAttribute('data-uia-overlay', '');
    Object.assign(overlay.style, {
      position: 'fixed', left: `${r.left - 4}px`, top: `${r.top - 4}px`, width: `${r.width + 8}px`, height: `${r.height + 8}px`,
      border: '3px solid #ff2d55', borderRadius: '6px', boxShadow: '0 0 0 4000px rgba(0,0,0,0.12)', zIndex: '2147483647', pointerEvents: 'none',
    });
    document.documentElement.appendChild(overlay);
    return { x: r.left, y: r.top, width: r.width, height: r.height };
  }
  function unhighlight() { if (overlay) { overlay.remove(); overlay = null; } }

  function locale() {
    const lang = (document.documentElement.lang || '').toLowerCase();
    const body = (document.body ? document.body.innerText : '').slice(0, 20000);
    return {
      lang,
      indian: /-in\b|^(hi|te|ta|kn|ml|mr|bn|gu|pa)\b/.test(lang) || /₹|\+91[\s-]?\d|\bindia\b|\bINR\b|\bpincode\b/i.test(body)
        || /\.(in|co\.in)$/.test(location.hostname),
    };
  }

  async function scrollThrough(maxSteps) {
    const step = Math.max(200, Math.floor(window.innerHeight * 0.85));
    let last = -1;
    for (let k = 0; k < maxSteps; k++) {
      window.scrollBy(0, step);
      await new Promise((r) => setTimeout(r, 120));
      const y = window.scrollY;
      if (y === last) break;
      last = y;
    }
    const height = document.documentElement.scrollHeight;
    window.scrollTo(0, 0);
    await new Promise((r) => setTimeout(r, 100));
    return { height };
  }

  window.__uia = Object.freeze({
    selectorFor, accessibleName, isVisible, isDangerous, collectForms, fieldState, formValidity, collectLinks,
    brokenAnchors, imageIssues, overflow, textLayout, tapTargets, prepareFocusAudit, focusInfo, startWatch,
    stopWatch, buttonCandidates, highlight, unhighlight, locale, scrollThrough, alertsText,
    title: () => document.title, mutationCount: () => mutations,
  });
}
