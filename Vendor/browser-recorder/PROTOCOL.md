# browser-recorder: runner protocol

`runner.mjs` is a Node 18+ ES module. It uses **playwright-core 1.64.1**, pinned exactly because that version
expects the installed Chromium build, `~/Library/Caches/ms-playwright/chromium-1248`. It has no postinstall
step that downloads browsers. Both `playwright-core` (Apache-2.0, © Microsoft) and its `LICENSE`/`NOTICE` files
ship in `node_modules/playwright-core`. This runner (`runner.mjs`, `inject.js`) is MIT and was written
for SparkV. No code from Automa (AGPL), Selenium IDE, UI.Vision or Healenium is included; see
`Sources/Labs/BrowserRecorder/DESIGN.md` for what each tool contributed as an idea.

## Commands

| Command | Purpose |
|---|---|
| `node runner.mjs check` | Prints `{"type":"check","ok":bool,"playwright":"1.64.1","chromium":"<path>","node":"v22…"}`. |
| `node runner.mjs record --profile DIR [--url URL] [--browser chrome] [--headless]` | Opens a persistent-profile browser and records until stopped. |
| `node runner.mjs replay --flow FILE --profile DIR [--vars-stdin] [--csv FILE] [--allow-risky] [--shots DIR] [--step-timeout MS] [--continue-on-error] [--from STEP_ID] [--browser chrome] [--headless]` | Replays a flow. The exit code is 0 on success and 1 on failure. `--from` skips the steps before `STEP_ID` ("Replay from Here"); variables and risky words are then checked only from that step on, and a non-navigate first step opens its recorded `pageURL` in the fresh tab. |
| `node runner.mjs risky --flow FILE` | Prints `{"type":"risky","words":[…],"variables":[…]}`. |

`--headless` is meant for tests. The app always records and replays headed, so the user can see the browser.

## stdin (JSON lines)

* `{"vars":{"email":"…","password":"…"}}` is the **first** line when `--vars-stdin` is set. These base values
  are merged under each CSV row. Secrets travel only this way, never in argv.
* `{"cmd":"stop"}` makes recording send its flow and exit. Replay abandons the current step within about 150 ms
  (no retry, no failure screenshot), emits `stopped {reason:"user"}` and `done {stopped:true}`.
* Closing stdin (for example when the app quits) has the same effect as `stop`. SIGTERM and SIGINT do too.

## stdout (one JSON object per line)

Recording:
`recording` → `step {index, step}` / `stepUpdated {index, step}` (typing merged into one step) /
`stepRemoved {index}` (two clicks folded into a dblclick) → `flow {reason, flow}`. The reason is `stop`, `overlay`
or `browserClosed`.

Replay:
`start {flowId, name, steps, rows}` → per row `rowStart {row, rows}` → per step `stepStart {row, index, stepId, title}`
→ `retry {attempt, message}`* → `healed {index, stepId, via: fallback|fuzzy, selectorIndex, score, runnerUp,
selectors[], fingerprint}`? → `stepDone {ms}` | `stepFailed {message, screenshot, optional}` → `rowDone {row, ok}`
→ `done {ok, rows, passedRows, failedRows, healed, durationMs, stopped, flow?}`. `flow` is included when
something was healed, with the healed selectors put first.

Errors: `error {code, message}`. The codes are `needsConfirmation` (with `words`), `missingVariables` (with `missing`),
`browserMissing`, `profileInUse` and `fatal`. Problems that don't stop the run arrive as `warning {message}`. The `--shots` folder is created only when a step fails.

## Flow file (schema 1)

```jsonc
{
  "schema": 1, "id": "uuid", "name": "Acme signup", "createdAt": 1729…, "updatedAt": 1729…,   // ms since 1970
  "startURL": "https://…", "trigger": "manual", "defaults": { "email": "me@x.com" },        // never secrets
  "steps": [
    { "id": "uuid", "type": "navigate", "url": "https://…/index.html", "pageIndex": 0, "title": "Open …", "selectors": [] },
    { "id": "uuid", "type": "fill", "title": "Type into “Email”", "value": "{{email}}",
      "selectors": [ {"kind":"role","role":"textbox","name":"Email"}, {"kind":"label","text":"Email"},
                     {"kind":"css","value":"#email"} ],
      "fingerprint": { "tag":"input","role":"textbox","name":"Email","text":"","label":"Email","id":"email",
                       "classes":[],"attrs":{"name":"email","type":"email"},"path":["form"],"rect":{…} },
      "pageURL": "https://…/index.html", "pageIndex": 0 },
    { "type": "fill", "masked": true, "value": "{{password}}", … },   // the password itself is never read
    { "type": "delay", "ms": 1000 }, { "type": "waitText", "value": "Done", "timeout": 15000 },
    { "type": "waitURL", "value": "/welcome" }, { "type": "waitFor", "selectors": […], "fingerprint": {…} }
  ]
}
```

The step types are `navigate`, `click`, `dblclick`, `hover`, `fill`, `press` (`key`), `select` (`options[{value,label}]`),
`check`, `uncheck`, `upload` (`value` holds `|`-separated paths or `{{file}}`, and `fileNames` the recorded names),
`scroll` (`x`,`y`), `waitFor`, `waitText`, `waitURL`, `delay` (`ms`, capped at 120 s) and `comment`. Optional flags
are `disabled` (the step is skipped), `optional` (a failure doesn't stop the row) and `timeout` (in ms). The `pageIndex` field gives the tab
in the order tabs opened. A `navigate` step whose `pageIndex` is one past the last tab opens a new tab.

Selector kinds, tried in order: `testid {attr,value}`, `role {role,name}`, `label {text}`,
`placeholder {text}`, `text {text}`, `alt {text}`, `title {text}`, `css {value}` and `xpath {value}`.

## Limits

Each step gets 3 attempts. Selectors fall back to a fuzzy fingerprint match after 30% of the step timeout, which
needs a score of at least 0.6 and a lead of at least 0.04 over the runner-up. Other limits: 2000 steps per flow,
500 CSV rows, a 120 s maximum delay and 60 minutes per run.

## Tests

`node test/test.mjs` runs headless against local pages in `test/site` (v1, then v2 with renamed ids and classes,
then v3 with a restructured DOM, then v4 with the button removed). It records by driving the page through
Playwright, then replays through the real CLI. It checks that passwords are masked, that typing is merged, and that
selects, checkboxes, uploads and scrolls are recorded and replayed. It also checks self-healing (fallback and fuzzy),
the CSV loop, missing-variable and risky-flow refusals, the failure screenshot and new-tab handling. The test
writes only to a temporary directory.
