// Field purpose inference and type-correct, obviously-synthetic test data.
//
// Purpose comes from (strongest first) the autocomplete token, the input type,
// then name/id/label/aria-label/placeholder text. Values are fictional:
// example.com e-mail addresses (RFC 2606), 555-01xx US numbers (reserved for
// fiction), and generated passwords that are never anyone's real credential.
// Payment, bank and government-ID fields are never filled.

const AUTOCOMPLETE = {
  email: 'email', tel: 'phone', 'tel-national': 'phone', 'tel-local': 'phone',
  'given-name': 'firstName', 'family-name': 'lastName', 'additional-name': 'middleName', name: 'fullName',
  nickname: 'username', username: 'username', 'new-password': 'password', 'current-password': 'password',
  'one-time-code': 'otp', organization: 'company', 'organization-title': 'jobTitle',
  'street-address': 'address', 'address-line1': 'address', 'address-line2': 'address2', 'address-line3': 'address2',
  'address-level2': 'city', 'address-level1': 'state', country: 'country', 'country-name': 'country',
  'postal-code': 'postalCode', bday: 'dob', 'bday-day': 'dobDay', 'bday-month': 'dobMonth', 'bday-year': 'dobYear',
  url: 'url', sex: 'gender', language: 'language',
  'cc-name': 'cardName', 'cc-number': 'cardNumber', 'cc-exp': 'cardExpiry', 'cc-exp-month': 'cardExpiry',
  'cc-exp-year': 'cardExpiry', 'cc-csc': 'cvc', 'cc-type': 'cardType', 'transaction-amount': 'amount',
};

// Order matters: sensitive purposes first so "card number" never reads as "number".
const TEXT_RULES = [
  ['cardNumber', /card.?(number|no|num)|cc.?(num|number)|credit.?card|debit.?card|\bpan\b.?card/],
  ['cvc', /\bcvv\b|\bcvc\b|\bcvn\b|security.?code|card.?code/],
  ['cardExpiry', /expir|exp.?date|\bmm.?yy\b|valid.?thru/],
  ['bankAccount', /\biban\b|account.?(number|no)|routing|\bifsc\b|sort.?code|\bswift\b|\bbic\b|\bupi\b/],
  ['govId', /\bssn\b|social.?security|aadhaa?r|passport|\bpan\b|national.?id|tax.?id|\bgstin?\b|\btin\b|driver.?licen|voter.?id/],
  ['password', /pass.?word|passwd|\bpwd\b|passcode/],
  ['otp', /\botp\b|one.?time|verification.?code|verify.?code|2fa|auth.?code|security.?pin/],
  ['email', /e-?mail/],
  ['phone', /phone|mobile|\btel\b|telephone|\bcell\b|whats.?app|contact.?(number|no)/],
  ['url', /website|\burl\b|homepage|web.?site|portfolio|linkedin|github/],
  ['firstName', /first.?name|given.?name|\bfname\b|forename/],
  ['lastName', /last.?name|surname|family.?name|\blname\b/],
  ['username', /user.?name|user.?id|\blogin\b|handle|screen.?name/],
  ['dob', /birth|\bdob\b|\bbday\b/],
  ['age', /\bage\b|years.?old/],
  ['postalCode', /\bzip\b|postal|pin.?code|pincode|post.?code/],
  ['address2', /address.?(line)?.?2|apartment|\bapt\b|suite|flat.?no|landmark/],
  ['address', /address|street|\baddr\b/],
  ['city', /\bcity\b|town|locality/],
  ['state', /\bstate\b|province|region|county/],
  ['country', /country|nation\b/],
  ['company', /company|organi[sz]ation|business|employer|\borg\b/],
  ['jobTitle', /job.?title|designation|position|occupation/],
  ['quantity', /\bqty\b|quantity|how.?many|number.?of|guests|seats|people|count\b/],
  ['amount', /amount|price|budget|salary|income|cost/],
  ['search', /search|query|\bq\b|keyword/],
  ['subject', /subject|topic/],
  ['message', /message|comment|feedback|description|notes?\b|details|\bbio\b|about|enquiry|inquiry|question/],
  ['fullName', /full.?name|your.?name|\bname\b/],
  ['gender', /gender|\bsex\b/],
  ['code', /coupon|promo|referral|voucher|invite.?code/],
];

export const SENSITIVE = new Set(['cardNumber', 'cvc', 'cardExpiry', 'cardName', 'cardType', 'bankAccount', 'govId']);

export function purposeFromText(text) {
  const t = String(text || '').toLowerCase().replace(/[_\-.\[\]]+/g, ' ');
  if (!t.trim()) return null;
  for (const [purpose, re] of TEXT_RULES) if (re.test(t)) return purpose;
  return null;
}

/** Best guess of what a field is for, plus where that guess came from. */
export function inferPurpose(f) {
  const tokens = String(f.autocomplete || '').toLowerCase().split(/\s+/).filter(Boolean);
  for (const token of tokens.reverse()) {
    if (AUTOCOMPLETE[token]) return { purpose: AUTOCOMPLETE[token], source: `autocomplete="${token}"` };
  }
  const typeMap = { email: 'email', tel: 'phone', url: 'url', password: 'password', search: 'search' };
  if (typeMap[f.type]) {
    // A password-type field labelled "PIN"/"CVV" is still sensitive.
    const text = purposeFromText([f.name, f.id, f.label, f.ariaLabel].join(' '));
    if (f.type === 'password' && text && SENSITIVE.has(text)) return { purpose: text, source: 'label' };
    return { purpose: typeMap[f.type], source: `type="${f.type}"` };
  }
  const named = purposeFromText([f.name, f.id].join(' '));
  const labelled = purposeFromText([f.label, f.ariaLabel, f.accName && f.accSource !== 'placeholder' ? f.accName : ''].join(' '));
  const placeholder = purposeFromText(f.placeholder);
  const purpose = labelled || named || placeholder;
  if (purpose) return { purpose, source: labelled ? 'label' : named ? 'name/id' : 'placeholder' };
  if (['date', 'datetime-local', 'month', 'week', 'time'].includes(f.type)) return { purpose: 'date', source: `type="${f.type}"` };
  if (f.type === 'number' || f.type === 'range') return { purpose: 'number', source: `type="${f.type}"` };
  if (f.tag === 'textarea') return { purpose: 'message', source: 'textarea' };
  if (f.inputMode === 'numeric' || f.inputMode === 'decimal') return { purpose: 'number', source: 'inputmode' };
  if (f.inputMode === 'email') return { purpose: 'email', source: 'inputmode' };
  if (f.inputMode === 'tel') return { purpose: 'phone', source: 'inputmode' };
  return { purpose: 'text', source: 'default' };
}

/** Two guesses describe compatible things (no "misleading placeholder"). */
export function compatiblePurposes(a, b) {
  if (!a || !b || a === b) return true;
  const groups = [
    ['fullName', 'firstName', 'lastName', 'username', 'middleName'],
    ['address', 'address2', 'city', 'state', 'country', 'postalCode'],
    ['dob', 'date', 'age'],
    ['message', 'subject', 'text', 'search'],
    ['phone', 'otp'],
    ['quantity', 'amount', 'number', 'age'],
    ['email', 'username'],
    ['code', 'otp'],
  ];
  return groups.some((g) => g.includes(a) && g.includes(b));
}

// ---------------------------------------------------------------------------

export function makeRandom(seed) {
  let s = seed >>> 0 || 0x9e3779b9;
  const next = () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 0x100000000; };
  return {
    next,
    int: (lo, hi) => lo + Math.floor(next() * (hi - lo + 1)),
    digits: (n) => Array.from({ length: n }, () => Math.floor(next() * 10)).join(''),
    tag: () => Math.floor(next() * 36 ** 6).toString(36).padStart(6, '0'),
  };
}

export function patternRegex(pattern) {
  if (!pattern) return null;
  for (const flags of ['v', 'u', '']) {
    try { return new RegExp(`^(?:${pattern})$`, flags); } catch { /* try next */ }
  }
  return null;
}

function fits(value, f) {
  if (f.maxLength > 0 && value.length > f.maxLength) return false;
  if (f.minLength > 0 && value.length < f.minLength) return false;
  const re = patternRegex(f.pattern);
  return !re || re.test(value);
}

const pad2 = (n) => String(n).padStart(2, '0');
const isoDate = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;

function parseDateish(type, s) {
  if (!s) return null;
  if (type === 'month') return new Date(`${s}-01T12:00:00`);
  if (type === 'week') {
    const m = /^(\d{4})-W(\d{2})$/.exec(s);
    if (!m) return null;
    const d = new Date(Date.UTC(+m[1], 0, 4));
    d.setUTCDate(d.getUTCDate() + (+m[2] - 1) * 7);
    return new Date(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 12);
  }
  if (type === 'time') return null;
  const d = new Date(s.length <= 10 ? `${s}T12:00:00` : s);
  return Number.isNaN(d.getTime()) ? null : d;
}

function formatDateish(type, d) {
  switch (type) {
    case 'month': return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}`;
    case 'week': {
      const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
      const day = t.getUTCDay() || 7;
      t.setUTCDate(t.getUTCDate() + 4 - day);
      const yearStart = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
      const week = Math.ceil(((t - yearStart) / 86400000 + 1) / 7);
      return `${t.getUTCFullYear()}-W${pad2(week)}`;
    }
    case 'datetime-local': return `${isoDate(d)}T10:30`;
    default: return isoDate(d);
  }
}

/** A date inside [min, max]; birthdays default to 1990, other dates to next week. */
export function dateValue(f, purpose) {
  const type = f.type === 'text' ? 'date' : f.type;
  if (type === 'time') {
    const min = f.min || '00:00', max = f.max || '23:59';
    return '10:30' >= min && '10:30' <= max ? '10:30' : min;
  }
  let target = new Date();
  if (purpose === 'dob' || purpose === 'age') target = new Date(1990, 4, 15, 12);
  else target.setDate(target.getDate() + 7);
  const min = parseDateish(type, f.min), max = parseDateish(type, f.max);
  if (min && target < min) target = new Date(min.getTime() + (max && max - min < 7 * 86400000 ? 0 : 86400000));
  if (max && target > max) target = new Date(max.getTime() - (min && max - min < 86400000 ? 0 : 86400000));
  if (min && target < min) target = min;
  return formatDateish(type, target);
}

/** A number inside [min, max] that also lands on the step grid. */
export function numberValue(f, purpose) {
  const min = f.min !== '' && Number.isFinite(+f.min) ? +f.min : null;
  const max = f.max !== '' && Number.isFinite(+f.max) ? +f.max : null;
  const stepRaw = f.step === 'any' ? null : (f.step !== '' && +f.step > 0 ? +f.step : 1);
  const preferred = { age: 30, quantity: 2, amount: 100, postalCode: 560038, dobYear: 1990, dobDay: 15, dobMonth: 5 }[purpose] ?? null;
  let v;
  if (preferred !== null && (min === null || preferred >= min) && (max === null || preferred <= max)) v = preferred;
  else if (min !== null && max !== null) v = min + (max - min) / 2;
  else if (min !== null) v = min + (stepRaw || 1);
  else if (max !== null) v = Math.min(max, 1);
  else v = 1;
  if (stepRaw) {
    const base = min ?? 0;
    v = base + Math.round((v - base) / stepRaw) * stepRaw;
    if (max !== null && v > max) v -= stepRaw;
    if (min !== null && v < min) v = min;
  }
  const decimals = stepRaw && !Number.isInteger(stepRaw) ? String(stepRaw).split('.')[1].length : 0;
  return v.toFixed(decimals);
}

function phoneCandidates(ctx) {
  const r = ctx.rand;
  if (ctx.indian) {
    const d = `9${r.int(6, 9)}${r.digits(8)}`; // Indian mobiles start 6-9
    return [`+91${d}`, d, `+91 ${d.slice(0, 5)} ${d.slice(5)}`, `+91-${d}`, `0${d}`, `91${d}`];
  }
  const tail = `01${r.digits(2)}`; // 555-0100..0199 is reserved for fiction
  return [`+1415555${tail}`, `415555${tail}`, `(415) 555-${tail}`, `415-555-${tail}`, `415 555 ${tail}`, `1415555${tail}`];
}

function textCandidates(purpose, f, ctx) {
  const tag = ctx.tag;
  const india = ctx.indian;
  switch (purpose) {
    case 'email': return [`test+${tag}@example.com`, `t${tag}@example.com`];
    case 'phone': return phoneCandidates(ctx);
    case 'otp': return ['123456', '1234', '12345678'];
    case 'password': return [`UiAudit-${tag}-9a!`, `UiAudit${tag}9A`];
    case 'firstName': return ['Test'];
    case 'middleName': return ['Q'];
    case 'lastName': return ['User'];
    case 'fullName': return ['Test User'];
    case 'username': return [`testuser${tag}`, `tu${tag}`];
    case 'company': return ['Example Labs'];
    case 'jobTitle': return ['QA Tester'];
    case 'url': return ['https://example.com', 'example.com'];
    case 'address': return [india ? '12 Test Road, Indiranagar' : '123 Test Street'];
    case 'address2': return ['Suite 4'];
    case 'city': return [india ? 'Bengaluru' : 'Springfield'];
    case 'state': return [india ? 'Karnataka' : 'California', india ? 'KA' : 'CA'];
    case 'country': return [india ? 'India' : 'United States', india ? 'IN' : 'US'];
    case 'postalCode': return india ? ['560038'] : ['94105', '94105-0001'];
    case 'search': return ['test'];
    case 'subject': return ['UI audit test'];
    case 'message': return ['Automated UI audit test message from SparkV. Synthetic data, please ignore.'];
    case 'gender': return ['Prefer not to say'];
    case 'code': return ['TEST2026'];
    case 'age': return ['30'];
    case 'quantity': return ['2'];
    case 'amount': return ['100'];
    case 'number': return ['1', '10'];
    case 'dobYear': return ['1990'];
    case 'dobMonth': return ['05', '5'];
    case 'dobDay': return ['15'];
    case 'language': return ['English'];
    case 'dob': case 'date': return [dateValue({ ...f, type: 'date' }, purpose), '15/05/1990', '05/15/1990'];
    default: return ['Test value', 'Test'];
  }
}

/**
 * The value to type into a text-like field: the first realistic candidate that
 * satisfies pattern/minlength/maxlength, else one generated from the pattern.
 */
export function textValue(purpose, f, ctx) {
  const candidates = textCandidates(purpose, f, ctx);
  for (const c of candidates) if (fits(c, f)) return { value: c, satisfies: true };
  if (f.pattern) {
    const sampled = sampleFromPattern(f.pattern, ctx.rand);
    if (sampled !== null && fits(sampled, f)) return { value: sampled, satisfies: true };
  }
  let v = candidates[0];
  if (f.minLength > 0 && v.length < f.minLength) v = v.padEnd(f.minLength, 'x');
  if (f.maxLength > 0 && v.length > f.maxLength) v = v.slice(0, f.maxLength);
  return { value: v, satisfies: fits(v, f) };
}

/** A value that a correct form should reject, for the "accepts wrong type" probe. */
export function invalidProbe(purpose, f) {
  if (['checkbox', 'radio', 'file', 'select', 'select-one', 'select-multiple', 'hidden', 'color', 'range',
    'date', 'datetime-local', 'month', 'week', 'time', 'password'].includes(f.type)) return null;
  if (f.type === 'number') {
    if ((purpose === 'age' || purpose === 'quantity') && f.min === '') return { value: '-5', expect: `a ${purpose} cannot be negative` };
    return null;
  }
  switch (purpose) {
    case 'email': return { value: 'not-an-email', expect: 'an e-mail address must contain "@" and a domain' };
    case 'phone': return { value: 'abc-not-a-phone', expect: 'a phone number must contain digits only (plus formatting)' };
    case 'url': return { value: 'not a url', expect: 'a URL must be a valid address' };
    case 'age': case 'quantity': case 'amount': case 'number':
      return { value: 'abc', expect: `a ${purpose === 'number' ? 'numeric value' : purpose} must be a number` };
    case 'postalCode': return { value: 'ABC!!', expect: 'a postal code must match its format' };
    case 'dob': case 'date': return { value: '99/99/9999', expect: 'an impossible date must be rejected' };
    case 'otp': return { value: 'abcdef', expect: 'a one-time code is numeric' };
    default:
      if (f.pattern) return { value: '!!invalid!!', expect: `the value must match pattern ${f.pattern}` };
      return null;
  }
}

/** Value for the file chooser from the bundled fixtures, picked by accept=. */
export function fixtureFor(accept, fixturesDir) {
  const a = String(accept || '').toLowerCase();
  const pick = (name) => `${fixturesDir}/${name}`;
  if (!a) return pick('test-upload.png');
  if (/image|\.png|\.jpe?g|\.gif|\.webp/.test(a)) return pick('test-upload.png');
  if (/pdf/.test(a)) return pick('test-upload.pdf');
  if (/csv|spreadsheet|excel/.test(a)) return pick('test-upload.csv');
  if (/text|\.txt|\.md/.test(a)) return pick('test-upload.txt');
  return pick('test-upload.txt');
}

// ---------------------------------------------------------------------------
// Tiny regex sampler for HTML pattern= values: literals, escapes (\d \w \s),
// classes with ranges, groups with alternation (first branch), and
// quantifiers (minimum count, at least 1 for +). Returns null when unsure.

export function sampleFromPattern(pattern, rand) {
  let i = 0;
  const src = pattern;
  const pickFromClass = (chars) => chars.length ? chars[Math.floor((rand ? rand.next() : 0) * chars.length)] : null;
  const DIGITS = '0123456789'.split('');
  const WORD = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.split('');

  function parseClass() {
    i++; // [
    let negate = false;
    if (src[i] === '^') { negate = true; i++; }
    const chars = [];
    let first = true;
    while (i < src.length && (src[i] !== ']' || first)) {
      first = false;
      let c = src[i];
      if (c === '\\') {
        const e = src[i + 1]; i += 2;
        if (e === 'd') chars.push(...DIGITS);
        else if (e === 'w') chars.push(...WORD);
        else if (e === 's') chars.push(' ');
        else chars.push(e);
        continue;
      }
      if (src[i + 1] === '-' && src[i + 2] && src[i + 2] !== ']') {
        const a = c.charCodeAt(0), b = src[i + 2].charCodeAt(0);
        for (let k = a; k <= b && k - a < 200; k++) chars.push(String.fromCharCode(k));
        i += 3;
        continue;
      }
      chars.push(c); i++;
    }
    i++; // ]
    if (negate) {
      const pool = WORD.concat(['-', '_', '.']).filter((c) => !chars.includes(c));
      return () => pickFromClass(pool.filter((c) => /[a-z0-9]/i.test(c)));
    }
    // Prefer alphanumerics so samples look natural.
    const nice = chars.filter((c) => /[a-z0-9]/i.test(c));
    return () => pickFromClass(nice.length ? nice : chars);
  }

  function parseAtom() {
    const c = src[i];
    if (c === '(') {
      i++;
      if (src[i] === '?') { i++; if (src[i] === ':' || src[i] === '=' || src[i] === '!') i++; else return null; }
      const seq = parseAlternation();
      if (src[i] !== ')') return null;
      i++;
      return seq;
    }
    if (c === '[') return parseClass();
    if (c === '\\') {
      const e = src[i + 1]; i += 2;
      if (e === 'd') return () => pickFromClass(DIGITS);
      if (e === 'w') return () => pickFromClass(WORD);
      if (e === 's') return () => ' ';
      if (/[DWSbB]/.test(e)) return () => 'a';
      return () => e;
    }
    if (c === '.') { i++; return () => 'a'; }
    if (c === '^' || c === '$') { i++; return () => ''; }
    i++;
    return () => c;
  }

  function parseQuantified() {
    const atom = parseAtom();
    if (!atom) return null;
    let min = 1, max = 1;
    const q = src[i];
    if (q === '?') { min = 0; max = 1; i++; }
    else if (q === '*') { min = 0; max = 0; i++; }
    else if (q === '+') { min = 1; i++; }
    else if (q === '{') {
      const m = /^\{(\d+)(,(\d*))?\}/.exec(src.slice(i));
      if (m) { min = +m[1]; max = m[2] ? (m[3] ? +m[3] : min) : min; i += m[0].length; }
    }
    if (src[i] === '?') i++; // lazy
    const count = Math.max(min, q === '+' ? 1 : 0);
    return () => { let s = ''; for (let k = 0; k < count; k++) { const part = atom(); if (part === null) return null; s += part; } return s; };
  }

  function parseSequence() {
    const parts = [];
    while (i < src.length && src[i] !== '|' && src[i] !== ')') {
      const p = parseQuantified();
      if (!p) return null;
      parts.push(p);
    }
    return () => { let s = ''; for (const p of parts) { const v = p(); if (v === null) return null; s += v; } return s; };
  }

  function parseAlternation() {
    const first = parseSequence();
    if (!first) return null;
    while (src[i] === '|') { i++; if (!parseSequence()) return null; }
    return first;
  }

  try {
    const gen = parseAlternation();
    if (!gen || i < src.length) return null;
    return gen();
  } catch {
    return null;
  }
}
