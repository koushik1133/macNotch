# SparkV Investor Deck: Phase 2 Structural Blueprint

| Item | Value |
| --- | --- |
| Deck | SparkV seed investor deck: 16 slides plus 2 hidden appendix slides |
| Audience | Angel and seed investors |
| Goal | A follow-up meeting and a cheque |
| Narrative | Problem → solution → live demo → product depth (meetings, proof run) → why now → market (sourced) → competition → business model → unit economics → go to market → traction and readiness → roadmap and risks → team [TBD] → the ask [TBD] and use of funds |
| Canvas | 3840 × 2160 px (16:9 UHD). python-pptx: 13.333 × 7.5 in, 288 px per inch, 1 px = 3175 EMU |
| Machine-readable twin | `docs/decks/investor/outline.json`. All slide copy below is generated from it, so the two never drift. |
| Inputs | `docs/SparkV-Feature-Guide.md`, `docs/SparkV-Business-Plan.md`, `docs/screenshots/*.png` (50 real dark renders), `docs/decks/style-demos/*` (the three approved styles), public figures cited in §6 |
| Sibling decks | Shares the recording rig, crop names and coordinates with `docs/decks/customer/BLUEPRINT.md` §3.1, so one recording session can serve both decks |
| Date | 22 Oct 2026 |

---

## 0. Ground rules for anyone finishing this deck

1. **Only real facts.** Every number comes from the two project docs or a public source in §6. Anything the project does not have is a visible placeholder, for example `[TBD: waitlist signups]`. Never replace a `[TBD]` with a guess, and never delete one silently.
2. **No invented traction, users, revenue or team.** SparkV is pre-launch and pre-revenue. Slide 13 shows internal test results and says so. Slide 15 is all placeholders apart from the studio line from sparkv.si.
3. **Do not claim or show:**
   - **Face Unlock.** The ArcFace weights are licensed for non-commercial use only (business plan §8). Slide 14 names it as a blocker; no slide shows the feature.
   - **Live team sync of Spaces.** Team "shared Spaces" is a `.sparkvspace` file package today (business plan §6a).
   - **"Controls any app."** The screen assistant points and explains, Dictation and Reply Drafter type where the cursor is, and UI Audit and Browser Flows drive their own Chromium (feature guide, Known limits 5).
   - **"On the Mac App Store."** SparkV is sold direct, by design (business plan §5).
4. **Features marked "Needs a live check"** (Dictation, the screen assistant, Meetings, Live Translation, live activities and others, see each slide's claim status) are claimed only if the 4K take in §3 shows them working. If a take fails, cut the claim; never fake a take.
5. **Browser Flows is "beta".** Its self-test was not clean on 22 Oct (feature guide §27). It appears only in lists, never as a hero.
6. **Names.** "Clicky" may be renamed before launch (business plan §7 suggests "SparkV Assist"). Slide copy says "screen assistant"; the name appears only in notes, through `deck.feature_names.clicky`. Competitor names appear only as plain-text wordmarks (no logos) in factual price and job comparisons (slides 2 and 9). Get a legal check before the deck circulates widely.
7. **Competitor prices come from third-party listings** (business plan §3). Re-check each vendor's own pricing page on the day you send the deck.
8. **Sample-data hygiene.** `16-universal-search-panel.png` shows a sample note "Three tiers: Free, Pro $9, Team $19 per seat". That contradicts the real pricing on slide 10 and will confuse investors. Use the I06 re-capture or blur that row. `46-compact-wings.png` is clipped in the offscreen render (feature guide, Known limits 4); do not use it.
9. **Requirements to state when asked:** Apple silicon, macOS 15 or later, best on a MacBook with a notch (elsewhere the island sits in the menu bar). UI Audit needs Node.js 20+, Browser Flows Node.js 18+.

---

## 1. Complete outline

### 1.1 Slide map

| # | Layout | Header | Visual |
| --- | --- | --- | --- |
| 1 | `key_visual_header` | Your notch, now an AI command center. | 01-home.png; clip I01 |
| 2 | `metrics_dashboard` | Mac power users rent five apps for one workflow. | chart C1 |
| 3 | `feature_showcase` | One drawer. Every tool. Right under the camera. | 01-home.png, 10-agents-hub.png; clip I02 |
| 4 | `feature_showcase` | Live demo: 90 seconds, all on the Mac. | 16-universal-search-panel.png, 36-meeting-notes.png, 50-dictation.png, 51-clicky-answer.png; clip I03 |
| 5 | `feature_showcase` | Meeting notes without a bot in the call. | 36-meeting-notes.png, 37-meeting-live-answers.png, 38-live-translation.png; clip I04 |
| 6 | `metrics_dashboard` | Proof it works: one real UI Audit run. | 22-ui-audit-window.png; clip I05 |
| 7 | `timeline` | Why now: the AI already ships inside the Mac. | type and tiles |
| 8 | `metrics_dashboard` | A big, paying, AI-curious audience. | chart C2; table T8 |
| 9 | `two_column_comparison` | Five jobs, one app, one price. | chart P9; table T9 |
| 10 | `pricing_table` | Free to start. $39 once for everything. | table T10 |
| 11 | `metrics_dashboard` | We keep about 94% of every Pro sale. | chart C3; chart C4; table T11 |
| 12 | `timeline` | Go to market: waitlist to Product Hunt in 30 days. | type and tiles |
| 13 | `metrics_dashboard` | Built and tested. Launch numbers come next. | type and tiles |
| 14 | `timeline` | Four known blockers, all scheduled. | type and tiles |
| 15 | `minimal_body` | Team | type and tiles |
| 16 | `cta` | The ask | 01-home.png; chart C5 |
| A1 | `feature_showcase` | Appendix: every feature, one hover | 12-render grid |
| A2 | `minimal_body` | Appendix: sources | type and tiles |

Every required visual type is present: app screenshots in notch mockups (1, 3, 4, 16, A1), window screenshots (4, 5, 6), clips (1, 3, 4, 5, 6), a pricing table (10), a competitor comparison matrix and positioning map (9), a cost comparison chart (2), a market chart (8), revenue and unit-economics charts (11) and a use-of-funds chart (16). Each chart's data table and source label is printed under its slide.

### 1.2 Slides

#### Slide 1: Title

- **Layout:** `key_visual_header`
- **Header:** Your notch, now an AI command center.
- **Subtitle:** Dictation, meetings, screen help and 20+ tools in one Mac app. Private by default. Pay once.
- **Body (exact):**
  - SparkV for macOS
  - Seed round · [TBD: month and year]
  - sparkv.si
- **Speaker notes:** SparkV turns the MacBook notch into a drawer that opens when you hover it: media, a file tray, your day, a converter, knowledge Spaces and a hub of more than 20 agents. The AI runs on the Mac by default, so we pay nothing per user for AI. That is why we can sell it once instead of monthly. In two minutes I will show it working, then the numbers.
- **Screenshots:**
  - `docs/screenshots/01-home.png`: hero_drawer, frame `notch_mockup`, at x 1155, y 1100, w 1530, h 352; scale 1.25x; 4K replacement `media/stills/I01-hero-0005-R-DRAWER-HOME.png`; Screen rect bleeds off the bottom edge. Prefer the 4K still from clip I01.
- **Clip:** I01 (`media/rec/I01-hero.mov`, 00:00-00:08) at x 1011, y 1100, w 1818, h 1023; Keynote/video export only; PPTX uses the still
- **Claim status:** 20+ tools: *verified headless* (Agents hub has 22 cells (fg section 8); positioning line (bp section 10))

#### Slide 2: Problem

- **Layout:** `metrics_dashboard`
- **Header:** Mac power users rent five apps for one workflow.
- **Subtitle:** Notch, clipboard, dictation, meeting notes and screenshots are sold separately, and the AI ones are subscriptions.
- **Body (exact):**
  - $395.99 in year one for five separate apps
  - $312 a year for AI dictation plus AI meeting notes
  - Five shortcuts, five windows, five bills
- **KPI tiles:** **$395.99** year one, five separate apps · **$312/yr** Wispr Flow + Granola, recurring · **$39** SparkV Pro, once
- **Speaker notes:** This is the stack a busy Mac user ends up with: a notch app, a clipboard manager, a dictation app, a meeting-notes app and a screenshot tool. Using public list prices, year one costs about $396, and the two AI subscriptions alone are $312 a year, every year. Cloud AI has a cost on every request, and subscriptions are the norm for these tools. We do not have that cost; it is the core of our business model.
- **Screenshots:** none (data slide)

**Chart C1: Year-one cost of five separate apps vs SparkV Pro (USD)** (`bar_horizontal`, sourced). Placement: x 192, y 600, w 2112, h 1300 px.

| product | job | basis | usd_year1 | source_id |
| --- | --- | --- | --- | --- |
| Granola | AI meeting notes | $14 per user per month x 12 (Business) | 168.0 | granola |
| Wispr Flow | AI dictation | $144 per year (Pro, yearly) | 144.0 | wispr |
| Paste | Clipboard manager | $29.99 per year | 29.99 | paste |
| CleanShot X | Screenshots and recording | $29 one-time (1 year of updates) | 29.0 | cleanshot |
| NotchNook | Notch hub | $25 one-time | 25.0 | notchnook |
| Five apps total |  | sum | 395.99 | bp |
| SparkV Pro | All five jobs | $39 one-time, 12 months of updates (launch week $29) | 39.0 | bp |

- Annotation: Wispr Flow + Granola alone: $312 per year
- Sources: [Granola pricing, Granola blog](https://granola.ai/blog/granola-pricing-plans-features-roi); [Wispr Flow pricing, via getvoibe](https://www.getvoibe.com/resources/wispr-flow-pricing/); [Paste on the App Store](https://apps.apple.com/app/id967805235); [CleanShot X pricing, via toolradar](https://toolradar.com/tools/cleanshot/pricing); [NotchNook price, via iMore](https://www.imore.com/apps/mac-apps/this-dollar25-app-gives-my-macbook-pro-a-dynamic-island-and-it-was-worth-every-penny); SparkV Business Plan (docs/SparkV-Business-Plan.md), researched 22 Oct 2026
- Footnote on slide: "Prices from third-party listings cited in the SparkV business plan (section 3), Oct 2026. Re-check vendor pages before sending."

#### Slide 3: Solution

- **Layout:** `feature_showcase`
- **Header:** One drawer. Every tool. Right under the camera.
- **Subtitle:** Hover the notch: 12 header buttons, 21 drawer pages and a 22-tile agents hub.
- **Body (exact):**
  - Notch core: media, volume and battery, tray, AirDrop, your day
  - Productivity: clipboard, converter, downloads, search, Spaces
  - AI: dictation, screen help, reply drafts, meetings, translation
  - Developer tools: UI Audit, Browser Flows, Flow Canvas
- **Speaker notes:** Everything lives in one place the user already looks at. Hover the notch and the drawer opens; move away and it closes. The header has six pages on the left and six actions on the right, and the agents hub launches every tool. When the drawer is closed, live activities such as volume, battery, AirPods, notifications, meetings and recordings show beside the camera. All 21 drawer pages render in the real app layout, and every tile and hotkey is wired.
- **Screenshots:**
  - `docs/screenshots/10-agents-hub.png`: hero_drawer, frame `notch_mockup`, at x 2043, y 560, w 1530, h 570; scale 1.25x; 4K replacement `media/stills/I02-tour-0014-R-DRAWER-HUB.png`
  - `docs/screenshots/01-home.png`: secondary_drawer, frame `card`, at x 2196, y 1220, w 1224, h 282; scale 1.0x; Home page card overlapping the device by 80 px; optional in style B
- **Clip:** I02 (`media/rec/I02-tour.mov`, 00:00-00:24) at x 1968, y 560, w 1680, h 945
- **Claim status:** 21 drawer pages, 22 hub tiles, all wired: *verified headless* (fg sections 1, 8 and verification summary)

#### Slide 4: Live demo

- **Layout:** `feature_showcase`
- **Header:** Live demo: 90 seconds, all on the Mac.
- **Subtitle:** Talk, ask, record and find, with Groq switched off.
- **Body (exact):**
  - Hold fn, speak, release: clean text is typed for you
  - Hold ⌃⌥ and ask: SparkV answers and points to the spot
  - One click records a meeting: tasks, decisions, answers
  - ⌥Space finds anything you saw, with cited answers
- **Speaker notes:** Run this live on the demo Mac; the film I03 is the backup if the room's Wi-Fi, audio or permissions fail. Order: dictation into TextEdit, the screen assistant in Preview, a short recorded meeting, then Universal Search for 'launch' and the agents hub. Say out loud that Groq is off, so everything is on-device. Do not say SparkV clicks or types through other apps on its own: the assistant points and explains; dictation types where your cursor is. The screen assistant is called Clicky in the app today and may be renamed before launch.
- **Screenshots:**
  - `docs/screenshots/50-dictation.png`: fallback_still_1, frame `band`, at x 1344, y 560, w 1000, h 140; src crop [212, 0, 800, 112]; scale 1.25x; 4K replacement `media/stills/I03-demo-0014-R-BAND.png`
  - `docs/screenshots/51-clicky-answer.png`: fallback_still_2, frame `band`, at x 2512, y 560, w 1010, h 205; src crop [208, 0, 808, 164]; scale 1.25x; 4K replacement `media/stills/I03-demo-0031-R-BAND.png`
  - `docs/screenshots/36-meeting-notes.png`: fallback_still_3, frame `window`, at x 1344, y 1100, w 1136, h 765; scale 0.58x
  - `docs/screenshots/16-universal-search-panel.png`: fallback_still_4, frame `window`, at x 2512, y 1100, w 1136, h 803; scale 0.78x; 4K replacement `media/stills/I06-search.png`; **WARNING:** The render's 'Pricing call notes' row shows sample prices (Pro $9, Team $19) that contradict real pricing. Use the I06 re-capture with corrected sample data, or blur that row.
- **Clip:** I03 (`media/rec/I03-demo.mov`, 00:00-01:30) at x 1344, y 560, w 2304, h 1296
- **Claim status:** Dictation types cleaned text: *needs a live check* (fg section 9) · Screen assistant answers and points: *needs a live check* (fg section 10) · Meeting notes with tasks, decisions, answers: *needs a live check* (fg section 31) · Universal Search with cited answers: *verified headless* (fg section 12 (21 results for 'launch' on sample data))

**Demo run sheet (live, 90 s; the same beats as clip I03 in §3.3):** 1) hover the notch, Home opens; 2) TextEdit, hold fn, say the dictation line, release; 3) Preview, hold ⌃⌥, ask "Where do I change the export format?"; 4) header record button, the partner asks the scripted question, the suggested answer appears, stop; 5) the meeting notes window, Notes tab then Answers tab; 6) ⌥Space, type "launch", Tab for Ask; 7) agents hub sweep. If any beat fails live, switch to the film at that timestamp; do not retry on stage.

#### Slide 5: Meetings

- **Layout:** `feature_showcase`
- **Header:** Meeting notes without a bot in the call.
- **Subtitle:** SparkV records your mic and the call audio, transcribes on device and hands you the follow-ups.
- **Body (exact):**
  - Minutes, key points, decisions and your tasks with due days
  - Suggested answers when someone asks you a question
  - Live translated captions, with the original underneath
  - Filed into Spaces and searchable later
- **Speaker notes:** This is the feature people pay Granola $14 per user per month for. In SparkV it is part of Pro at one price, because transcription and summaries run on the Mac. No bot joins the call, and audio does not leave the machine unless the user turns on their own Groq key. Status: the notes and answers views render from saved meetings; live audio capture is on our pre-launch live-check list.
- **Screenshots:**
  - `docs/screenshots/36-meeting-notes.png`: hero_window, frame `window`, at x 1660, y 560, w 1960, h 1320; scale 1.0x; 4K replacement `media/stills/I04-meetings-0024.png`
  - `docs/screenshots/37-meeting-live-answers.png`: build_step_2, frame `window`, at x 1660, y 560, w 1960, h 1320; scale 1.0x; 4K replacement `media/stills/I04-meetings-0029.png`; crossfade on click 1
  - `docs/screenshots/38-live-translation.png`: secondary_card, frame `card`, at x 192, y 1480, w 1280, h 400; scale 1.0x; 4K replacement `media/stills/I04-meetings-0012.png`
- **Clip:** I04 (`media/rec/I04-meetings.mov`, 00:00-00:30) at x 1632, y 560, w 2016, h 1134
- **Claim status:** Records mic and system audio, transcribes on device: *needs a live check* (fg section 31) · Live Translation captions: *needs a live check* (fg section 24)

#### Slide 6: Proof (UI Audit)

- **Layout:** `metrics_dashboard`
- **Header:** Proof it works: one real UI Audit run.
- **Subtitle:** SparkV crawled a test site, found the planted bugs and wrote the fix prompt.
- **Body (exact):**
  - Summary written on device by Apple Intelligence
  - Fix prompt pastes straight into Claude Code, Cursor or Copilot
  - Runs only on sites you own or may test
- **KPI tiles:** **69** findings across 6 pages · **3 · 15** critical · high severity · **51,666** characters in the fix prompt (60 issues) · **48/48** runner self-tests pass
- **Speaker notes:** This is not a mock-up. SparkV's own UI Audit controller audited a bundled test site with planted issues on 127.0.0.1: six pages, 69 findings, three of them critical and fifteen high. Apple Intelligence wrote the summary on device, and the P button produced a 51,666-character fix prompt covering 60 issues. The runner's self-test passes 48 of 48, including never sending a form to a non-test host and never clicking logout or delete. It needs Node.js on the Mac. Its sibling, Browser Flows, is still in beta: its self-test was not clean on 22 October.
- **Screenshots:**
  - `docs/screenshots/22-ui-audit-window.png`: hero_window, frame `window`, at x 1728, y 560, w 1920, h 1280; scale 0.889x; 4K replacement `media/stills/I05-ui-audit-0020-R-WINDOW-C.png`
- **Clip:** I05 (`media/rec/I05-ui-audit.mov`, 00:00-00:30) at x 1728, y 640, w 1920, h 1080
- **Claim status:** 6 pages, 69 findings (3 critical, 15 high), 51,666-char prompt, 48/48: *verified headless, end to end* (fg section 25 and verification summary)
- **Footnote on slide:** "Internal test, 22 Oct 2026, planted-issue site on 127.0.0.1 (feature guide section 25)."

#### Slide 7: Why now

- **Layout:** `timeline`
- **Header:** Why now: the AI already ships inside the Mac.
- **Subtitle:** Apple silicon and Apple's on-device models make private AI with zero cost per request possible.
- **Body (exact):**
  - Cloud AI apps pay for every request. SparkV pays $0.
  - Works offline. Audio and screens stay on the Mac.
  - Every MacBook Pro since 2021 has a notch to build on.
- **Timeline nodes:** **Oct 2021** 14- and 16-inch MacBook Pro introduce the notch → **Jun 2023** Mac Pro moves to M2 Ultra: every Mac is now Apple silicon → **Jun 2025** Foundation Models framework opens Apple's on-device model to apps, 'without cloud API costs' → **2025** 25.6M Macs shipped, up 11.1% → **Next** SparkV 1.0: notarized direct download [TBD: launch date]
- **Speaker notes:** Three things lined up. The notch arrived on the MacBook Pro in 2021. Since mid-2023 every Mac Apple sells runs Apple silicon. And at WWDC 2025 Apple opened its on-device model to developers; in Craig Federighi's words, it runs without cloud API costs and works offline. That turns AI from a per-request cost into a free capability of the hardware. Competitors built on cloud models have to charge monthly. We do not.
- **Screenshots:** none (data slide)

#### Slide 8: Market

- **Layout:** `metrics_dashboard`
- **Header:** A big, paying, AI-curious audience.
- **Subtitle:** Sized bottom-up from public Mac data. Our own funnel numbers are [TBD] until launch.
- **Body (exact):**
  - TAM: 100M+ active Macs (Apple, 2018; latest public figure)
  - SAM: [TBD: Apple-silicon MacBooks with a notch on macOS 15+]
  - SOM: [TBD: year-3 paid users target]
- **KPI tiles:** **25.6M** Macs shipped in 2025 (IDC, prelim.) · **100M+** active Macs (Apple, Oct 2018) · **83%** of surveyed Mac users paid for software in the past month (Setapp 2023, n=1,241) · **42%** use AI apps daily (same survey)
- **Speaker notes:** I will not show you a made-up market number. What is public: IDC counts 25.6 million Macs shipped in 2025, up 11 percent, and Apple last said there were 100 million active Macs, in 2018. Setapp's 2023 survey of its own audience found 83 percent had paid for Mac software in the past month and 42 percent use AI apps daily; that is a survey of Mac app buyers, not of all Mac owners. The notched-MacBook share of that base is the number we still need to source, and it is marked TBD.
- **Screenshots:** none (data slide)

**Chart C2: Mac shipments worldwide (millions of units)** (`column_clustered`, sourced (2024 bar derived)). Placement: x 2016, y 600, w 1632, h 760 px.

| period | mac_units_m | basis | source_id |
| --- | --- | --- | --- |
| FY2024 | 23.0 | derived: 25.6 / 1.111 (IDC growth rate); draw this bar with a hatched or 60% fill | idc_fy25 |
| FY2025 | 25.6 | IDC preliminary | idc_fy25 |
| Q2 2024 | 5.1 | IDC preliminary (annotation only) | idc_q2_25 |
| Q2 2025 | 6.2 | IDC preliminary, +21.4% (annotation only) | idc_q2_25 |
| Q4 2025 | 7.1 | IDC preliminary, 9.3% PC share (annotation only) | idc_fy25 |

- Annotation: +11.1% in 2025
- Annotation: Q4 2025: 7.1M, 9.3% of PCs
- Sources: [IDC preliminary Q4/FY2025 PC tracker, via 9to5Mac (13 Jan 2026)](https://9to5mac.com/2026/01/13/apple-shipments-unchanged-as-pc-market-grew-during-q4-2025/); [IDC preliminary Q2 2025, via MacTrast (Jul 2025)](https://www.mactrast.com/2025/07/new-data-released-by-idc-shows-mac-shipments-are-continuing-to-increase/)
- Footnote on slide: "IDC preliminary data via 9to5Mac (Jan 2026) and MacTrast (Jul 2025). 2024 bar derived from IDC's growth rate."

**Table T8: Sizing funnel** Placement: x 2016, y 1420, w 1632, h 480 px.

| Layer | Definition | Figure | Source |
| --- | --- | --- | --- |
| TAM | Active Macs | 100M+ (2018) | apple_100m |
| SAM | Apple-silicon MacBooks with a notch, macOS 15+ | [TBD: count] | [TBD: method: notched-model share of shipments 2021-2025 x survival] |
| SOM | Paid Pro + Team seats in 3 years | [TBD: target] | [TBD] |

**How to fill the SAM placeholder (do not guess):** take notched models (MacBook Pro 14/16 from Oct 2021, MacBook Air from M2) × their share of IDC or Omdia Mac shipments for 2021 to 2025, adjust for retirements, and cite each input. If no defensible public figure exists, keep the `[TBD]` and say in the meeting that the funnel will be measured from beta data.

#### Slide 9: Competition

- **Layout:** `two_column_comparison`
- **Header:** Five jobs, one app, one price.
- **Subtitle:** Each rival owns one job. SparkV covers all five and charges once.
- **Body (exact):**
  - Breadth: 20+ tools behind one hover
  - Pay once: no AI bill to pass on
  - Private by default: on-device models
- **Speaker notes:** Read the matrix by column: every competitor is excellent at one job. Notch apps such as NotchNook are built around media and a file tray, and the free open-source one is not notarized. The AI tools, Wispr Flow, Granola and Raycast Pro, are sold as subscriptions. SparkV is the only one in this set that combines the notch with the AI jobs and charges once. The honest risk: any of them can add features. Our answer is breadth plus integration, because Spaces and Search tie meetings, dictation, clipboard and captures together, and the cost structure lets us stay one-time. Prices are from third-party listings; we re-check them before every send.
- **Screenshots:** none (data slide)

**Chart P9: Positioning (qualitative)** (`scatter_2x2`, qualitative; y position from each product's price model (cited), x from its main job). Placement: x 2832, y 560, w 816, h 816 px.

| Product | x (point tool 0 → suite 1) | y (subscription 0 → pay once 1) |
| --- | --- | --- |
| SparkV | 0.9 | 0.9 |
| NotchNook | 0.25 | 0.7 |
| Alcove | 0.15 | 0.85 |
| boring.notch | 0.2 | 0.95 |
| CleanShot X | 0.3 | 0.6 |
| Paste | 0.15 | 0.35 |
| Raycast Pro | 0.6 | 0.15 |
| Wispr Flow | 0.2 | 0.1 |
| Granola | 0.3 | 0.1 |


**Table T9: Jobs covered and price model** Placement: x 192, y 560, w 2496, h 1280 px.

| Job | SparkV | NotchNook | Alcove | boring.notch | Paste | Wispr Flow | Granola | CleanShot X | Raycast Pro |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Notch drawer and live activities | ● | ● | ● | ● |  |  |  |  |  |
| Clipboard history | ● |  |  |  | ● |  |  |  |  |
| AI dictation | ● |  |  |  |  | ● |  |  |  |
| AI meeting notes | ● |  |  |  |  |  | ● |  |  |
| Screenshots and recording | ● |  |  |  |  |  |  | ● |  |
| Search and AI answers | ◐ |  |  |  |  |  |  |  | ● |
| Price | $39 once | $25 once or $3/mo | ~$13.99 once | Free (GPL) | $29.99/yr | $15/mo | $14/user/mo | $29 + $19/yr opt. | $8-10/mo |

Legend (on slide, caption size): "● = the product's main job per the cited listing. ◐ = SparkV Universal Search with cited answers; not a full app launcher. Blank = not that product's main job; this is not a full feature audit."

#### Slide 10: Business model and pricing

- **Layout:** `pricing_table`
- **Header:** Free to start. $39 once for everything.
- **Subtitle:** Sold direct, with Lemon Squeezy as merchant of record for tax and license keys.
- **Body (exact):**
  - Free hooks users away from free notch apps
  - Pro is one price for every feature
  - Team adds recurring revenue from companies
- **Speaker notes:** Three plans. Free is a useful notch app at zero, which competes with the free open-source option and gives reviewers something to try. Pro is $39 once, $29 in launch week, and includes every feature; buyers on r/macapps prefer one-time prices and CleanShot X shows the model works. Team is $8 per seat per month, billed yearly, minimum three seats, for companies that need invoices, seat management and an MDM package. We are not on the Mac App Store because SparkV needs Accessibility and other APIs the sandbox does not allow; Lemon Squeezy handles VAT, GST and sales tax worldwide. Shared Spaces for Team is a file package today, not live sync.
- **Screenshots:** none (data slide)

| | Free | Pro (Recommended) | Team |
| --- | --- | --- | --- |
| Price | $0 | $39 once | $8 per seat / month, billed yearly |
| INR | ₹0 | ₹1,499 | ₹499 |
| Line 1 | Notch core: media, HUD, battery, tray, Today, timer | Everything: all AI assistants, meetings, dev tools | Minimum 3 seats; one invoice (PO or bank transfer) |
| Line 2 | World Clock and System Gauges | 2 Macs per person, 12 months of updates | Seat management, shared Spaces packages |
| Line 3 | Clipboard history (last 25), Copy Text | Optional renewal $19/yr; the app never stops working | Priority support, 1 business day |
| Line 4 | Dictation without AI formatting | Launch week: $29 (₹999) | Deployment .pkg for MDM |

Footer strip: "14-day full Pro trial, no card · 50% student discount · 30-day refunds · Alternative held back: five feature packs at $9-19 each (all five = $39)"

#### Slide 11: Unit economics

- **Layout:** `metrics_dashboard`
- **Header:** We keep about 94% of every Pro sale.
- **Subtitle:** On-device AI means no inference bill. The only variable cost is the payment fee.
- **Body (exact):**
  - $0 AI cost per user
  - $99 a year fixed (Apple Developer); no MoR monthly fee
  - 3 Pro sales cover the fixed Apple fee
- **KPI tiles:** **$0** AI cost per user · **$99/yr** fixed platform cost (Apple Developer Program)
- **Speaker notes:** Our gross margin is the payment fee and nothing else. On a $39 sale Lemon Squeezy takes 5 percent plus 50 cents, so we keep $36.55; about $36 from a non-US buyer. AI runs on the Mac, and the optional Groq path uses the buyer's own key, so inference costs us nothing. Fixed costs are the $99 Apple Developer fee, a domain and static hosting for the site and update feed. The chart on the right is arithmetic, not a forecast: it shows what tiny shares of one year's Mac shipments would be worth. Our real revenue plan is marked TBD until the beta gives us a conversion rate.
- **Screenshots:** none (data slide)

**Chart C3: What we keep from one $39 Pro sale (US buyer, USD)** (`waterfall`, sourced arithmetic). Placement: x 192, y 560, w 2016, h 1000 px.

| step | usd | basis | source_id |
| --- | --- | --- | --- |
| List price | 39.0 | Pro one-time | bp |
| MoR fee 5% | -1.95 | Lemon Squeezy 5% | lemonsqueezy |
| Per-order fee | -0.5 | Lemon Squeezy 50c | lemonsqueezy |
| AI inference | 0.0 | on-device; Groq optional with the buyer's own key | bp |
| Net to SparkV | 36.55 | 93.7% of list | bp |

- Annotation: Non-US buyer: about +1.5% fee, net $35.97
- Annotation: Affiliate-sourced sale (30% commission): net about $24.85
- Sources: SparkV Business Plan (docs/SparkV-Business-Plan.md), researched 22 Oct 2026; [Lemon Squeezy fees, via Dodo Payments review](https://dodopayments.com/blogs/lemonsqueezy-review)
- Footnote on slide: "Fee schedule from the business plan section 4. Excludes refunds [TBD: refund rate], support time and DMG bandwidth (20-60 MB per download)."

**Chart C4: Illustrative only: net revenue if a share of ONE year's Mac shipments bought Pro** (`column_clustered`, illustrative scenario, clearly not a forecast). Placement: x 2400, y 1060, w 1248, h 900 px.

| share_of_2025_shipments | pro_sales | net_per_sale_usd | net_revenue_usd |
| --- | --- | --- | --- |
| 0.01% | 2560 | 36.55 | 93568 |
| 0.05% | 12800 | 36.55 | 467840 |
| 0.10% | 25600 | 36.55 | 935680 |

- Annotation: Arithmetic on 25.6M (IDC 2025) x share x $36.55. Not a forecast. Our forecast: [TBD: revenue plan]
- Sources: [IDC preliminary Q4/FY2025 PC tracker, via 9to5Mac (13 Jan 2026)](https://9to5mac.com/2026/01/13/apple-shipments-unchanged-as-pc-market-grew-during-q4-2025/); SparkV Business Plan (docs/SparkV-Business-Plan.md), researched 22 Oct 2026

**Table T11: Net per sale by plan (USD)** Placement: x 192, y 1620, w 2016, h 400 px.

| Plan | Price | Net, US buyer | Net, non-US buyer |
| --- | --- | --- | --- |
| Pro | $39.00 | $36.55 | $35.97 |
| Pro, launch week | $29.00 | $27.05 | $26.62 |
| Pro, student | $19.50 | $18.03 | $17.73 |
| Team, per seat-year (3-seat order) | $96.00 | $90.55 | $89.11 |

Basis: Lemon Squeezy 5% + $0.50 per order; +1.5% non-US; +0.5% on subscriptions (Team). Team row = (3 x $96 - 5.5% - $0.50) / 3.

#### Slide 12: Go to market

- **Layout:** `timeline`
- **Header:** Go to market: waitlist to Product Hunt in 30 days.
- **Subtitle:** Demo-first and creator-led. Affiliates earn 30%, only when a sale happens.
- **Body (exact):**
  - Product Hunt, r/macapps App Pile, Show HN
  - YouTube: one 2-4 min demo plus a 30 s Short per feature
  - Comparison pages: SparkV vs NotchNook, Alcove, boring.notch
- **Timeline nodes:** **Days 1-3** Apple Developer ID, Lemon Squeezy products, domain → **Days 4-7** Legal pages; Face Unlock out of the sold build → **Days 8-12** Licensing, trial, Sparkle updates, notarization → **Days 13-15** Clean-Mac install and update test → **Days 16-18** Landing page, pricing, waitlist → **Days 19-22** Demo video, 5 Shorts, keys to 10-15 creators → **Days 23-25** Private beta, 30-50 users, 5 testimonials → **Day 26** Ship 1.0 at the launch price → **Day 27** Product Hunt (Tue/Wed), r/macapps, X, LinkedIn, waitlist email → **Days 28-30** Show HN, affiliates open, retrospective
- **Channel chips:** Product Hunt · r/macapps · YouTube creators (20k-300k subs) · Lemon Squeezy affiliates (30%, 30-day cookie) · Show HN / Indie Hackers · Setapp (month 3+)
- **Target chips:** [TBD: waitlist target] · [TBD: trial-to-paid target] · [TBD: CAC by channel] · [TBD: creator reach]
- **Speaker notes:** The plan is in the business plan, day by day. Days one to fifteen make the app sellable: Developer ID, notarization, licensing and a clean-Mac test. Then the landing page and waitlist, a demo video and Shorts, keys for creators, a private beta of 30 to 50 users, and launch on a Tuesday or Wednesday on Product Hunt and in the r/macapps App Pile thread. Affiliates are paid only on sales. Setapp is a second channel from month three. The targets on the bottom row are TBD; we will set them from the waitlist and beta numbers.
- **Screenshots:** none (data slide)

#### Slide 13: Traction and readiness

- **Layout:** `metrics_dashboard`
- **Header:** Built and tested. Launch numbers come next.
- **Subtitle:** Pre-revenue today. This is what is verified, and what we will report.
- **Body (exact):**
  - Full app compiles; every tab, tile and hotkey is wired
  - 50 real views rendered with sample data
  - Open: Browser Flows self-test not clean; live hardware checks pending
- **KPI tiles:** **29,283** widget checks, 0 failures · **195** clipboard and paste-stack checks, 0 failures · **63** OCR and screen-recorder checks, 0 failures · **48/48** UI Audit runner self-tests
- **Placeholder tiles:** [TBD: waitlist signups] · [TBD: beta users] · [TBD: trial starts] · [TBD: paid conversions] · [TBD: revenue]
- **Speaker notes:** We are pre-revenue and pre-launch, and I will not dress that up. What exists: the full app compiles with the Command Line Tools, every drawer tab, hub tile and default hotkey is wired, 50 views were rendered from the real code, and the automated harnesses pass, about 29,000 widget checks, 195 clipboard checks, 63 OCR and recorder checks and 48 of 48 UI Audit runner tests. What is still open: the Browser Flows self-test was not clean, and features that need a microphone, camera or system permission are on a live-check list before launch. The bottom row is what we will report to you monthly.
- **Screenshots:** none (data slide)
- **Footnote on slide:** "Internal checks run 22 Oct 2026 against current sources (feature guide, verification summary)."

#### Slide 14: Roadmap and risks

- **Layout:** `timeline`
- **Header:** Four known blockers, all scheduled.
- **Subtitle:** What stands between the build and the first sale, and what comes after.
- **Body (exact):**
  - Before sale: signing, licensing, the face model, Node.js
  - After launch: Setapp, packs, Team sync, reliability
- **Lane: Before the first sale:** **Developer ID + notarization** (Self-signed today; Developer ID cert, notarize and staple (days 1-3, 8-12)) · **Licensing, trial, paywall** (Not in the app yet; Lemon Squeezy License API; about 4-6 days of work) · **Face Unlock model** (ArcFace weights are non-commercial: Face Unlock is left out of 1.0) · **Node.js for dev tools** (List as a requirement, or bundle a signed Node (+40-100 MB))
- **Lane: After launch ([TBD: order and dates]):** **Setapp channel** (From month 3, once reviews exist) · **Feature packs** (e.g. a Meetings-only pack as a cheaper entry) · **Team: live Spaces sync** (Not built; today Spaces share as a file package) · **Browser Flows reliability** (Self-test must pass cleanly before it leaves beta) · **Commercial face model** ([TBD: licensed or replacement model])
- **Speaker notes:** Investors should hear the risks from us first. Four things block the first sale and all four are on the 30-day plan: proper Apple signing and notarization, licensing code, the face-recognition model's non-commercial license, which we solve by leaving Face Unlock out of 1.0, and the Node.js dependency of the developer tools. One more risk: SparkV uses private macOS paths for media and the HUD. Fallbacks already exist, and Sparkle lets us ship fixes fast. After launch, the order of Setapp, packs and Team sync is TBD and will follow what beta users ask for.
- **Screenshots:** none (data slide)

#### Slide 15: Team

- **Layout:** `minimal_body`
- **Header:** Team
- **Subtitle:** [TBD: one line on why this team wins]
- **Body (exact):**
  - [TBD: founder name] · [TBD: role] · [TBD: relevant prior work]
  - [TBD: co-founder or first hire] · [TBD: role]
  - [TBD: advisors]
  - Built at SparkV, a software studio in Telangana, India (sparkv.si)
- **Cards:** [TBD: founder name] / [TBD: role] / [TBD: one proof point] / [TBD: photo] · [TBD: co-founder / first hire] / [TBD: role] / [TBD] / [TBD: photo] · [TBD: advisor] / [TBD: role] / [TBD] / [TBD: photo]
- **Speaker notes:** [TBD: founder to write this in their own words: who built SparkV, what they shipped before, and why they will win the Mac power-user market.] The only fact from our files is the studio: SparkV is a software studio in Telangana, India, per sparkv.si.
- **Screenshots:** none (data slide)

#### Slide 16: The ask and use of funds

- **Layout:** `cta`
- **Header:** The ask
- **Subtitle:** Raising [TBD: amount] on [TBD: instrument and terms] for [TBD: months] of runway.
- **Body (exact):**
  - Milestone: [TBD: paid users or revenue] by [TBD: date]
  - Next step: a 20-minute live demo on your Mac
  - sparkv.si · [TBD: founder email]
- **Speaker notes:** We are raising [TBD: amount]. The money goes to four buckets, and the percentages are TBD: engineering to clear the launch blockers and harden the beta features, go to market for the launch video, creators and Product Hunt, legal for the EULA, privacy and the India DPDP rules, and support. The milestone we commit to is [TBD]. The best next step is a 20-minute demo on your own Mac.
- **Screenshots:**
  - `docs/screenshots/01-home.png`: cta_drawer, frame `notch_mockup`, at x 2490, y 1880, w 1068, h 246; scale 0.87x; Optional small device at bottom-right; drop it if the donut needs the room

**Chart C5: Use of funds** (`donut`, [TBD] values; draw equal dashed slices until the founder fills them). Placement: x 2400, y 560, w 1248, h 1248 px.

| bucket | percent | covers |
| --- | --- | --- |
| Product and engineering | [TBD: %] | licensing and trial, notarization pipeline, Sparkle, Browser Flows reliability, commercial face model |
| Go to market | [TBD: %] | demo video and Shorts, creator keys, launch, comparison pages |
| Legal and compliance | [TBD: %] | EULA, privacy, refunds, GDPR, India DPDP (notice duties from 13 May 2027), trademark review incl. the Clicky name |
| Support and operations | [TBD: %] | support, docs site, $99/yr Apple fee, hosting |

- Sources: SparkV Business Plan (docs/SparkV-Business-Plan.md), researched 22 Oct 2026

#### Slide A1 (hidden): Every feature

- **Layout:** `feature_showcase` (hidden backup)
- **Header:** Appendix: every feature, one hover
- **Subtitle:** Real renders from the current code with sample data.
- **Speaker notes:** Backup slide for questions about breadth. Every image is a real view rendered from the current source with sample data.
- **Screenshot grid (4 columns, tile 816 px wide, scale 816/1224 = 0.67):** `02-widgets.png`, `04-tray.png`, `06-today.png`, `07-converter.png`, `08-spaces.png`, `11-flow.png`, `13-clipboard.png`, `15-universal-search.png`, `28-focus.png`, `31-downloads.png`, `17-reply-drafter.png`, `23-job-agent.png`

#### Slide A2 (hidden): Sources

- **Layout:** `minimal_body` (hidden backup)
- **Header:** Appendix: sources
- **Subtitle:** Every number in this deck, and where it comes from.
- **Body (exact):**
  - See sources[] (rendered as a two-column list, 40 px, text_muted)
- **Speaker notes:** Leave this in the PDF version sent after the meeting.
- **Screenshots:** none (data slide)

---

## 2. Ultra-HD art direction

### 2.1 Global specs (all three styles)

| Spec | Value |
| --- | --- |
| Master | 3840 × 2160 px. Export PNG at 3840 wide and PDF from PPTX; Keynote at 3840 × 2160 when clips are embedded. |
| Safe area | 192 px left and right, 160 px top and bottom (content box 3456 × 1840). Footer band y 2016-2096: source line left, two-digit slide number right, both `source` size in `text_faint`. Slide 1 has no footer. |
| Grid | 12 columns of 240 px with 48 px gutters from x 192. Header zone y 160-480, subtitle y 480-560, content y 560-1960. |
| Type at 4K (pt in PPTX) | Display 176 px (44 pt), H1 144 px (36 pt), H2 104 px (26 pt), KPI 240 px (60 pt), subtitle 80 px (20 pt), body 72 px (18 pt), caption 48 px (12 pt), source 40 px (10 pt). Nothing smaller than 40 px. |
| Copy limits | Header ≤ 9 words on one or two lines, subtitle ≤ 18 words, ≤ 4 bullets of ≤ 12 words. Numbers use tabular figures. |
| Screenshot scale | Renders in `docs/screenshots` are 2× (the 1224 px drawer is 612 pt). Place at 1.0× where possible, never above 1.25×. Anything bigger uses a 4K still from §3 (`images[].final`). |
| Drawer and band renders | Always inside a `notch_mockup`. The mockup screen is filled with the renders' own wallpaper gradient `#2A2E43` (top) → `#171925` (bottom of the screenshot) → `#0F1119` (screen bottom), so the drawer has no seam in any style. Notch: pure `#000000`, top-centred on the screenshot, width 30% of the screenshot width, height 4.5% of it, bottom corners 24 px, with a 10 px camera dot (`#2B3448` → `#11141C`). If a bare drawer is needed without the mockup, crop to the bbox in `src_crop_px` and key out the navy surround (pixels with b − r between 11 and 28, b between 33 and 72, g ≥ r). |
| Window renders | Inside a `window` frame: 28 px corner radius, 1 px `line` outline, macOS traffic lights drawn at 24 px from the top-left (the renders have no title bar). No drop shadows in any style (the Apple style forbids shadows on slide content); in A and C put `glow` behind the window, never on top of it. |
| Charts | Flat 2D. Value labels on bars at caption size; axis labels `text_muted`; gridlines `line` at 50% or none. Derived values (the 2024 Mac bar) use a hatched or 60% fill. `[TBD]` values draw as dashed outlines with the label in `tbd`. One accent series per chart, always SparkV or the key number. Source line under every chart. |
| `[TBD]` chips | 2 px dashed outline in `tbd`, text in `tbd`, radius 16 px, padding 16 × 32 px. They must look deliberately unfinished, never like a design element. |
| Motion (Keynote or video export only) | Builds 400 ms, ease-out cubic-bezier(0.2, 0.8, 0.2, 1). Drawer reveal 520 ms from under the notch. Numbers count up over 800 ms on slides 2, 6, 11 and 13. No bounces or spins. |
| Accessibility | Body text contrast ≥ 7:1 on `bg`, captions ≥ 4.5:1. Never put text on a screenshot. Red is never the only signal (pair it with position, weight or a label). |

### 2.2 Tokens

Values are taken from the three approved style demos in `docs/decks/style-demos/` (`sparkv-red-black/index.html`, `apple-minimal/STYLE.md`, `dark-cyberpunk/index.html`). Style A also matches the live sparkv.si stylesheet read on 22 Oct 2026 (`--red #f01822`, `--red-on-dark #f8262f`, background `#080809`/`#09090a`, surface `#101012`/`#111113`, border `#29292f`, muted `#8e8e95`, green `#57d791`, system sans and mono stacks).

| Token | A: sparkv.si red/black | B: Apple minimal | C: Dark cyberpunk |
| --- | --- | --- | --- |
| `bg` | #09090A | #FFFFFF | #000000 |
| `bg_hero` | #050506 | #F5F5F7 | #000000 |
| `bg_elev` | #111113 | #F5F5F7 | #0A0A0C |
| `bg_elev_2` | #17171A | #E8E8ED | #111114 |
| `line` | #FFFFFF1A | #D2D2D7 | #26262B |
| `line_strong` | #FFFFFF26 | #1D1D1F | #3A3A41 |
| `text` | #F7F7F5 | #1D1D1F | #F2F2F4 |
| `text_muted` | #A0A0A3 | #6E6E73 | #A1A1AA |
| `text_faint` | #808088 | #86868B | #6B6B74 |
| `accent` | #F01822 | #F01822 | #FF1E2D |
| `accent_text` | #F8262F | #F01822 | #FF1E2D |
| `accent_soft` | #FF8A90 | #F01822 | #8A0F18 |
| `accent_ink` | #FFFFFF | #FFFFFF | #000000 |
| `glow` | radial rgba(240,24,34,0.16) r=1400px under the notch | none (no shadows on slide content; depth only from the device mockup) | rgba(255,30,45,0.45) neon bloom + rgba(0,229,255,0.28) chromatic offset 2 px |
| `ok` | #57D791 | #1D8E3E | #39FF88 |
| `tbd` | #9A9AA1 | #86868B | #6B6B74 |
| `bar_neutral` | #3A3A3F | #AEAEB2 | #26262B |
| `chart` | #F01822, #F7F7F5, #808088, #3A3A3F, #57D791 | #F01822, #1D1D1F, #AEAEB2, #E8E8ED, #1D8E3E | #FF1E2D, #00E5FF, #A1A1AA, #3A3A41, #39FF88 |
| `font_display` | SF Pro Display | SF Pro Display Light | Chakra Petch |
| `font_body` | SF Pro Text | SF Pro Text | Inter |
| `font_mono` | SF Mono | SF Mono | JetBrains Mono |
| `font_fallback` | Inter | Inter | Arial Narrow |

Note: the customer blueprint uses a blue accent for style B and a magenta/cyan accent for style C. This deck follows the approved style demos instead, where B keeps SparkV red under 10% of the slide and C uses neon red with a cyan offset. If the team settles on one convention, change only the `styles` block in `outline.json`.

### 2.3 Where the three styles differ

- **A: sparkv.si red/black.** Every slide black (`bg`), hero slides 1, 3 and 16 on `bg_hero`. Exactly one red element per slide: the key number, the SparkV bar or row, the Pro card or the CTA. Thin `line` hairlines separate sections. The glow is red and low, as if lit from under the notch. Headers use system sans Bold, with the one key phrase in `accent_text`.
- **B: Apple minimal.** Text and data slides (2, 7, 8, 9, 10, 11, 12, 13, 14, 15, A2) are white or `#F5F5F7`. Product slides (1, 3, 4, 5, 6, 16, A1) are `#F5F5F7` with the dark device or window as the only dark mass, because every render is dark. No glows and no shadows on slide content; depth comes only from the device. Headlines in SF Pro Display Light with a Semibold emphasis run (or Inter Light/SemiBold off a Mac). Red stays under 10% of the slide: only the eyebrow, the SparkV value, the Pro outline and the CTA. Cut bullets to three where a slide has four (drop the last).
- **C: Dark cyberpunk.** Pure black, a faint 64 px grid on hero slides, and a 4% scanline texture allowed on backgrounds only (never on screenshots or text). Neon red `#FF1E2D` for the key element with a 2 px cyan (`#00E5FF` at 28%) chromatic offset on headers only. Headers in Chakra Petch, body in Inter, every number and hotkey in JetBrains Mono inside 2 px outline chips. Device rim: 2 px neon red at 40%. Keep glows outside text boxes.

### 2.4 Per-slide art direction

All coordinates are master px (x, y, w, h). Token names refer to 2.2.

**Slide 1, key visual header.** `bg_hero`. Text block centred on 12 columns: eyebrow "SparkV for macOS" (caption, `accent_text`) at y 240, header in Display over two lines at y 320-700 (the phrase "AI command center" in `accent_text` for A and C; Semibold emphasis run for B), subtitle at y 740-840 in `text_muted`. "Seed round · [TBD: month and year]" as a `[TBD]` chip and "sparkv.si" as plain caption at y 900. Device: `notch_mockup` screen 1011, 1100, 1818, 1180 bleeding off the bottom edge; drawer at 1155, 1100, 1530, 352 (1.25×; prefer the I01 4K still). `glow` centred at (1920, 1300). A: red bloom 16%. B: no glow, mist background, the device does the work. C: grid background, neon rim on the device, cyan offset on the header.

**Slide 2, metrics dashboard.** `bg`. Chart C1 (horizontal bars) at 192, 600, 2112, 1300: five competitor bars in `bar_neutral`, the "Five apps total" bar in `text`, the "SparkV Pro" bar in `accent`, value labels at bar ends. A thin rule above "Five apps total". Three KPI tiles stacked on the right (2496, 600 / 1050 / 1500, each 1152 × 400): value in KPI size, label in caption; only "$39" in `accent`. Footnote at y 2016. B: tiles are `bg_elev` cards with no outline; C: values in JetBrains Mono, the SparkV bar with neon bloom.

**Slide 3, feature showcase.** `bg_hero`. Copy on columns 1-6 (192-1824): header H1, subtitle, four bullets, each starting with its group name in `text` and the rest in `text_muted`. Device on the right: screen 1968, 560, 1680, 1100; hub render at 2043, 560, 1530, 570 (1.25×; prefer the I02 still). The Home render as a 1.0× card (2196, 1220) overlapping the device bottom by 80 px for depth (A and C only; B drops it for space). One callout: a 4 px `accent` ring around the agents-hub header button (render position ≈ (959, 40), on the slide ≈ (3242, 610)).

**Slide 4, feature showcase (demo).** `bg`. Bullets on columns 1-5 (192-1248) with each hotkey (fn, ⌃⌥, ⌥Space) in a mono chip before the sentence. Media box 1344, 560, 2304, 1296: the I03 film when presenting in Keynote; in PPTX/PDF a 2 × 2 fallback grid (dictation band, answer band, meeting notes, search panel), 32 px gaps, each inside its own frame. A "LIVE" pill (caption size, `accent` fill, `accent_ink` text) at the media box's top-left. B: the media box sits on `#F5F5F7` with no outline; C: the box has a 2 px neon red corner-bracket frame instead of a full outline.

**Slide 5, feature showcase.** `bg`. Copy on columns 1-5; the Live Translation caption render (38) as a 1.0× card under the bullets at 192, 1480, 1280, 400. Meeting notes window (36) at 1660, 560 at 1.0× in a `window` frame; build step 2 crossfades to the Answers view (37) in the same box. Callout: an `accent` 4 px left bar beside the "tasks" panel. In Keynote, replace the window with clip I04 at 1632, 560, 2016, 1134.

**Slide 6, metrics dashboard (proof).** `bg`. Four KPI tiles in a 2 × 2 grid on the left (192/936 × 600/1220, each 696 × 560); "3 · 15" in `accent`, the others in `text`. UI Audit window render (22) at 1728, 560, 1920, 1280 (0.89×) in a `window` frame. Three body lines as small caption rows under the tiles at y 1820-1960. Footnote "Internal test, 22 Oct 2026…" at y 2016 must stay visible: it is what makes the slide honest. C: severity dots in the render already use red/orange/yellow/blue; keep the slide accent to the one tile so it does not compete.

**Slide 7, timeline.** `bg`. A horizontal rail at y 1100 (2 px `line`) from x 384 to 3456, five nodes at x 384, 1152, 1920, 2688, 3456. Node: 24 px circle in `text_muted`; the "Jun 2025" node (on-device models) is 40 px in `accent` as the focal point; the "Next" node is a dashed `tbd` circle. Date above each node in mono caption; event text below (caption, max 3 lines, 640 px wide). Three body lines as a row of three cards at y 1500-1900 (each 1088 wide), the first ("$0") with the number in `accent`. Source references as superscript numbers matching the A2 list.

**Slide 8, metrics dashboard (market).** `bg`. Four KPI tiles 2 × 2 on columns 1-7 (192/1032 × 600/1280, each 792 × 620); "25.6M" in `accent`. Chart C2 (two columns) at 2016, 600, 1632, 760: the 2025 bar in `accent`, the 2024 bar hatched or at 60% fill with "derived" under its label; annotations as caption text above the bars. Funnel table T8 at 2016, 1420, 1632, 480, with TAM, SAM and SOM rows; `[TBD]` cells as chips. Source line at y 2016.

**Slide 9, two-column comparison.** `bg`. Matrix T9 at 192, 560, 2496, 1280: first column 640 px for job names, nine product columns of about 206 px; the SparkV column filled `bg_elev` with a 4 px `accent` top bar; ● glyphs 48 px; ◐ for SparkV search; the price row in caption size with a hairline above. Positioning map P9 at 2832, 560, 816, 816: axes in `line`, axis titles in caption `text_muted`, dots 24 px in `text_muted`, the SparkV dot 40 px in `accent` with its label in `text`. The three body lines as a stacked list under the map (2832, 1440). Legend and sources at y 1900-2016. B: no column fill, only the red top bar; C: SparkV column with neon outline, other dots cyan.

**Slide 10, pricing table.** `bg`. Three plan cards (Free 192, Pro 1376, Team 2560; each 1088 wide). Pro is raised 40 px and 80 px taller, with a 4 px `accent` outline and a "Recommended" pill. Price in KPI size; INR on its own line in caption `text_muted`; "launch week $29" as an `accent_text` caption. Four lines per card with check glyphs. Footer strip at y 1840: the trial, student, refund and packs line in caption. B: cards white on `#F5F5F7` with a hairline; only Pro has red. C: price in JetBrains Mono, the Pro card with neon rim.

**Slide 11, metrics dashboard (unit economics).** `bg`. Waterfall C3 at 192, 560, 2016, 1000: the "List price" and "Net to SparkV" totals in `text` and `accent`, deductions in `bar_neutral`, the "AI inference $0" step drawn as a labelled zero-height marker with a short `accent` tick (it is the point of the slide). Table T11 under it (192, 1620, 2016, 400). Right: two KPI tiles (2400 and 3048, y 560, 600 × 440) and C4 (2400, 1060, 1248, 900) with the title "Illustrative only" in `tbd` colour and a dashed frame, so nobody reads it as a forecast.

**Slide 12, timeline (go to market).** `bg`. Rail at y 900 with 10 nodes from x 288 to 3552 (day ranges above, tasks below in caption, 300 px wide). Day 27 (launch) is the focal node in `accent`. Channel chips (outline, `text`) in one row at y 1400; target chips (`[TBD]` style) in one row at y 1720. B: no rail colour, nodes as thin rings; C: rail as a neon gradient line.

**Slide 13, metrics dashboard (readiness).** `bg`. Row 1: four verified tiles (192, 1072, 1952, 2832; y 600; 816 × 520), each with a small `ok` check glyph; numbers in `text` (no red: they are internal checks). Row 2: five `[TBD]` chips (each 640 × 300, y 1260). The three body lines at y 1660-1900, the "Open:" line in `text_muted` with a small warning glyph. Footnote at y 2016.

**Slide 14, timeline (two lanes).** `bg`. Lane 1 "Before the first sale" at y 640-1240: four cards, each with an index number and a status chip ("scheduled", days from the 30-day plan). Lane 2 "After launch" at y 1340-1900: five lighter cards with dashed outlines (order `[TBD]`). Lane labels as vertical captions on the left margin. No red except the lane-1 index numbers.

**Slide 15, minimal body.** `bg`. Three cards (192, 1376, 2560; y 700; 1088 × 1100): photo slot 480 × 480 as a dashed circle with "[TBD: photo]", name, role and proof point as `[TBD]` chips. Studio line ("Built at SparkV…") centred at y 1880 in caption `text_muted`. Do not use stock photos or silhouettes that look like real people.

**Slide 16, CTA.** `bg_hero`. Left (columns 1-8): header Display, subtitle with three `[TBD]` chips inline, three body lines; "sparkv.si" as an `accent` pill button (1056 × 160) at y 1640 with "[TBD: founder email]" chip beside it. Right: donut C5 at 2400, 560, 1248, 1248 with four equal dashed slices labelled "[TBD: %]" and bucket names outside. Optional small device (0.87× Home render) bottom-right at 2490, 1880; drop it if crowded. A: red bloom behind the button; B: no glow; C: neon button with cyan offset.

**A1, feature grid (hidden).** `bg`. Four columns of mini notch mockups (816 px wide renders at 0.67×) in three rows, 64 px gaps, captions under each (feature name, caption size). **A2, sources (hidden).** Two-column list at source size in `text_muted`, ID in mono.

---

## 3. 4K screen-recording and screenshot scripts

### 3.1 Rig and coordinate system (shared with the customer deck)

- **Machine:** MacBook Pro 16-inch with notch, Apple silicon, macOS 15 or later, built-in display only, at the default scaled size 1728 × 1117 pt (3456 × 2234 px; panel resolution per the Oct 2021 MacBook Pro launch coverage).
- **Capture:** a ScreenCaptureKit recorder (for example OBS Studio's macOS Screen Capture source, or the macOS ⌘⇧5 recorder for simple takes) on the built-in display at native 3456 × 2234 px, 60 fps, ProRes 422 HQ or HEVC 10-bit at 80 Mbps or more. Capture the cursor on its own layer if the tool supports it. System audio off except where stated; voice-over recorded separately. Do not use SparkV's own recorder (⌃⌥⇧R) to film SparkV: its red band would appear in the shot.
- **Edit canvas: 3840 × 2160, 60p.** Place the capture at 111.11% (3840 × 2482), top-aligned, so the notch is at top centre and the bottom 322 px (Dock area) fall off. **All coordinates in this section are canvas px.** canvas_px = points × 2.2222 = render_px (from `docs/screenshots`) × 1.1111. On a 14-inch MacBook Pro (3024 × 1964 px) use 126.98% and canvas_px = points × 2.5397, then recompute.
- **Reference positions** (derived from the renders; check the first frame of every clip and shift all values by the same offset if they differ):
  - Notch centre x 1920; drawer top y 0; drawer body about x 1289-2547.
  - Drawer bottom: Home-size pages about y 253; Widgets-size about y 383; agents hub about y 447.
  - Header icons (y 41): Home 1381, Widgets 1440, Tray 1498, Today 1556, Converter 1613, Spaces 1671 · Focus 2190, Record 2248, Agents hub 2306, Flow 2363, Screen assistant 2421, Gear 2468.
  - Hub tile centres: columns x 1420, 1563, 1706, 1849, 1991, 2133, 2277, 2419; rows y 139, 264, 383. Row 1: Search, Focus, Modes, Capture, Copy Text, Reply, Ask Screen, Prompt. Row 2: Clipboard, Paste Stack, Record, Widgets, File Drop, Downloads, Translate, UI Audit. Row 3: Jobs, Browser, Distance, Canvas, Setup, C.
  - Meeting notes window (2178 × 1467, centred): top-left (831, 550); tabs Notes (1653, 779), Transcript (1864, 779), Answers (2073, 779).
  - UI Audit window (2400 × 1600, centred): top-left (720, 483); URL field (1380, 590), "Full frontend" (2731, 590), Start (2976, 590), status line (1068, 802), Summarize (2472, 1997), Open report (2760, 1997), P button (3052, 1997).
  - TextEdit demo window: 1600 × 900 canvas px, top-left (1120, 700). Preview demo window: 2000 × 1200, top-left (920, 560). File menu title in Preview's menu bar about (300, 41): verify.
- **Crop rectangles (canvas px):**

| Name | x | y | w | h | Use |
| --- | --- | --- | --- | --- | --- |
| R-FULL | 0 | 0 | 3840 | 2160 | Full frame, windows, pointer flights |
| R-MID | 640 | 0 | 2560 | 1440 | Notch plus the top of a centred window; 1.5× zoom in a full-screen film |
| R-TOP-16x9 | 960 | 0 | 1920 | 1080 | Notch close-up; 2× zoom, only inside a slide box (see the scale rule) |
| R-DRAWER-HOME | 1260 | 0 | 1320 | 300 | Home, Today, Flow and other Home-size pages |
| R-DRAWER-MID | 1260 | 0 | 1320 | 430 | Widgets, Tray, Converter, Search page |
| R-DRAWER-HUB | 1260 | 0 | 1320 | 500 | Agents hub |
| R-BAND | 1260 | 0 | 1320 | 240 | Closed-island bands (dictation, answer, live activities) |
| R-WINDOW-C | window x − 60 | window y − 60 | window w + 120 | window h + 120 | Any centred window |

- **Scale rule for clips in this deck:** the film plays inside slide boxes about 0.5-0.6× of the master (2304 or 2016 px wide), so a 2× zoom (R-TOP-16x9) shows at about 1.2× of native pixels on the slide, which is acceptable. For a full-screen web version of the same film, limit zooms to R-MID (1.5×).
- **Output names:** clips `docs/decks/investor/media/rec/I0n-name.mov`; stills `docs/decks/investor/media/stills/I0n-name-SSSS.png` (SSSS = the timecode as mmss, e.g. 0008 = 00:08, 0114 = 01:14) and crops `…-SSSS-R-NAME.png`. Nothing in `media/` exists yet; these are the names `outline.json` expects in `images[].final`. Where a customer-deck clip covers the same beat, reuse it and note the source file.

### 3.2 Demo environment and sample data (prepare once)

1. **A fresh macOS user, "SparkV Demo"**: no personal mail, contacts, photos or notifications. Dark appearance. Wallpaper: solid `#09090A` for styles A and C, solid `#1D1D1F` for B. Desktop icons hidden (Finder settings). Menu bar shows only the clock; note the time as `[demo time]` on stills.
2. **SparkV build:** the notarized release candidate once it exists (nothing is built for this task). Every permission granted in Setup beforehand so no prompt appears on camera. **Groq off everywhere**: no key in the screen assistant, gear › Meetings › "Allow Meeting Notes to Use My Groq Key" off, Flow Canvas Groq off. Gear › Live Activities › "Hide Message Text" on (except the notification still in I06).
3. **Dictation:** gear › Dictation › Hold to Talk key = fn, AI Formatting on. Flow › Words: add "SparkV".
4. **Meetings:** gear › Meetings › "Suggest Answers to Questions" on. Live Translation on (Agents hub › Translate), reading language English, caption window at the bottom centre.
5. **Calendar:** a local "Demo" calendar with "Investor sync (demo)" starting 6 minutes after recording begins, with a meeting link on a call service you control; "Design review" at [demo time + 2 h]; "1:1" at [demo time + 4 h].
6. **Spaces:** "Helm Launch", "Acme Client", "Personal". Pre-file about 20 items by using the features off camera, and include these items **with corrected sample data** so search results agree with slide 10: web page "Launch checklist: Beta [demo date], GA [demo date]. Owners: [Presenter] (API), Priya (design)"; meeting "Pricing call notes: Free, Pro $39 once, Team $8 per seat per month"; Flow note "Launch ideas: notch demo video, founder AMA, pricing page test"; dictation "Let's move the launch review to Thursday at 3."
7. **Clipboard:** turn history on (Clipboard page › Turn On), then copy 8 items: a URL, the colour `#F01822`, `demo@example.com`, a code snippet, an image.
8. **Files in `~/SparkV-Demo/`:** `Pitch-Notes.pdf` (3 pages, own content), `hero-v2.png` (own artwork, opened in Preview for the screen-assistant beat), `Project-Notes.docx`.
9. **Music:** a track you hold the rights to, with your own artwork, `[TBD: licensed demo track]`. The renders show a commercial track title; do not show or play commercial music in investor media. Record with audio muted.
10. **Meeting partner:** a colleague on a second Mac, consenting, voice only. Script: (a) two Spanish sentences, "Hola a todos. Hoy revisamos el plan de lanzamiento y los precios."; (b) "[Presenter], what's the status of the API migration?"; (c) "Let's use Lemon Squeezy for checkout and launch on a Tuesday." Record a full 2-3 minute version off camera first, so the notes window has rich content for the cut-away.
11. **UI Audit target:** the bundled planted-issue test site from `Vendor/ui-audit/test`, served on 127.0.0.1 `[TBD: port and start command, see Vendor/ui-audit/test]`. Node 20+ at `/opt/homebrew/bin/node`; Playwright Chromium installed (`npx playwright-core install chromium`). Never point UI Audit at a site you do not own.
12. **Post-production overlays:** keystroke HUD bottom-centre at y 1960 (mono chips, caption size, `bg_elev` fill) showing each hotkey as it is pressed; cursor scaled 1.5× with a 60 px `accent` halo on clicks; a "time-lapse" label whenever footage is sped up; "Groq off · on-device" tag top-right in the demo film.

Cursor rules for every clip: steady 900-1200 px/s with ease-in-out, 0.5 s pause before every click, park the cursor outside the drawer (y > 1000) when not interacting, and never hover the notch by accident during a transition.

### 3.3 Clip scripts

#### I01 Hero hover (slides 1 and 16; same as customer clip C01)

- **Window and drawer state:** empty desktop, drawer closed, compact wings showing the licensed demo track's artwork, Home was the last tab.
- **Sample data:** licensed track playing (muted).

| Time | Shot | Action | Cursor path (canvas px) | Crop | Deck overlay |
| --- | --- | --- | --- | --- | --- |
| 00:00-00:02 | Closed island with now-playing wings | none | parked at (1920, 1300) | R-TOP-16x9 | Slide 1 loop start |
| 00:02-00:04 | Drawer opens on Home | hover the notch | (1920, 1300) → (1920, 30), arrives 00:03 | R-TOP-16x9 | |
| 00:04-00:06 | Hold on Home; scrubber moves | none | rest at (1920, 160) | R-DRAWER-HOME (still I01-hero-0005) | Still → slide 1 drawer slot (1155, 1100, 1530 wide) |
| 00:06-00:08 | Drawer closes, wings return | move away | (1920, 160) → (1920, 1300); drawer closes about 0.5 s after leaving | R-TOP-16x9 | Loop point = frame 00:00 |
| 00:08-00:20 | Optional: play/pause and volume knob | click play/pause (1588, 174) twice; scroll up 3 notches on the knob (1851, 161) | as stated | R-DRAWER-HOME | Slide 16 small device (still at 00:12) |

#### I02 Drawer tour and agents hub (slide 3)

- **State:** drawer closed; pages pre-filled (Tray has a PNG, a PDF and a link; Today shows the demo meetings; Converter has `Pitch-Notes.pdf` dropped; Spaces shows three Spaces).

| Time | Shot | Action | Cursor path | Crop | Deck overlay |
| --- | --- | --- | --- | --- | --- |
| 00:00-00:02 | Drawer opens on Home | hover notch | (1920, 1300) → (1920, 30) → (1381, 41) | R-MID | Slide 3 media box (1968, 560, 1680 × 945) in Keynote |
| 00:02-00:04 | Widgets | click Widgets | → (1440, 41) | R-MID | |
| 00:04-00:06 | Tray | click Tray | → (1498, 41) | R-MID | |
| 00:06-00:08 | Today | click Today | → (1556, 41) | R-MID | |
| 00:08-00:10 | Converter | click Converter | → (1613, 41) | R-MID | |
| 00:10-00:12 | Spaces | click Spaces | → (1671, 41) | R-MID | |
| 00:12-00:16 | Agents hub opens (tallest drawer) | click Agents hub | → (2306, 41) | R-DRAWER-HUB (still I02-tour-0014) | Still → slide 3 hero (2043, 560, 1530 wide) |
| 00:16-00:20 | Sweep row 1 then row 2; tooltips show hotkeys | hover 0.4 s on Search, Reply, Ask Screen, UI Audit | (1420, 139) → (2419, 139) → (2419, 264) → (1420, 264) | R-MID | |
| 00:20-00:24 | Drawer closes | move away | → (1920, 1300) | R-MID | |

#### I03 Master demo film (slide 4; the backup for the live demo)

- **State:** TextEdit demo window open and empty (1120, 700, 1600 × 900), 20 pt font; Preview window with `hero-v2.png` behind it; Universal Search index populated (§3.2 item 6); meeting partner connected and muted until 00:38. Drawer closed. Overlay "Groq off · on-device" for the whole film.
- **Spoken dictation line:** "Um, so let's move the launch review to Thursday at three. We need the pricing page, the demo video and the beta invites."

| Time | Shot | Action | Cursor path | Crop | Deck overlay |
| --- | --- | --- | --- | --- | --- |
| 00:00-00:04 | Establish: closed island, empty TextEdit | none | parked (1920, 1300) | R-FULL | Slide 4 box (1344, 560, 2304 × 1296) |
| 00:04-00:08 | Drawer opens on Home, then closes | hover notch, leave | (1920, 1300) → (1920, 30) → (1920, 1150) | R-MID | |
| 00:08-00:12 | Click into TextEdit; press and hold fn; dictation band appears | click, hold fn at 00:09 | rest at (1920, 1150) | R-TOP-16x9 | Keystroke HUD "hold fn" |
| 00:12-00:18 | Speak the line; band shows live level | keep holding fn | static | R-TOP-16x9 (still at 00:14 → R-BAND for slide 4 fallback 1) | |
| 00:18-00:24 | Release fn; cleaned text appears as a list, no "um" | release fn | static | R-MID | If the filler words are not removed, cut the "clean text" claim |
| 00:24-00:28 | Switch to Preview; hold ⌃⌥ and ask "Where do I change the export format?" | ⌘-Tab to Preview, hold ⌃⌥ from 00:25 | park at (1900, 1100) | R-MID | HUD "hold ⌃⌥" |
| 00:28-00:34 | Release; answer band under the notch; the pointer flies to the File menu | release ⌃⌥ at 00:28 | (SparkV's pointer, not the cursor) → about (300, 41) | R-FULL (still at 00:31 → R-BAND for fallback 2) | Record system audio for this beat only (spoken answer) |
| 00:34-00:38 | Start a meeting from the header | hover notch, click Record | (1900, 1100) → (1920, 30) → (2248, 41) → (1920, 1300) | R-TOP-16x9 | |
| 00:38-00:46 | Partner asks script line (b); suggested answer appears under the notch | none | parked | R-TOP-16x9 | Subtitle the partner's question in post |
| 00:46-00:50 | Stop recording | hover notch, click Record | → (1920, 30) → (2248, 41) | R-TOP-16x9 | Cut-away card "2-minute meeting, shortened" |
| 00:50-00:58 | Meeting notes window: tasks, minutes, decisions; then Answers tab | click Answers | → (2073, 779) at 00:55 | R-FULL (still at 00:52 → fallback 3) | Uses the off-camera full meeting from §3.2 item 10 |
| 00:58-01:02 | Universal Search | press ⌥Space, type "launch" (about 8 characters/s) | parked (1920, 1300) | R-FULL | HUD "⌥Space" |
| 01:02-01:10 | Results grouped by source; press Tab for Ask; cited answer streams | press Tab | static | R-FULL (still at 01:06; the clean version is I06-search) | Check the pricing row shows the corrected sample data |
| 01:10-01:14 | Esc; open the agents hub | Esc, hover notch, click hub | → (1920, 30) → (2306, 41) | R-TOP-16x9 | |
| 01:14-01:22 | Sweep all three rows | hover only | (1420, 139) → (2419, 139) → (2419, 264) → (1420, 264) → (1420, 383) → (2133, 383) | R-MID | |
| 01:22-01:26 | Drawer closes; closed island | move away | → (1920, 1300) | R-TOP-16x9 | |
| 01:26-01:30 | End card | none | hidden | R-FULL + overlay | "SparkV · sparkv.si" in style tokens |

#### I04 Meetings, live answers and translation (slide 5)

- **State:** Today page shows "Investor sync (demo)" starting in 6 minutes; Live Translation on; Suggest Answers on; Groq off; caption window bottom-centre.

| Time | Shot | Action | Cursor path | Crop | Deck overlay |
| --- | --- | --- | --- | --- | --- |
| 00:00-00:04 | Heads-up under the closed notch ("in 6 min", Join) | none | parked (1920, 1300) | R-TOP-16x9 | Slide 5 box (1632, 560, 2016 × 1134) in Keynote |
| 00:04-00:08 | Today opens; click the meeting's Notes button (position: verify on the first frame) | hover heads-up, click Notes | (1920, 1300) → (1920, 120) → [Notes button] | R-MID | |
| 00:08-00:14 | Partner speaks the Spanish lines; English captions with the original underneath | none | parked | R-FULL (still at 00:12 → replaces render 38) | Caption card on slide 5 (192, 1480) |
| 00:14-00:20 | Partner asks the API question; suggested answer under the notch | none | parked | R-TOP-16x9 | |
| 00:20-00:22 | Stop | hover notch, click Record | → (1920, 30) → (2248, 41) | R-TOP-16x9 | |
| 00:22-00:30 | Notes window: Notes tab (tasks, decisions), then Answers | click Answers at 00:27 | → (2073, 779) | R-FULL (stills at 00:24 → replaces 36; 00:29 → replaces 37) | Slide 5 window slot (1660, 560) |

#### I05 UI Audit run (slide 6)

- **State:** planted-issue test site running on 127.0.0.1; UI Audit window centred (720, 483); Max pages 6, Depth 3, "Allow form submission" and "Allow risky clicks" both off (the window still fills forms on local test hosts, as the render's status line says); Chromium window placed on the right half when it opens.

| Time | Shot | Action | Cursor path | Crop | Deck overlay |
| --- | --- | --- | --- | --- | --- |
| 00:00-00:04 | Agents hub › UI Audit tile; drawer page shows | hover notch, click hub, click tile | (1920, 30) → (2306, 41) → (2419, 264) | R-MID | Slide 6 window slot (1728, 640, 1920 × 1080) in Keynote |
| 00:04-00:08 | Open the full window (gear › Agents › UI Audit…), type the URL | click gear, menu item, then URL field; type `http://127.0.0.1:[port]` | → (2468, 41) → menu → (1380, 590) | R-FULL | |
| 00:08-00:10 | Choose Full frontend; Start | click | → (2731, 590) → (2976, 590) | R-FULL | |
| 00:10-00:18 | Crawl: live log streams, findings appear by severity (time-lapse 6-10×) | none | parked off-window | R-FULL | "Time-lapse" label |
| 00:18-00:22 | Done line: pages and findings counts | none | → (1068, 802) hover | R-WINDOW-C (still at 00:20 → replaces render 22) | If the counts differ from 6 / 69 / 3 / 15, update slide 6 to what the take shows |
| 00:22-00:26 | Summarize: on-device summary appears | click Summarize | → (2472, 1997) | R-FULL | "On-device (Apple Intelligence)" label must be readable |
| 00:26-00:30 | P: fix prompt copied | click P | → (3052, 1997) | R-FULL | Optional 2 s paste into an editor to show the prompt's first lines |

#### I06 4K still set (slides 1, 3, 4 and A1)

Take each still with the clip state above, export a PNG frame at 3840 × 2160, then crop. Save as `media/stills/I06-<name>.png` (no timecode).

| Still | Setup and action | Crop | Replaces | Used on |
| --- | --- | --- | --- | --- |
| I06-home | Drawer open on Home with the licensed track and its artwork | R-DRAWER-HOME | 01-home.png | 1, 3, 16 |
| I06-hub | Agents hub open, no hover | R-DRAWER-HUB | 10-agents-hub.png | 3 |
| I06-search | ⌥Space, "launch", corrected sample data, Ask answer visible | R-WINDOW-C on the panel | 16-universal-search-panel.png | 4 |
| I06-bands | Volume key ×3 (volume HUD), plug in charger (battery), AirPods connected (AirPods band), a message from a second demo account (notification, Hide Message Text off for this still only) | R-BAND each | 42, 43, 44, 45 | A1, backup |
| I06-wings | Closed island with timer and now playing in the wings | R-BAND | 46-compact-wings.png (clipped render) | backup |
| I06-grid | One still per A1 page (Widgets, Tray, Today, Converter, Spaces, Flow, Clipboard, Search page, Focus, Downloads, Reply, Jobs) | R-DRAWER-HOME or R-DRAWER-MID | the A1 renders | A1 |

### 3.4 Still and clip checklist

1. Frame exported at 3840 × 2160, sRGB PNG; crops saved as separate files, never cropped inside the slide.
2. No personal data, real third-party names or faces, commercial music or artwork, or permission prompts. The clock reads `[demo time]`.
3. The footage shows exactly what the slide claims. A "Needs a live check" feature that misbehaved is cut from the slide, not re-staged.
4. Sample data agrees with the deck (pricing $39 / $8, not the $9 / $19 in the old search render).
5. Update `images[].final` in `outline.json` with the delivered path, and the slide's `claims[].status` to "verified live, <date>".

---

## 4. Generator notes (`outline.json`)

- `deck` holds canvas, safe area, directories and the rules (`placeholder_rule`, `image_rule`, `max_screenshot_upscale` 1.25). EMU = px × 3175; `box_in` = px / 288 is given alongside every `placement_px`.
- `styles` has three token sets (`sparkv_red`, `apple_minimal`, `cyberpunk`) with the same keys; the generator picks one with `--style`.
- `slides[]`: `n`, `id`, `layout` (one of the eight `layouts` keys), `header`, `subtitle`, `body[]`, `notes`, `images[]` (`file` from `screenshots_dir`, `role`, `placement_px`, `box_in`, `mockup`: `notch_mockup`, `window`, `band`, `card` or `none`; optional `src_crop_px`, `scale`, `final`, `screen_px`, `notch_px`, `build`, `warning`), `video` (Keynote only), `chart`, optional `chart_2`, `table`, `kpi_tiles[]`, `tbd_tiles[]`, `timeline[]`, `lanes[]`, `channels[]`, `kpi_placeholders[]`, `cards[]`, `grid`, `claims[]`, `source_line`, `hidden`.
- `chart` types: `bar_horizontal` (C1), `column_clustered` (C2, C4), `waterfall` (C3, with `total_indices`), `scatter_2x2` (P9, qualitative), `donut` (C5, `values` all null with `placeholder_equal_split`). Every chart carries `data_table`, `source_ids` and a `label` that says whether it is sourced, derived, illustrative or `[TBD]`. python-pptx has no native waterfall: build C3 as a stacked column with an invisible base series.
- `table` with `type: plan_cards` is the pricing slide; other tables have `columns`, `rows` and optional `highlight_column` and `legend`.
- Hidden slides (`"hidden": true`): set `show="0"` on the slide element.
- `recordings[]` lists clips I01-I06 and which slides use them.

---

## 5. Open placeholders

| Placeholder | Slide | Who fills it, and from what |
| --- | --- | --- |
| [TBD: month and year] | 1 | Founder, at send time |
| [TBD: Apple-silicon MacBooks with a notch on macOS 15+], [TBD: count], [TBD: method] | 8 | A sourced public estimate (method in the slide 8 note), or leave visible |
| [TBD: year-3 paid users target] | 8 | Founder's plan, after beta conversion data |
| [TBD: refund rate] | 11 | Lemon Squeezy data after launch |
| [TBD: revenue plan] | 11 | Founder's model; the C4 chart stays labelled illustrative |
| [TBD: waitlist target], [TBD: trial-to-paid target], [TBD: CAC by channel], [TBD: creator reach] | 12 | Founder, from the waitlist and beta |
| [TBD: waitlist signups], [TBD: beta users], [TBD: trial starts], [TBD: paid conversions], [TBD: revenue] | 13 | Real numbers only, after days 16-30 of the launch plan |
| [TBD: order and dates], [TBD: licensed or replacement model], [TBD: launch date] | 14, 7 | Founder, after the beta |
| All team fields | 15 | Founder |
| [TBD: amount], [TBD: instrument and terms], [TBD: months], [TBD: paid users or revenue] by [TBD: date], [TBD: %] ×4, [TBD: founder email] | 16 | Founder and counsel |
| [TBD: licensed demo track] | I01, I06 | Music you hold rights to |
| [TBD: port and start command] | I05 | `Vendor/ui-audit/test` |
| [demo time], [demo date], [Presenter] | all clips | The person recording |
| Final name of the screen assistant | notes on 4 | Product decision (business plan §7) |

---

## 6. Sources

| ID | Source | Used for |
| --- | --- | --- |
| `bp` | SparkV Business Plan (docs/SparkV-Business-Plan.md), researched 22 Oct 2026 | Pricing, fees, competitors, GTM, launch plan, blockers |
| `fg` | SparkV Feature Guide (docs/SparkV-Feature-Guide.md), checks run 22 Oct 2026 | Features, verification status, test results |
| `idc_fy25` | [IDC preliminary Q4/FY2025 PC tracker, via 9to5Mac (13 Jan 2026)](https://9to5mac.com/2026/01/13/apple-shipments-unchanged-as-pc-market-grew-during-q4-2025/) | Apple 25.6M Macs in 2025 (+11.1%); Q4 2025 7.1M, share 9.3%. Preliminary; confirm on idc.com |
| `idc_q2_25` | [IDC preliminary Q2 2025, via MacTrast (Jul 2025)](https://www.mactrast.com/2025/07/new-data-released-by-idc-shows-mac-shipments-are-continuing-to-increase/) | 6.2M Macs in Q2 2025 vs 5.1M in Q2 2024 (+21.4%) |
| `apple_100m` | [Apple, Oct 2018 event: 100 million active Macs, via TechCrunch (30 Oct 2018)](https://techcrunch.com/2018/10/30/there-are-now-100-million-macs-in-use) | Latest public active-Mac figure found; dated, label it 2018 |
| `setapp_2023` | [Setapp Mac Apps Report 2023 (n=1,241, mostly US), via SecurityBrief Asia (Oct 2023)](https://securitybrief.asia/story/42-of-macos-users-use-ai-based-apps-daily-report) | 42% use AI apps daily; 83% paid for Mac software in the past month; 70% own an M1/M2 Mac. Survey of Setapp's audience, not a census |
| `fm_2025` | [Apple Foundation Models framework, WWDC 2025, via TechCrunch (9 Jun 2025)](https://techcrunch.com/2025/06/09/apple-lets-developers-tap-into-its-offline-ai-models/) | Federighi: on-device models run 'without cloud API costs' and work offline |
| `as_2023` | [Mac Pro with M2 Ultra completes Apple silicon transition, via MobileSyrup (5 Jun 2023)](https://mobilesyrup.com/2023/06/05/apple-completes-its-transition-to-in-house-chips-with-m2-ultra-mac-pro/) | Every Mac Apple sells since June 2023 is Apple silicon |
| `mbp_2021` | [14- and 16-inch MacBook Pro with notch, 18 Oct 2021, via Macworld](https://www.macworld.com/article/677726/everything-apple-announced-at-its-18-october-event.html) | Notch introduced on MacBook Pro; 16-inch panel 3456x2234 |
| `notchnook` | [NotchNook price, via iMore](https://www.imore.com/apps/mac-apps/this-dollar25-app-gives-my-macbook-pro-a-dynamic-island-and-it-was-worth-every-penny) | $25 one-time or $3/month (business plan section 3) |
| `alcove` | [Alcove price, via appgefahren](https://www.appgefahren.de/alcove-bringt-die-dynamic-island-auf-den-mac-394469.html) | about $13.99 one-time |
| `boringnotch` | [boring.notch on GitHub](https://github.com/TheBoredTeam/boring.notch) | Free, GPL-3.0, not notarized |
| `raycast` | [Raycast Pro pricing, Raycast blog](https://www.raycast.com/blog/changing-how-raycast-ai-is-priced) | $10/month or $8/month billed yearly |
| `cleanshot` | [CleanShot X pricing, via toolradar](https://toolradar.com/tools/cleanshot/pricing) | $29 one-time with 1 year of updates, then $19/year optional |
| `wispr` | [Wispr Flow pricing, via getvoibe](https://www.getvoibe.com/resources/wispr-flow-pricing/) | Pro $15/month or $144/year |
| `granola` | [Granola pricing, Granola blog](https://granola.ai/blog/granola-pricing-plans-features-roi) | Business $14/user/month |
| `paste` | [Paste on the App Store](https://apps.apple.com/app/id967805235) | $3.99/month, $29.99/year or $89.99 lifetime |
| `lemonsqueezy` | [Lemon Squeezy fees, via Dodo Payments review](https://dodopayments.com/blogs/lemonsqueezy-review) | 5% + 50c; about +1.5% non-US orders, +0.5% subscriptions |
| `sparkv_site` | [sparkv.si (company site), read 22 Oct 2026](https://www.sparkv.si) | Software studio in Telangana, India; colour tokens |

Public figures were found by web search on 22 Oct 2026. IDC figures are preliminary and reported second-hand; confirm them on idc.com before the deck is sent. The 100 million active Macs figure is from 2018 and must always carry its year.
