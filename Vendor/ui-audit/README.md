# ui-audit runner

A Node runner for SparkV's UI / frontend audit. See `Sources/Labs/UIAudit/DESIGN.md` for how it works.

```
npm ci                                   # playwright-core 1.64.1 + axe-core 4.14.0 (exact pins)
node audit.mjs --url http://localhost:3000 --mode full     # headed Chromium window
node audit.mjs --config run.json --stdin-control           # how the app runs it
node test/run-test.mjs                                     # self-check against planted-issue fixtures (headless)
```

- `playwright-core@1.64.1` uses Chromium revision **1248**, which must be installed in `~/Library/Caches/ms-playwright/chromium-1248` (headed) and `chromium_headless_shell-1248` (headless). If it is missing: `npx playwright-core install chromium`.
- Modes: `ui`, `forms`, `a11y`, `full`. Options: `--max-pages`, `--max-depth`, `--allow-submit`, `--allow-dangerous`, `--allow-origin <origin>` (repeatable), `--headless`, `--out DIR`, `--rate-ms`, `--max-seconds`.
- stdout carries JSON lines. stdin takes `pause`, `resume` and `stop`. Output is `report.json`, `report.md`, `report.html` and `screenshots/`.
- `fixtures/` holds the files used for `<input type=file>` uploads.
- `test/` is development-only and does not need to be bundled.

## Licenses

- playwright-core: Apache-2.0, © Microsoft Corporation.
- axe-core: MPL-2.0, © Deque Systems, Inc. Used unmodified; its source is in `node_modules/axe-core`.
- The runner code (`audit.mjs`, `lib/`, `test/`) is original SparkV code.
