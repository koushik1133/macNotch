# UI Audit: design note

An autonomous frontend audit of the user's own website. SparkV starts a Node + Playwright runner, which opens a visible Chromium window. The runner crawls the site, fills and probes forms with synthetic data, and runs accessibility, layout, keyboard, link, console and network checks. It streams progress as JSON lines and writes a report (JSON, Markdown, HTML) with a screenshot for each issue. The "P" button turns that report into a fix prompt for a coding agent.

## What production tools do, and what we took from them

| Tool | How it works (public docs / README) | What we adopted |
|---|---|---|
| **Playwright MCP** (github.com/microsoft/playwright-mcp, Apache-2.0) | Drives the page through the accessibility tree rather than pixels. Runs **headed by default**. Has `--allowed-origins` / `--blocked-origins` (and notes they are *not* a security boundary) and an `--isolated` in-memory profile. | Headed by default so the user can watch and take over. Main-frame navigation is limited to an allowed-origins list, enforced in `context.route`. We use a fresh, isolated browser context with no stored credentials. Findings carry role/name locators (`getByRole('textbox', { name: 'Email' })`). |
| **Playwright codegen / locators** (playwright.dev/docs/codegen) | Prefers role, text and test-id locators, and refines them until they are unique. | Selector generator order: unique `#id` (skipping generated ids), `data-testid/test/cy/qa`, `tag[name]`, `a[href]`, then the shortest unique `:nth-of-type` path. A role+name locator is added for agents. |
| **axe-core / @axe-core/playwright** (github.com/dequelabs/axe-core, MPL-2.0) | `axe.run(context, { runOnly: { type: 'tag', values: [...] }, resultTypes: ['violations'] })`. Each violation has `id`, `impact`, `help`, `helpUrl`, and `nodes[].target/html/failureSummary`. | axe-core 4.14.0 is injected with the page's `define` hidden, so AMD sites still get `window.axe`. It runs WCAG 2.0/2.1/2.2 A+AA plus best-practice rules. Impact maps to severity (critical→critical, serious→high, moderate→medium, minor→low). `failureSummary` is split into "actual" and "fix". |
| **Lighthouse** (developer.chrome.com/docs/lighthouse) | The tap-target audit flags targets under 48×48 px that overlap neighbours. The content-width audit fails when content is wider than the viewport. | Tap targets follow the WCAG 2.5.8 minimum (24×24 CSS px), with the spacing and inline-link exceptions. Overflow uses `scrollWidth > clientWidth` at 1440 and 390 px, plus the outermost element causing it. A missing `meta viewport` is reported. |
| **browser-use** (github.com/browser-use/browser-use, MIT) | DOM extraction of interactive elements. `sensitive_data` keeps secrets away from the model. `max_actions_per_step`. | The page DOM is scanned for interactive candidates. No credentials ever reach the runner: passwords are generated test values, and payment, bank and government-ID fields are never filled. Click, Tab and probe counts are capped per page. |
| **Stagehand** (github.com/browserbase/stagehand, MIT) | `observe()` returns real selectors before `act()`, so the plan can be reviewed and credentials never reach the model. | Plan first: the runner emits a `plan` event (origins, submission policy, risky-click policy) before acting. Every action is a deterministic Playwright call on a selector. |
| **Skyvern** (github.com/Skyvern-AI/skyvern, AGPL-3.0, *ideas only, no code used*) | Livestreams the browser so a human can intervene. Uses error codes to halt a run. | The visible window, plus **Take over** (pause between actions) and **Stop**, which writes a partial report. |
| **Gemini in Chrome agentic browsing** (Google security blog; 9to5google 2025-12-08 and 2026-01-28; The Register 2026-01-29, *public coverage only*) | Logs each step in a work log. "Take over task" is always visible. Requires human confirmation before purchases or posting, and before sensitive sites. | A live log of each step and an always-visible Take over / Resume / Stop. Destructive or financial controls (pay, checkout, delete, remove, cancel subscription, transfer, logout…) are never clicked without the per-run "Allow risky clicks" toggle. Forms are never submitted on non-test hosts without the per-run "Allow form submission" toggle. |
| **QA Wolf / AI QA services** (public marketing pages) | Produce human-readable bug reports with repro steps and expected vs actual, which feed into fix workflows. | Every finding has page, viewport, selector, locator, evidence, steps to reproduce, expected, actual, suggested fix, acceptance criteria and a screenshot. "P" builds a coding-agent prompt from them. |

Sources: https://github.com/microsoft/playwright-mcp · https://playwright.dev/docs/codegen · https://github.com/dequelabs/axe-core/blob/develop/doc/API.md · https://github.com/dequelabs/axe-core-npm/blob/develop/packages/playwright/README.md · https://developer.chrome.com/docs/lighthouse/seo/tap-targets · https://developer.chrome.com/docs/lighthouse/pwa/content-width · https://github.com/browser-use/browser-use · https://docs.browser-use.com/customize/agent/all-parameters · https://github.com/browserbase/stagehand · https://github.com/Skyvern-AI/skyvern · https://9to5google.com/2025/12/08/gemini-chrome-agentic-security/ · https://9to5google.com/2026/01/28/chrome-gemini-auto-browse/ · https://www.theregister.com/2026/01/29/chrome_gemini_pane/

No proprietary app was decompiled or copied. All runner code is original and depends only on `playwright-core` (Apache-2.0) and `axe-core` (MPL-2.0, used unmodified).

## Architecture

```
UIAuditController (@MainActor, ObservableObject)
  ├─ writes run-config.json → ~/Library/Application Support/SparkV/UIAudit/<stamp>-<host>/
  ├─ UIAuditProcess: node audit.mjs --config … --stdin-control
  │     stdout: JSON lines (plan/state/page/step/finding/page-done/log/error/done)
  │     stdin:  pause | resume | stop     (EOF ⇒ runner stops: an app crash never leaves a crawler)
  ├─ ActivityCenter band: "UI audit: page 3/12 · 7 issues"
  ├─ UIAuditWindowController / UIAuditWindowView (full window)
  ├─ UIAuditTabView (drawer tab, 508×114)
  ├─ UIAuditPromptBuilder (the "P" prompt, deterministic)
  └─ UIAuditSummarizer: rule-based → on-device FoundationModels → Groq (opt-in only)
```

Runner (`Vendor/ui-audit/audit.mjs`): breadth-first crawl of the allowed origins (max pages and depth configurable), rate-limited (≥200 ms, 600 ms default). For each page it:

1. Loads the page and waits for `networkidle` (max 4 s), then scrolls to the bottom and back to load lazy content.
2. Collects links: same-origin links are queued; external ones are listed but never visited. Up to 25 same-origin link targets are checked with HEAD (GET fallback). Dangerous URLs are not requested (logout, delete, checkout…).
3. Images: missing alt (when axe is off) and broken images.
4. axe-core.
5. Layout at 1440 and 390: overflow and its causes, clipped text (overflow hidden without ellipsis or line-clamp), overlapping text (rects of each element's own text nodes), and tap targets at 390.
6. Keyboard: up to 60 Tab presses. Detects focus with no visible change (computed outline, shadow, border, background and color, plus `::before`/`::after`, compared with an unfocused snapshot), focus on invisible elements, traps (date and time inputs get extra presses for their segments), backward jumps, positive tabindex, and pointer-only clickables.
7. Forms (static): accessible name, placeholder-as-label, empty or misleading placeholder (the purpose inferred from the placeholder contradicts the label), placeholder example failing the field's own `pattern`, missing format hint, "*" markers without `required`, required fields not marked, `label[for]` pointing to a missing id, duplicate ids, missing autocomplete (WCAG 1.3.5), and generic input types.
8. Forms (dynamic): each field's purpose is inferred from autocomplete, type, name, id, label, aria and placeholder. The runner then:
   - fills type-correct test data within pattern, min/max, step and length limits (Indian `+91` mobile numbers when the page looks Indian, otherwise fictional 555-01xx E.164 numbers, `test+<tag>@example.com`, dates in range, the first valid select option, checkboxes and radios, bundled fixture files for file inputs);
   - probes wrong-type values on blur (`not-an-email`, `abc-not-a-phone`, …) and reads `validity`, `aria-invalid` and newly visible text in the field's wrapper;
   - judges each validation message (vague? associated via describedby or errormessage, or a live region?);
   - checks that realistic data passes;
   - only where submission is allowed: tries an empty submit (required fields must block it), then a valid submit (5xx/4xx response, or no feedback).
9. Dead buttons: up to 12 per page. Each button is clicked under a MutationObserver. A button counts as dead when there is no DOM mutation, URL change (ignoring hash), scroll, dialog, request or popup within 700 ms.
10. Console errors, uncaught exceptions and failed requests, deduplicated. Identical findings on later pages are folded into `alsoOn`.

## Safety model

- **Origins**: main-frame navigation outside `allowedOrigins` (the start origin plus any extras the user lists) is aborted. Popups are closed. Downloads are refused, and permission prompts are denied (`--deny-permission-prompts`, no granted permissions).
- **Writes**: a route guard aborts every non-GET/HEAD/OPTIONS request unless the target is an allowed origin **and** either a test host (localhost, 127.x, ::1, *.localhost, *.test, *.local; staging and dev hosts are remote and need the opt-in) or the user turned on "Allow form submission" for this run. This also stops autosave and analytics XHRs from writing. Blocked requests are listed in the report's safety log.
- **Clicks**: anything whose text, aria-label, title, value, id, name, href or formaction matches pay, purchase, buy, checkout, place order, delete, remove, destroy, cancel subscription, unsubscribe, deactivate, transfer, send money, withdraw, logout or sign out is skipped unless the user turned on "Allow risky clicks" for this run. Submit buttons that match are never pressed. JS dialogs are dismissed (confirm() → cancel); only `beforeunload` is accepted.
- **Data**: the runner never reads real credentials. Passwords are generated per run. Payment, bank and government-ID fields stay empty and are listed as "sensitive fields left empty".
- **Input**: keyboard and mouse go to the Playwright page over CDP. Nothing is posted to the macOS desktop.
- **Stop**: the controller sends `stop`, then SIGTERM, then SIGKILL. The runner writes a partial report on stop or SIGTERM, and Chromium exits with its pipe. The run has a hard cap (`maxRunSeconds`, 900 s).
- **Groq**: `uiAudit.useGroqSummaries` is off by default. While it is off the keychain is never read. When it is on, only a digest of finding titles and paths is sent.

## Known limits

- The 390 px pass resizes the viewport (no `isMobile` emulation). A missing viewport meta tag is reported separately.
- Shadow DOM and cross-origin iframes are not crawled (axe still reports inside open shadow roots).
- On non-test hosts, validation found only at submit time or on the server can't be observed. These findings say so ("submission was off…").
- Heuristic checks (dead buttons, overlap, focus visibility) are deliberately conservative and can still misfire on unusual widgets. Each finding has a screenshot so the user can verify it.
