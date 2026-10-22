# Browser Task Recorder: design note

This feature records repetitive browser work once, saves it as a flow that can be edited,
replays it on demand, and survives small UI changes.

## What production tools do (research)

| Tool | What we take from it |
|---|---|
| **Playwright codegen / locators** ([codegen docs](https://playwright.dev/docs/codegen), [locators docs](https://playwright.dev/docs/locators)) | Codegen chooses locators "prioritizing role, text and test id locators" and refines a locator until it matches one element. The docs rank user-facing locators first: `getByRole` with an accessible name, then `getByLabel`, `getByPlaceholder`, `getByText` and `getByTestId`. CSS and XPath come last because "the DOM can often change". Codegen keeps logins in a persistent `--user-data-dir`. It warns that Chrome 136+ refuses the default Chrome profile for automation, so a separate profile is needed. |
| **Playwright actionability** ([actionability docs](https://playwright.dev/docs/actionability)) | Before acting, Playwright waits until the element is visible, *stable* (the same bounding box for two animation frames), enabled, able to receive events and editable. We rely on `locator.click/fill/...` for this. On top of it we add a DOM-quiet wait (no mutations for 300 ms) and a short network-idle wait between steps. |
| **Selenium IDE** ([repo, Apache-2.0](https://github.com/SeleniumHQ/selenium-ide), [.side format example](https://github.com/syarig/selenium-side-converter)) | Every recorded command keeps one `target` plus a `targets` list of alternative locators (id, css, xpath, link text). The README's roadmap describes "collecting as many attributes as we can per user event", with the most reliable ones first and the rest as fallbacks. We store an ordered `selectors[]` list per step for the same reason. |
| **Healenium** ([how it works](https://healenium.io/docs/how_healenium_works), [healenium-web](https://github.com/healenium/healenium-web)) | Healenium stores a snapshot of each element (its path and attributes) from the last successful run. When a locator fails, it compares the stored path with the current DOM using an LCS-style algorithm, scores the candidates, and uses the best one above a `score-cap` threshold (0.5 in their example). It can then write the healed locator back. We store a **fingerprint** per step: tag, role, accessible name, text, id, classes, key attributes, label and ancestor tag path. When every selector fails, we score all elements on the page against it (weighted string similarity plus an LCS ratio on the ancestor path) and accept the best one above 0.6, and only if it clearly beats the runner-up. Healed selectors are put first in the list, and the old ones stay as fallbacks. |
| **Automa** ([docs: blocks](https://docs.automa.site/workflow/blocks.html), [looping](https://docs.automa.site/workflow/looping.html); AGPL, so **no code was used**) | A flow is a graph of blocks (Trigger → New tab → Forms → Delay → ...). Each block can retry or fall back on error. Loop Data iterates over a table and reads values as `{{loopData.x}}`. Our read-only graph draws Trigger → step cards with connectors, and our flows use `{{variable}}` substitution with a CSV loop. |
| **UI.Vision RPA** ([csvRead docs](https://ui.vision/rpa/docs/selenium-ide/csvread)) | Each loop iteration reads one CSV line, and the columns become `${!COL1}...`. We use the header row instead, so the columns become `{{header}}` variables, with one replay per row. |
| **Bardeen** (product docs) | Bardeen runs automations only after an explicit trigger or a click, and it shows a run log. We do the same: the trigger is always **Manual**, and there is no schedule or automatic run. |

## Architecture

```
Swift (SparkV)                              Node (Vendor/browser-recorder)
BrowserRecorderController ──spawn──▶ node runner.mjs record|replay ...
   ▲   stdin: {"cmd":"stop"} / {"vars":{...}}      │ playwright-core 1.64.1 (= chromium-1248 installed)
   └── stdout JSON lines: step / progress / healed / stepFailed / flow / done / error
```

* **Pinning.** `playwright-core@1.64.1` declares chromium revision `1248`, and that revision is installed in
  `~/Library/Caches/ms-playwright`. We use `playwright-core` rather than `playwright` because it has no
  postinstall step that downloads browsers.
* **Record.** `launchPersistentContext(~/Library/Application Support/SparkV/BrowserRecorder/Profile)` opens a headed
  browser, so the user's logins persist. `exposeBinding('__nirEmit')` and `addInitScript(inject.js)` run in every
  page of the context; only the top frame records. Recorded actions: navigate (typed by the user, not caused by a
  click), click, dblclick, fill (merged per field), press (Enter/Tab/Escape), select, check/uncheck, upload (file
  names only), scroll (debounced) and a "Wait for element" pick mode from the in-page overlay.
  **Passwords:** for `type=password` fields, and for fields whose name or autocomplete looks like a card, CVV, OTP or
  SSN field, the page script never reads the value. It sends `masked:true` and the value `{{password}}`
  (or `{{secret}}` for the other kinds).
* **Replay.** Steps run in order, each with up to 3 attempts. Between steps the runner waits for the DOM to settle
  and for the page load to finish. Target resolution:
  1. Each stored selector, tried in order, until one matches exactly **one** visible element.
  2. After about 30% of the step timeout with no match, a fuzzy fingerprint match.
  3. If nothing matches, the step fails: the runner saves a full-page screenshot and emits `stepFailed`.

  `{{vars}}` are filled in from the stdin vars and then from the CSV row. One pass runs per CSV row.
* **Safety.** The runner refuses flows that contain purchase, payment or delete words unless `--allow-risky`
  is passed, and Swift passes it only after an NSAlert confirmation. Delays are capped at 120 s, CSVs at 500 rows,
  each run at 60 minutes and each flow at 2000 steps. Secrets are passed over stdin, never on the command line. Nothing
  runs on its own.
