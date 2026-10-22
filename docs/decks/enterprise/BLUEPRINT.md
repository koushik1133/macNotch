# SparkV Enterprise Deck: Phase 2 Blueprint

Deck: **SparkV Team, 30-day pilot proposal** · Audience: enterprise and agency buyers (IT, security, operations, agency principals) · Ask: a Team pilot, 30 days, up to 5 seats.

Machine-readable twin: `outline.json` (same folder). The python-pptx generator reads that file; this document is the human spec and the source of truth when the two disagree.

Inputs used: `docs/SparkV-Feature-Guide.md`, `docs/SparkV-Business-Plan.md`, the 50 renders in `docs/screenshots/`, sparkv.si's live stylesheet (colors), and the public sources listed in [Sources](#sources). Nothing here claims users, revenue, customers or team members. Every number the project does not have is a `[TBD: ...]` placeholder, and every public number carries its source.

---

## 0. Narrative and honesty rules

**Story arc (16 slides):** the problem (2) → the market context (3) → what SparkV does, shown in real UI (4-8) → what it is worth, with stated assumptions (9) → privacy and security (10) → deployment (11) → admin and support (12) → competitors (13) → price (14) → the pilot (15) → the ask (16).

**Rules every slide follows**

1. **Status is stated, not implied.** The feature guide marks many features "Needs a live check". Showcase notes say so, and the pilot is framed as the live check.
2. **Pre-1.0 facts are disclosed on slide 11.** Today's build is signed with a local identity. Developer ID signing, notarization, licensing code and the MDM `.pkg` are on the 30-day launch checklist. The pilot runs on the notarized 1.0 build (`[TBD: 1.0 date]`).
3. **Things that do not exist are never promised:** SSO or SCIM, live Spaces sync (sharing is a `.sparkvspace` file package), an org-wide switch that blocks Groq, Face Unlock in the sold build (blocked by the ArcFace non-commercial license), "control any app" (the screen assistant points; it does not click).
4. **The ROI figure is a model.** Slide 9 shows the assumptions table next to the total, and the subtitle says "not a measured result".
5. **Competitor prices** come from third-party listings in the business plan. The slide says "verify on vendor pages before external use".
6. **Naming:** the business plan advises against "Clicky" in marketing (trademark). Deck copy says "screen assistant"; the recording scripts use the in-app label because that is what is on screen. If the feature is renamed (for example "SparkV Assist"), update copy and re-record R7c.
7. **Placeholders render visibly**: `[TBD: ...]` uses the `tbd` token (muted text, 2 px dashed outline). Never delete one to make a slide look finished.

---

## 1. Complete outline

Layout types used: key visual header (1), metrics dashboard (2, 3, 9), feature showcase with screenshot (4-8), two-column comparison (10, 13), timeline (11, 15), minimal body (12), pricing table (14), CTA (16).

Visual types covered: app screenshots in notch mockups (1, 4, 5, 7, 16), window screenshots (6, 7, 8, 11), pricing table (14), competitor comparison (13), market chart (3), cost and revenue charts (13, 14), ROI chart (9).

Screenshot paths are relative to `docs/screenshots/`. Native sizes are in pixels (renders are 2x).

---

### Slide 1 · Key visual header · Title

- **Header:** Your team's notch, now an AI command center.
- **Subtitle:** SparkV Team: a 30-day pilot for up to 5 seats
- **Body:**
  - Dictation, meetings, search and screen help, on device
  - Private by default. Deploys with your MDM.
  - sparkv.si
- **Visual:** full-bleed frame from recording **R1** at 00:05 (drawer open on Home). Fallback until R1 exists: `01-home.png` (1224x282) in the notch mockup, top center.
- **Speaker notes:** SparkV lives in the MacBook notch. Hover it and a drawer opens with media, a file tray, your day and a hub of more than 20 agents. Today we are asking for one thing: a 30-day pilot with up to five people on your team. We measure the time it saves against a baseline you set, and you decide on day 30.

### Slide 2 · Metrics dashboard · Where the work week goes

- **Header:** Where the work week goes
- **Subtitle:** Talking about work and looking for things crowd out the work itself
- **KPI tiles (value / label / source line):**
  - **57%** / of Microsoft 365 users' time goes to communicating; 43% to creating / Microsoft Work Trend Index 2023
  - **19%** / of interaction workers' time goes to searching for and gathering information / McKinsey Global Institute, 2012
  - **68%** / say they lack enough uninterrupted focus time / Microsoft Work Trend Index 2023
  - **3x** / faster text entry by speech than a phone keyboard (English) / Stanford, Baidu, UW study, 2016
- **Footer tile:** [TBD: your team's own baseline, measured in pilot week 1]
- **Screenshots:** none.
- **Speaker notes:** Four public numbers frame the problem. Caveats to say out loud: the 3x figure compares speech with a phone keyboard, not a desktop keyboard, so the ROI model on slide 9 uses a much smaller gain. The McKinsey figure is from 2012 and is a share of time, not "1.8 hours a day" (that conversion circulates but is not McKinsey's number). The pilot replaces all of these with your own baseline.

### Slide 3 · Metrics dashboard with market chart · Macs keep gaining ground

- **Header:** Macs keep gaining ground
- **Subtitle:** SparkV runs on Apple silicon Macs with macOS 15+, best on MacBooks with a notch
- **KPI tiles:**
  - **25.6M** / Macs shipped worldwide in 2025 (+11.1%) / IDC preliminary, Jan 2026
  - **9.0%** / of global PC shipments, up from 8.7% / IDC preliminary, Jan 2026
  - [TBD: Macs in your organization]
  - [TBD: of those, MacBooks with a notch on macOS 15+]
- **Chart C1 (column):** Global Mac shipments, millions of units

  | Year | Mac units (M) | Share of PC shipments | Basis |
  | --- | --- | --- | --- |
  | 2024 | 23.0 | 8.7% | Derived: 25.6 / 1.111 (IDC growth rate) |
  | 2025 | 25.6 | 9.0% | IDC preliminary |

  Annotations: "Omdia estimate for 2025: 27.7M (+16.4%)"; "Total PC market 2025: 284.7M (+8.1%)". Source line: IDC via 9to5Mac (13 Jan 2026) and MacTech (12 Jan 2026).
- **Screenshots:** none.
- **Speaker notes:** Context, not a pitch for our revenue: the Mac fleet keeps growing faster than the PC market. Omdia puts 2025 even higher. The 2024 bar is derived from IDC's growth rate, and the chart label says so. Ask the buyer for their fleet numbers to fill the two TBD tiles; that also sizes the pilot.

### Slide 4 · Feature showcase · One notch. 20+ agents.

- **Header:** One notch. 20+ agents.
- **Subtitle:** Hover the notch and the drawer opens. Move away and it closes.
- **Body:**
  - Write: dictation, reply drafts, prompt refiner
  - Meet: recording, notes, live answers, translation
  - Find: Spaces and Universal Search (⌥Space)
  - See: ask about any screen, copy text from any pixel
  - Ship: UI Audit, Browser Flows, Flow Canvas
- **Screenshot:** `10-agents-hub.png` (1224x456) in the notch mockup. Motion: **R2**.
- **Speaker notes:** This is the Agents hub: 22 tiles in an 8 by 3 grid, every one wired in the current build (verified headless). A tile opens its page, runs at once or shows a menu. Hover a tile to see its shortcut. Everything in this deck is reachable from here or from a hotkey.

### Slide 5 · Feature showcase · Write at the speed of speech

- **Header:** Write at the speed of speech
- **Subtitle:** Hold fn, talk, release. Clean text lands where the cursor is.
- **Body:**
  - Dictate into any text field: filler words removed, lists formatted
  - ⌃⌥R drafts a reply in your tone; you review and press Send
  - ⌘⇧V opens the clipboard stack at the cursor
  - Clipboard history stays off until the user turns it on
- **Screenshots:** `50-dictation.png` (1224x180, band under the notch), `17-reply-drafter.png` (1224x282, drawer), `14-clipboard-stack.png` (848x696, floating panel). Motion: **R3**, **R4**, **R5**.
- **Speaker notes:** Dictation types into any app. Reply Drafter reads the thread and writes into the message box; it never sends. Clipboard history is off by default and skips passwords and private copies. Status: dictation and Reply Drafter are "needs a live check" in the feature guide because they depend on the microphone, the fn key and other apps; the clipboard stack logic passed 195 checks. The pilot is the live check.

### Slide 6 · Feature showcase · Meeting notes, no bot in the call

- **Header:** Meeting notes, no bot in the call
- **Subtitle:** One click records the mic and the call audio. Transcription runs on the Mac.
- **Body:**
  - Minutes, decisions and your tasks with due days
  - Suggested answers when someone asks you a question
  - Live captions translate other speakers, on device
  - Filed to the right client Space automatically
- **Screenshots:** `36-meeting-notes.png` (1960x1320, main window), `38-live-translation.png` (1280x400, caption inset), `37-meeting-live-answers.png` (1960x1320, secondary, right column under the bullets). Motion: **R6**.
- **Speaker notes:** No bot joins the call, so there is nothing for the other side to admit. Your policy on telling participants about recording still applies: [TBD: customer's call-recording notice policy]. Live Translation uses Apple Translation on device after a one-time language download. Status: needs a live check (audio capture); notes and answers render from saved meetings.

### Slide 7 · Feature showcase · Every client in its own Space

- **Header:** Every client in its own Space
- **Subtitle:** Find anything you saw, heard or copied. Ask about anything on screen.
- **Body:**
  - Spaces file meetings, notes, mail, pages and screenshots per client
  - ⌥Space searches Spaces, meetings, dictations, clipboard and Tray
  - Ask mode answers from your own items, with citations
  - Hold ⌃⌥ and ask about any app; SparkV points at the spot
- **Screenshots:** `09-spaces-window.png` (2200x1440, main), `16-universal-search-panel.png` (1448x1024, inset overlapping the main window's lower right), `51-clicky-answer.png` (1224x220, band). Motion: **R7a**, **R7b**, **R7c**.
- **Speaker notes:** Built for agencies with several clients. Be exact about sharing: a Space can be exported and shared as a `.sparkvspace` file package; there is no live sync between teammates today. The screen assistant points and explains; it does not click or type. Without a Groq key it reads the screen text on device. Status: Spaces and Universal Search verified headless (21 results for "launch" on sample data); the screen assistant needs a live check.

### Slide 8 · Feature showcase · QA client sites before they ship

- **Header:** QA client sites before they ship
- **Subtitle:** UI Audit walks your site like a tester, then writes the fix prompt
- **Body:**
  - Crawls pages, fills forms on test hosts, checks 1440 px and 390 px
  - Accessibility (axe-core), Tab order, console errors, failed requests
  - Findings by severity, with screenshot and steps to reproduce
  - P copies a fix prompt for Claude Code, Cursor or Copilot
- **Proof strip (bottom right, mono):** Verified run on our test site: 6 pages · 69 findings · 3 critical · 15 high
- **Screenshot:** `22-ui-audit-window.png` (2160x1440). Backup: `21-ui-audit.png` (drawer page). Motion: **R8**.
- **Speaker notes:** This is the one feature verified end to end: SparkV's own controller audited the bundled planted-issue test site on 127.0.0.1 (6 pages, 69 findings: 3 critical, 15 high), Apple Intelligence wrote the summary on device, and P produced a 51,666-character fix prompt covering 60 issues. The runner self-test passed 48/48. It submits forms only on local or test hosts unless allowed and never clicks Delete or Log out unless allowed. Needs Node 20+ and Playwright's Chromium. Use only on sites you own or may test (EULA).

### Slide 9 · Metrics dashboard with ROI chart · About 2.5 hours back per person, per week

- **Header:** About 2.5 hours back per person, per week
- **Subtitle:** A model to test in the pilot, not a measured result
- **KPI tiles:**
  - **150 min** / modeled time saved per person per week / Model (assumptions below)
  - **$96** / Team list price per seat per year / SparkV pricing
  - **~3 min** / saved per week pays for a seat at $40/hour / Example rate, [TBD: your loaded rate]
- **Footer line:** Assumptions are conservative and replaced by measured values in the pilot.
- **Chart C2 (horizontal bar):** Modeled minutes saved per person per week

  | Workflow | Assumption | Minutes/week |
  | --- | --- | --- |
  | Dictation | 120 min/week of typed prose; speech 1.5x faster (half the 3x phone-keyboard result) | 40 |
  | Meeting write-ups | 4 recorded meetings/week x 10 min of notes saved | 40 |
  | Reply drafts | 15 routine replies/week x 2 min saved | 30 |
  | Finding past work | Spaces + Universal Search save 20 min/week of looking | 20 |
  | Screen tools | Copy Text, clipboard stack, Converter, Ask Screen | 20 |
  | **Total** | | **150** |

  Label on chart: "Model: assumptions, not measured". Break-even formula (in notes and as a footnote): minutes per week = 96 / (46 working weeks x hourly rate) x 60. At $40/h: 3.1 min.
- **Screenshots:** none.
- **Speaker notes:** Walk through the assumptions table, not the total. Dictation uses a 1.5x speed-up, half of the published 3x, because that study used a phone keyboard. The hourly rate is the buyer's number; $40 is only an example. If a buyer pushes on any row, halve it: the seat still pays for itself many times over at any realistic rate. The pilot measures the real figure.

### Slide 10 · Two-column comparison · Private by default

- **Header:** Private by default
- **Subtitle:** AI runs on the Mac. Nothing leaves unless someone turns it on.
- **Left column, "Stays on the Mac":**
  - Speech, meeting audio and transcripts
  - Screenshots, clipboard, Spaces, camera
  - AI: Apple Intelligence, Vision, Speech, Translation
  - Keys stored in the macOS Keychain
- **Right column, "Leaves only by choice":**
  - Groq: opt-in per feature, with your own key
  - Sends the screenshot under the pointer and the question, only while asking
  - License check: key, anonymous device ID, app version to Lemon Squeezy
  - Nothing else. No analytics.
- **Chip row:** Clipboard history off by default; passwords skipped · No meeting bot · Recorded browser passwords never saved · Face Unlock not in the sold build
- **Screenshots:** none (icon-only slide; see art direction).
- **Speaker notes:** This slide is the security reviewer's summary. AI cost to us is $0 because it runs on device, so there is no business reason to route data to a server. Groq is optional, per feature, and uses the customer's own key; nothing uses it unless turned on. Licensing talks to Lemon Squeezy, the merchant of record, which also handles payment data. Face Unlock is excluded from the sold build because its face model is licensed for non-commercial use only. Gap to disclose: there is no admin-enforced switch to block Groq org-wide yet [TBD: managed preference to disable Groq].

### Slide 11 · Timeline · Deploy in a day

- **Header:** Deploy in a day
- **Subtitle:** Signed, notarized and packaged for your MDM
- **Steps (5 nodes):**
  1. **Package:** Developer ID signed, notarized .pkg (com.sparkv.app)
  2. **Push:** Install with any MDM that deploys .pkg [TBD: MDMs tested]
  3. **Pre-approve:** PPPC profile allows Accessibility; Screen Recording, camera and mic stay user-approved
  4. **First launch:** Setup explains each permission; nothing is asked until Allow
  5. **Activate:** Seat key from the Team portal; 2 Macs per person
- **Status strip:** Status: signing, notarization, licensing and the .pkg are on the 1.0 checklist. The pilot runs on the notarized 1.0 build. [TBD: 1.0 date]
- **Requirements line:** Requires Apple silicon and macOS 15+. Node 20+ only for UI Audit and Browser Flows.
- **Screenshot:** `41-onboarding-permissions.png` (1560x1360). Alternate: `40-onboarding-welcome.png`. Motion: **R9**.
- **Speaker notes:** Be candid: today's build is signed with a local identity. Developer ID signing, notarization, licensing and the MDM package are tasks in the 30-day launch plan, and the pilot starts on that build. On permissions: an MDM privacy profile (PPPC) can pre-approve Accessibility; Screen Recording can at most be made approvable by standard users; camera and microphone always need the user's own approval. Verify against Apple's PPPC payload documentation for the customer's macOS version. With one stable Developer ID, grants survive updates.

### Slide 12 · Minimal body · Seats, admin and support

- **Header:** Seats, admin and support
- **Subtitle:** One invoice, simple seats, and a person who answers
- **Rows (label / text):**
  - **Seats** / 1 seat = 1 person on 2 Macs. Minimum 3 seats. Move a Mac by deactivating it in the gear menu.
  - **Admin** / Assign and revoke seats in the Lemon Squeezy customer portal. One invoice, PO or bank transfer.
  - **Resilience** / Checks the license every 7 days, 14 days offline grace. Never locks: falls back to Free and keeps data.
  - **Support** / Priority email, 1 business day. Signed automatic updates. 30-day refund.
- **Screenshots:** none.
- **Speaker notes:** Disclose what does not exist: no SSO or SCIM, no central policy console beyond the seat portal, and shared Spaces are file packages without live sync. Seat management may run on Keygen instead of Lemon Squeezy if needed. Updates ship through Sparkle with EdDSA-signed feeds. Support contact: [TBD: support email].

### Slide 13 · Two-column comparison with chart · One seat instead of five subscriptions

- **Header:** One seat instead of five subscriptions
- **Subtitle:** Overlapping tools, per seat, year one, list prices
- **Left: comparison table**

  | Tool | Covers | List price |
  | --- | --- | --- |
  | Wispr Flow Teams | Dictation | from $10/user/mo |
  | Granola Business | Meeting notes | $14/user/mo |
  | Raycast Pro | Launcher with AI | $8/mo billed yearly |
  | Paste | Clipboard | $29.99/yr |
  | CleanShot X | Screenshots, recording | $29 one-time |
  | NotchNook | Notch hub | $25 one-time |
  | Alcove | Notch | about $13.99 one-time |
  | **SparkV Team** | **All of the above areas** | **$8/seat/mo billed yearly** |

- **Right: Chart C3 (stacked bar):** Year-one cost per seat, USD list

  | Item | Basis | USD |
  | --- | --- | --- |
  | Wispr Flow Teams | from $10/user/mo x 12 | 120.00 |
  | Granola Business | $14/user/mo x 12 | 168.00 |
  | Raycast Pro | $8/mo billed yearly x 12 | 96.00 |
  | Paste | $29.99/yr | 29.99 |
  | CleanShot X | $29 one-time (year one) | 29.00 |
  | **Five-tool stack** | sum | **442.99** |
  | **SparkV Team** | $8/seat/mo billed yearly | **96.00** |

- **Footer:** Prices from third-party listings, Oct 2026; verify on vendor pages before external use. Overlap in areas covered, not feature parity.
- **Screenshots:** none.
- **Speaker notes:** The point is consolidation: one vendor review, one invoice, one privacy story. Do not claim parity: Granola, Wispr and Raycast are deep products in their own lanes. Monthly prices are annualized x12. NotchNook and Alcove stay out of the stack bar because they are one-time notch apps SparkV replaces outright.

### Slide 14 · Pricing table with revenue chart · Simple per-seat pricing

- **Header:** Simple per-seat pricing
- **Subtitle:** Start with a pilot. Keep the seats that earn their place.
- **Table (Team column highlighted):**

  | | Free | Pro | **Team** |
  | --- | --- | --- | --- |
  | Price | $0 | $39 one-time (launch $29), ₹1,499 | **$8 per seat per month, billed yearly ($96), ₹499** |
  | For | Trying the notch | Individual professionals | **Teams of 3 or more** |
  | Includes | Notch core, clocks and gauges, clipboard (25), Copy Text, dictation without AI formatting | Everything: AI assistants, meetings, Spaces, developer tools | **Everything in Pro, plus one invoice, seat portal, shared Spaces packages, priority support, MDM .pkg** |
  | Macs | 1 | 2 per person | **2 per seat** |
  | Try it | Always free | 14-day full trial, no card | **30-day pilot, up to 5 seats** |

- **Chart C4 (column), annual contract value at list price:**

  | Seats | USD per year | INR per year |
  | --- | --- | --- |
  | 5 | 480 | 29,940 |
  | 10 | 960 | 59,880 |
  | 25 | 2,400 | 149,700 |
  | 50 | 4,800 | 299,400 |

  Label: "List-price arithmetic ($96 or ₹5,988 per seat per year); not a forecast". Footer: [TBD: volume tiers above 50 seats].
- **Screenshots:** none.
- **Speaker notes:** Team is the recommended column for this audience. Pro includes 12 months of updates with optional renewal at $19 a year; the app keeps working. Students get 50% off Pro. Lemon Squeezy, as merchant of record, handles tax and invoices. The chart is plain arithmetic for common team sizes, not a forecast and not a discount offer.

### Slide 15 · Timeline · The 30-day pilot

- **Header:** The 30-day pilot
- **Subtitle:** Up to 5 seats. Your success criteria. A clear yes or no.
- **Steps:**
  1. **Day 0:** Kickoff: pick 5 users, agree success criteria, share the security pack
  2. **Days 1-3:** Deploy the .pkg and PPPC profile; 15-minute permissions walkthrough
  3. **Days 1-7:** Baseline: users log time on writing, meeting notes and searching
  4. **Days 8-25:** Daily use; weekly 15-minute check-in; support within 1 business day
  5. **Days 26-30:** Readout: measured vs. modeled time saved; decide on Team seats
- **Footer lines:**
  - Success criteria [TBD with customer]: hours saved per user per week, zero open security findings, users who want to keep it
  - After day 30: seats convert to Team (minimum 3) or are removed; the app falls back to Free
- **Screenshots:** none.
- **Speaker notes:** The pilot is designed to produce a yes or a no, not a slow fade. Agree the measurement method on day 0 [TBD: time-log method, for example a short daily form]. If the measured savings come in under the model, say so in the readout.

### Slide 16 · CTA · Start your 30-day pilot

- **Header:** Start your 30-day pilot
- **Subtitle:** Five seats. Thirty days. Your numbers.
- **Body:**
  1. Name up to 5 pilot users and a start date
  2. We send the security pack and the signed .pkg
  3. Day 30: readout and a decision
  - [TBD: sales contact email] · sparkv.si
- **Visual:** `01-home.png` in the notch mockup, top center (or R1 loop).
- **Speaker notes:** Close on the single ask. Leave the slide up during questions. Do not promise SSO, live Spaces sync or org-wide Groq controls; they do not exist today.

---

## 2. Ultra-HD art direction

### 2.1 Canvas, grid and type

| Item | Spec |
| --- | --- |
| Master | 3840x2160 (16:9). PPTX page 13.333 x 7.5 in; 1 in = 288 px at 4K. |
| Safe area | 0.6 in (173 px) left/right, 0.5 in top, 0.56 in bottom. Nothing but full-bleed imagery crosses it. |
| Grid | 12 columns, 0.22 in (64 px) gutter. Showcase media spans columns 1-7, text 8-12. |
| Type (pt / px at 4K) | KPI 72 / 288 · H1 40 / 160 · H2 28 / 112 · subtitle 20 / 80 · body 18 / 72 (never smaller) · caption 12 / 48 · source line 10 / 40 |
| Line length | Body max 48 characters per line; max 5 bullets; max 2 lines per bullet. |
| Screenshot scale | Renders are 2x Retina. In the 4K master never scale a render above **1.5x** of its pixel size (a 1224 px drawer max 1836 px = 6.375 in). Window renders (2000+ px) can go full column. For larger drawer imagery use the 4K recordings, not upscales. |
| Export | Stills: PNG, sRGB, 16-bit from ProRes grabs. Charts: native PPTX charts (editable) plus a 4K PNG render for Keynote/Google Slides. |

### 2.2 Tokens

Write every slide against these tokens. Values per style:

| Token | sparkv.si red/black | Apple minimal | Dark cyberpunk |
| --- | --- | --- | --- |
| `bg` | #09090A | #FFFFFF (alt #F5F5F7 for media slides) | #05060A |
| `bg-elev` (cards, tiles) | #111113 | #F5F5F7 | #0D0F1A |
| `line` | #FFFFFF1F | #D2D2D7 | #00E5FF24 |
| `text` | #F7F7F5 | #1D1D1F | #E6F1FF |
| `text-muted` | #9A9AA1 | #6E6E73 | #7A8BA8 |
| `accent` | #F8262F (red on dark) | #0071E3 | #00E5FF |
| `accent-strong` | #F01822 | #0066CC | #FF2E88 |
| `ok` | #57D791 | #1D8E3E | #39FF88 |
| `glow` | rgba(248,38,47,.35), 240 px blur | none; soft shadow 0 40 80 rgba(0,0,0,.12) | rgba(0,229,255,.45), 160 px blur, plus 1 px #FF2E88 rim |
| `tbd` | #9A9AA1 dashed 2 px | #86868B dashed 2 px | #7A8BA8 dashed 2 px |
| Chart series 1-5 | #F8262F, #F7F7F5, #9A9AA1, #57D791, #303035 | #0071E3, #1D1D1F, #86868B, #1D8E3E, #D2D2D7 | #00E5FF, #FF2E88, #7A8BA8, #39FF88, #1B2033 |
| Display / body / mono | SF Pro Display / SF Pro Text / SF Mono (site uses the system sans stack) | SF Pro Display / SF Pro Text / SF Mono | Space Grotesk / Inter / JetBrains Mono (embed or fall back to Helvetica Neue) |
| Texture | none; one red hairline under headers | none | 64 px grid at 4% `accent`, faint scanlines on full-bleed only |

The red/black values were read from sparkv.si's stylesheet on 22 Oct 2026 (`--background #09090a`, `--red #f01822`, `--red-on-dark #f8262f`, `--surface #111113`, `--muted #9a9aa1`, success `#57d791`).

**Do not recolor screenshots.** The app's own accent is violet/indigo (Setup window, Done button). Deck tokens color only the chrome around the screenshots.

### 2.3 Notch mockup (shared by all styles)

1. **Base:** top 30% of a 16-inch MacBook Pro display in `bg`-agnostic black: a 3840 px wide black band with the notch centered (x = 1920). Notch: black, bottom corners radius 24 px, width and height measured from an R1 frame (start with 400 x 72 px at 4K and correct).
2. **Mask the render.** Every drawer render sits on a navy backdrop (about #1E2030 gradient) outside the black drawer. Cut the drawer silhouette (pure black body, rounded bottom corners, flared top shoulders) to alpha before placing. Bands (42-51) mask the same way.
3. **Place** the drawer flush to the top edge, centered on the notch, so drawer black and notch black merge with no seam.
4. **Glow:** one `glow` ellipse behind the drawer, 1.4x drawer width, 60% opacity (none in Apple minimal; use the soft shadow instead).
5. **Per style:** red/black sits the black band directly on `bg` (the drawer reads as part of the page). Apple minimal puts the band inside a dark display crop with 32 px radius and an aluminium-gray bezel line (#D2D2D7) on the white page. Cyberpunk adds a 1 px `accent` outline on the drawer silhouette and the grid texture behind.

Window renders (09, 22, 36, 37, 41) use a macOS window frame: 20 px radius, 1 px `line` border, shadow 0 60 120 rgba(0,0,0,.5) on dark styles, 0 40 80 rgba(0,0,0,.18) in Apple minimal. Floating panels (14, 16, 38) use the same frame at 16 px radius.

### 2.4 Per-slide direction

Boxes are in inches (x, y, w, h) on the 13.333 x 7.5 page and match `outline.json`.

| # | Composition | Tokens in play | Style differences |
| --- | --- | --- | --- |
| 1 | R1 frame full-bleed; open drawer at top center; header lower-left at (0.6, 4.6), 2 lines max; subtitle `text-muted`; body lines 18 pt; "sparkv.si" in `accent`. Darken lower 45% with a `bg` gradient (0 to 85%) for legibility. | bg, text, accent, glow | Red: red glow under drawer, red hairline under header. Apple: the R1 frame sits in a rounded display crop centered on white, header centered below it, no gradient. Cyber: grid texture, `accent` glow, header with 1 px `accent-strong` offset shadow (2 px right). |
| 2 | 2x2 KPI tiles (each 5.9 x 2.1 in) in `bg-elev`, value in KPI size `accent`, label `text`, source `text-muted` 10 pt bottom-left. TBD tile full width under the grid, dashed `tbd`. | bg-elev, accent, tbd | Red: values white, a small red bar left of each tile. Apple: values `text`, accent only on the 3x. Cyber: values `accent`, tile borders `line`, mono source lines. |
| 3 | Chart C1 left (0.6, 1.7, 7.0, 4.6): two columns, 2025 in `accent`, 2024 in `text-muted`; value labels on top; annotations as small callouts. KPI tiles stacked right (8.2-12.73). | chart-1, chart-3, tbd | Red: 2025 bar red, 2024 gray. Apple: 2025 blue, thin axis, no gridlines. Cyber: bars with 1 px glow edge, axis labels mono. |
| 4 | Notch mockup with 10-agents-hub at (0.6, 1.9, 6.3, 2.35), glow behind; five bullets right, each starting with the bold verb (Write, Meet, Find, See, Ship) in `accent`. | glow, accent | Red: verbs red. Apple: verbs `text` bold, mockup in display crop. Cyber: verbs `accent`, tile row underline in `accent-strong`. |
| 5 | Left stack: band 50 (top), drawer 17 (middle), clipboard stack 14 (bottom-left inset). Keycap chips (fn, ⌃⌥R, ⌘⇧V) in `bg-elev` with 1 px `line`, set next to the matching bullet. | bg-elev, line, accent | Red: keycaps with red text. Apple: keycaps light gray, black glyphs. Cyber: keycaps outlined in `accent`, mono glyphs. |
| 6 | Window 36 large left; caption strip 38 below it; window 37 small in the right column under the bullets. A thin `accent` line connects bullet 2 to window 37. | line, accent | Red: connector red. Apple: no connector; captions under images instead. Cyber: connector with glow, scanline overlay on caption strip only. |
| 7 | Collage: Spaces window 09 left; search panel 16 overlapping its lower right with a heavier shadow; answer band 51 bottom-left. Bullets right. | glow, line | Red: red glow behind the search panel. Apple: plain shadows, no glow. Cyber: `accent` glow behind panel, `accent-strong` rim on the band. |
| 8 | Window 22 large left; proof strip bottom-right in mono on `bg-elev`: "6 pages · 69 findings · 3 critical · 15 high". Severity colors come from the screenshot; do not add new ones. | bg-elev, font-mono | Red: "3 critical" in red. Apple: strip in `text`, no color. Cyber: strip in `accent`, mono. |
| 9 | Chart C2 horizontal bars left (0.6, 1.7, 7.2, 4.4), values at bar ends; a stamp "MODEL" in `tbd` style top-right of the chart. KPI tiles right. Assumptions table below the chart in 12 pt caption type. | chart-1, tbd | Red: bars red. Apple: bars blue. Cyber: bars `accent` with glow, "MODEL" stamp in `accent-strong`. |
| 10 | Two columns of equal weight. Left header with a lock glyph in `ok`; right header with an outbound arrow glyph in `accent`. Chip row along the bottom in `bg-elev`. No screenshot. | ok, accent, bg-elev | Red: right column heading red. Apple: both headings `text`, glyphs colored. Cyber: left column `ok` rim, right `accent-strong` rim. |
| 11 | Rail at y 3.2 in across 0.6-8.2 in, five nodes; node = 0.36 in circle in `accent`; labels above, text below (max 3 lines, 14 pt). Window 41 right. Status strip full width at y 6.3 in, dashed `tbd` border. | accent, tbd | Red: nodes red, rail white 20%. Apple: nodes blue, rail #D2D2D7. Cyber: nodes `accent` with glow, rail `line`. |
| 12 | Four rows, label column 2.2 in in `accent` (H2), text `text` 18 pt, 1 px `line` dividers. Generous whitespace, no imagery. | accent, line | Red: labels red. Apple: labels `text` semibold. Cyber: labels mono `accent`. |
| 13 | Table left (0.6, 1.7, 6.9, 4.6) with the SparkV row highlighted in `bg-elev` and `accent` text; chart C3 right: stacked bar of five muted segments vs. one `accent` SparkV bar; totals at bar ends ($443, $96). | chart-1..5, accent | Red: stack in grays, SparkV red. Apple: stack in grays, SparkV blue. Cyber: stack in `#1B2033` shades with `line` borders, SparkV `accent` glow. |
| 14 | Pricing table (0.6, 1.6, 8.4, 4.9): Team column raised 0.12 in, `accent` 3 px top border, "Recommended for teams" tag. Chart C4 right, four columns, values on top. | accent, bg-elev | Red: Team border red. Apple: Team border blue, other columns no fill. Cyber: Team column with `accent` glow, others `line` borders. |
| 15 | Same rail system as slide 11, five nodes labeled by day; footer lines with the TBD criteria in `tbd`. | accent, tbd | As slide 11. |
| 16 | Notch mockup top center; header centered at y 2.4 in; three numbered steps in a row of three cards; contact line centered in `accent`. | glow, accent, tbd | Red: red glow, contact in red. Apple: white page, steps as plain numbered text. Cyber: cards with `accent` rims, contact in mono. |

---

## 3. 4K screen-recording and screenshot scripts

### 3.1 Global setup (do once)

**Machine and display**

- 16-inch MacBook Pro, Apple silicon, macOS 15 or later. Built-in display at **Default** scaling (1728 x 1117 pt, captured at 3456 x 2234 px). The notch only exists on the built-in display; on an external 4K display the island sits in the menu bar, so do not record notch shots there.
- 14-inch alternative: 3024 x 1964 capture, scale 126.98% in the edit. Re-measure every coordinate below.

**Capture and edit**

- OBS Studio, "macOS Screen Capture" source (ScreenCaptureKit, display mode, cursor on), canvas and output 3456 x 2234, 60 fps, Apple ProRes 422 HQ (or HEVC 10-bit, 100 Mbps).
- Edit timeline **3840 x 2160, 60 fps**. Scale the clip to **111.11%** (3840 x 2482), anchor top (y = 0); the bottom 322 px fall off. **All coordinates below are in this 3840 x 2160 timeline.**
- Landmarks (from the 2x renders, x = 1240 + 1.111 x render-x; confirm on the first take): notch center x = 1920; drawer spans x 1240-2600 from y = 0; drawer heights 313 px (282 px renders), 413 px (372), 507 px (456); bands 200 px (180).
- Header icons at y = 37: Home 1381 · Widgets 1440 · Tray 1498 · Today 1556 · Converter 1613 · Spaces 1671 · Focus 2190 · Record 2247 · Agents hub 2304 · Flow 2363 · screen assistant 2420 · gear 2468.
- Agents hub tiles: columns x 1420, 1562, 1704, 1848, 1990, 2133, 2276, 2419; rows y 128, 261, 383. (UI Audit = row 2, column 8 = (2419, 261).)

**Clean demo environment**

- A new macOS user, "SparkV Demo", Dark appearance. No personal mail, contacts or files on it. All sample names below are invented demo data and must not look like real customers.
- Wallpaper: solid dark gray **#1A1B20** (System Settings › Wallpaper › Colors › custom). The black drawer must read against it, and editors can key or grade it per style.
- Dock auto-hide on; desktop icons hidden; Stage Manager off; quit every app not in the shot; menu-bar clock set to analog so no date is visible.
- Pointer size 1.5 (Accessibility › Display › Pointer size). Click rings are added in post (a 48 px `accent` ring, 250 ms).
- Do Not Disturb on for every take.
- SparkV: the notarized 1.0 build once it exists; until then the locally signed build (grants persist across rebuilds). Grant all permissions beforehand except for R9. gear › Live Activities › **Hide Message Text** on. Clipboard history on for R5 only.
- Every take is also a live check. If a feature misbehaves, stop, log it, and use the static render on the slide. Never edit a failure to look like a success.

**Stills from recordings**

Export the named frame from the ProRes master as a 16-bit PNG at the crop rectangle given, then mask (section 2.3). For a clean single-window still without recording, ⇧⌘4, Space, ⌥-click the window (no shadow) gives a 2x PNG.

**Post overlays (all styles)**

- Keycap chips when a hotkey is pressed: 0.2 s in, held while the key is held, 0.2 s out, placed bottom-center at (1920, 1960).
- Speed-up badges ("4x") whenever time is compressed.
- No fake UI: never draw results, counts or text the take did not show.

### 3.2 Shot lists

#### R1 · Hero (slides 1 and 16)

**Set up:** Music app playing a royalty-free track from the crew's own library, artwork visible. Drawer closed. gear › Live Activities › Now Playing beside the notch on. Check the compact wings position live first: offscreen renders clip them near the top edge (feature guide, known limit 4). If they clip live too, skip 00:00-00:02.

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:02 | Closed notch; compact wings show artwork and level meter. | Rest at (1920, 1300). |
| 00:02-00:04 | Move to the notch; drawer opens on Home (media, capsules, mirror). | (1920, 1300) to (1920, 40), 0.8 s ease-out. |
| 00:04-00:07 | Hold on Home. Frame **00:05** is the slide 1 still. | Drift to (1700, 200), no click. |
| 00:07-00:09 | Click the Agents hub icon; drawer grows to the hub. | To (2304, 37), click. |
| 00:09-00:12 | Hold, then leave; drawer closes after 0.5 s. | (2304, 37) to (1920, 1300) at 00:11. |

**Crops:** slide 1 still = full frame (0, 0, 3840, 2160) at 00:05. Notch loop for slide 16 = (1140, 0, 1560, 600), 00:02-00:09.
**Overlay:** slide 1 full-bleed; slide 16 notch mockup top center at 100%.

#### R2 · Agents hub (slide 4)

**Set up:** Drawer closed; Translate tile off (so it does not read "Translate On", or leave on to match the render; decide once).

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:02 | Open the drawer. | (1920, 1100) to (1920, 40). |
| 00:02-00:03 | Click Agents hub icon. | To (2304, 37), click. |
| 00:03-00:10 | Glide along row 1; pause 0.6 s on Search, Copy Text, Reply, Ask Screen so each shortcut tooltip shows. | (1420, 128) to (2419, 128), stops at x 1420, 1990, 2133, 2276. |
| 00:10-00:12 | Drop to row 2 and rest on UI Audit. | To (2419, 261). |

**Crop:** (1140, 0, 1560, 600). **Overlay:** slide 4 media box (0.6, 1.9, 6.3, 2.35 in) as a looping video in the notch mockup; still fallback `10-agents-hub.png`.

#### R3 · Dictation (slide 5, band)

**Set up:** TextEdit, new document, 28 pt SF Pro, window placed at (600, 700)-(3240, 1900). gear › Dictation › Hold to Talk key = fn, AI Formatting on. Flow › Words: add "Northwind". Quiet room; speaker 30 cm from the Mac.
**Line to speak:** "Quick update on the Northwind launch. Um, the landing page is done, the pricing page needs one more review, and we ship Thursday."

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:01 | Text cursor blinking in the empty document. | Pointer parked at (3000, 1700). |
| 00:01-00:06 | Hold **fn** and speak; the dictation band shows under the notch. Keycap chip "fn". | None. |
| 00:06-00:07 | Release fn. | None. |
| 00:07-00:10 | Cleaned text types in (filler removed). | None. |

**Crops:** band (1140, 0, 1560, 260); document text (600, 700, 2640, 600) for an optional second layer. **Overlay:** slide 5 band box (0.6, 1.75, 6.2, 0.91 in); still fallback `50-dictation.png`. Show the typed result only as captured.

#### R4 · Reply Drafter (slide 5, drawer)

**Set up:** Mail with a demo mailbox on a test domain the crew controls. Sample thread from "Alex Rivera (sample)": "Can we move Thursday's review to Friday at 10?" Click Reply so the compose body has focus. Reply Drafter chips: write into box on, Groq off. Tone & Name… set to the demo user. Window at (400, 300)-(3440, 2000).

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:02 | Thread and empty reply visible. | Rest at (2600, 1500). |
| 00:02 | Press **⌃⌥R**. Keycap chip. | None. |
| 00:02-00:06 | Drawer shows the Reply Drafter page while drafting. | None. |
| 00:06-00:10 | Draft appears in the compose body. | Move to (2400, 1100) slowly. |
| 00:10-00:12 | Hover Send; **do not click**. End take. | To Send button [measure]. |

**Crops:** drawer (1140, 0, 1560, 360); compose body [measure on first take]. **Overlay:** slide 5 drawer box (0.6, 2.9, 6.2, 1.43 in); still fallback `17-reply-drafter.png`. Nothing is sent in any take.

#### R5 · Clipboard stack (slide 5, inset)

**Set up:** Clipboard page › Turn On. Copy, in order: a sentence ("Ship the onboarding fix before Friday's demo."), a URL on a test domain, a 3-line Swift snippet, a demo email address on a test domain, the hex color #4F8EF7, one image. TextEdit document focused, cursor at (1600, 1200).

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:01 | Empty line in the document. | Pointer parked at (3000, 1700). |
| 00:01 | Press **⌘⇧V**; stack opens at the text cursor. | None. |
| 00:02-00:04 | Press ↓ twice (highlight moves). | None. |
| 00:04 | Press ↩; the snippet pastes. | None. |
| 00:05-00:07 | Hold on the pasted text. | None. |

**Crop:** (1500, 1100, 1000, 900) around the stack [confirm on first take]. **Overlay:** slide 5 inset (0.6, 4.55, 2.5, 2.05 in); still fallback `14-clipboard-stack.png`.

#### R6 · Meeting, live answers, translation (slide 6)

**Set up:** Calendar event "Northwind weekly (sample)" starting 4 minutes after roll, with a meeting link on the crew's own test account. A second device joins as Speaker B and plays scripted lines. gear › Meetings › Suggest Answers to Questions on; Live Translation on, read language English, caption window on; Spanish downloaded in Apple Translation beforehand. Both speakers are crew and agree to be recorded.
**Speaker B lines:** (Spanish) "¿Cuándo estará lista la nueva página de precios?" then (English) "Alex, what's the status of the API migration?"

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:03 | Heads-up under the notch: "in 4 min" with Join. | Rest at (1920, 1300). |
| 00:03 | Click the Record icon in the header. | To (1920, 40) to open, then (2247, 37), click. |
| 00:03-00:08 | Speaker B, Spanish line; caption window shows English with the original underneath. | Move off to (3000, 1500). |
| 00:08-00:14 | Speaker B, English question; suggested answer appears under the notch. | None. |
| 00:14 | Click Record again to stop. | To (2247, 37), click. |
| 00:14-00:22 | Notes window: Minutes, Decisions, Your tasks; scroll to Your tasks. | Scroll at (1920, 1100). |

Time compression: the call itself runs longer; cut between beats, badge any speed-up.
**Crops:** answer band (1140, 0, 1560, 360); caption window placed before the take at (2400, 1500)-(3820, 1960), crop (2380, 1480, 1460, 500); notes window placed at (830, 250)-(3010, 1717), crop (780, 200, 2280, 1570). **Overlay:** slide 6 main (window), inset (captions), secondary (answer). Still fallbacks `36`, `38`, `37`.

#### R7a · Spaces (slide 7, main)

**Set up:** Three Spaces: "Northwind (client)", "Acme Robotics (client)", "Internal Ops", each with keywords and a test domain. Seed: the R6 meeting, five dictations, three web pages saved with ⌃⌥C from the crew's test site, two notes containing "launch". Open Spaces window placed at (698, 300)-(3142, 1900).

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:02 | Spaces window, Inbox selected. | Rest at (1200, 900). |
| 00:02-00:04 | Click "Northwind (client)"; Memory summary and items show. | To the Space row [measure], click. |
| 00:04-00:08 | Click Ask, type "What did we promise Northwind for launch?", ↩. | To Ask field [measure]. |
| 00:08-00:12 | Answer streams with citations; hover the first citation. | To citation [measure]. |

**Crop:** (650, 250, 2540, 1700). **Overlay:** slide 7 main box. Still fallback `09-spaces-window.png`.

#### R7b · Universal Search (slide 7, inset)

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00 | Press **⌥Space**; panel opens. | Pointer parked at (3400, 1800). |
| 00:01-00:03 | Type "launch". | None. |
| 00:03-00:06 | Results grouped by source; filters visible. | None. |
| 00:06 | Press Tab (Ask). | None. |
| 00:06-00:10 | Answer with citations. | None. |

**Crop:** starting guess (1115, 250, 1610, 1140) for the 1448 x 1024 panel [confirm position on first take]. **Overlay:** slide 7 inset. Still fallback `16-universal-search-panel.png`. Show only the result count the take shows.

#### R7c · Screen assistant (slide 7, band)

**Set up:** Keynote with a sample deck open, window at (300, 200)-(3540, 2000). No Groq key (on-device path, matching the privacy slide). If the on-device answer is weak, keep it anyway or drop the clip; do not switch to Groq without labeling it on the slide.
**Question:** "Where do I change the export format?"

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:01 | Keynote visible. | Rest at (1900, 1200). |
| 00:01-00:04 | Hold **⌃⌥**, ask the question aloud. Keycap chip. | None. |
| 00:04 | Release. | None. |
| 00:04-00:09 | Answer in the band under the notch; pointer flies to the spot. | System-driven. |

**Crops:** band (1140, 0, 1560, 300); full frame for the pointer flight. **Overlay:** slide 7 band box. Still fallback `51-clicky-answer.png`.

#### R8 · UI Audit (slide 8)

**Set up:** Node 20+ at `/opt/homebrew/bin/node`; Playwright Chromium present. Serve the bundled planted-issue test site on 127.0.0.1 [TBD: exact start command, see `Vendor/ui-audit/test/`]. UI Audit window at (1380, 300)-(3780, 1900); the Chromium window it opens sits behind, left.

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:02 | Open the drawer, click Agents hub, click UI Audit. | (1920, 40), (2304, 37), (2419, 261). |
| 00:02-00:05 | Type `http://127.0.0.1:[port]`, mode Full frontend. | To the address field [measure]. |
| 00:05 | Click **Start**. | To Start [measure]. |
| 00:05-00:20 | Chromium crawls; findings stream in by severity. Run at 4x with badge. | Rest. |
| 00:20-00:26 | Click a Critical finding; screenshot and steps show. | To the first Critical row [measure]. |
| 00:26-00:30 | Click **Summarize**; on-device summary appears. | To Summarize [measure]. |
| 00:30-00:32 | Click **P**; "copied" confirmation. | To P [measure]. |

**Crop:** (1340, 260, 2480, 1680). **Overlay:** slide 8 main box. Still fallback `22-ui-audit-window.png`. The proof strip on slide 8 quotes the verified run in the feature guide; if this take shows different counts, keep the strip (it cites the verified run) and never overlay the take's counts as if they were the same run.

#### R9 · Setup and permissions (slide 11)

**Set up:** A second fresh user, "SparkV Demo 2", with no grants. First launch of SparkV. Setup window centered at (1053, 330)-(2787, 1841). The admin password prompt in System Settings is entered off camera and cut.

| Time | Action | Cursor path |
| --- | --- | --- |
| 00:00-00:04 | Welcome page. Click the continue button. | To the button [measure]. |
| 00:04-00:08 | Terms & Privacy. Continue. | Same. |
| 00:08-00:12 | Permissions: ring at 0/12, rows "Not asked yet". | Rest at (2600, 900). |
| 00:12 | Click **Allow…** on Accessibility; System Settings opens to the right pane. | To Allow… [measure]. |
| 00:12-00:16 | Toggle SparkV on (cut the password prompt). Return to Setup; row reads Allowed, ring increments. | To the toggle [measure], then back. |

**Crop:** (1000, 280, 1840, 1610). **Overlay:** slide 11 window box (8.6, 1.6, 4.1, 3.57 in). Still fallback `41-onboarding-permissions.png` (shows 6/12 allowed).

### 3.3 Delivery

- Masters: `docs/decks/enterprise/recordings/R*.mov` (ProRes), one folder per take day.
- Deck loops: H.264 or HEVC MP4 at the crop size, 60 fps, 6-12 s, seamless loop (crossfade 10 frames).
- Stills: `docs/decks/enterprise/stills/R*-<timecode>.png`, masked, 16-bit.
- `outline.json` `images[].motion` points to these names; the generator uses the PNG fallback when a motion file is missing.

---

## Sources

| ID | Used on | Source |
| --- | --- | --- |
| msft_wti_2023 | 2 | Microsoft Work Trend Index 2023, [Will AI Fix Work?](https://www.microsoft.com/en-us/worklab/work-trend-index/will-ai-fix-work); coverage: [The Register](https://www.theregister.com/2023/05/10/microsoft_work_trend_index/). Verify exact wording on Microsoft's page. |
| mgi_2012 | 2 | McKinsey Global Institute, [The social economy](https://www.mckinsey.com/industries/technology-media-and-telecommunications/our-insights/the-social-economy) (2012): about 19% of interaction workers' time searching and gathering information. |
| stanford_2016 | 2, 9 | [Stanford News, Aug 2016](https://news.stanford.edu/stories/2016/08/stanford-study-speech-recognition-faster-texting): speech 3.0x faster than a phone keyboard in English. |
| idc_2025 | 3 | IDC preliminary 2025 data via [9to5Mac](https://9to5mac.com/2026/01/13/apple-shipments-unchanged-as-pc-market-grew-during-q4-2025/) and [MacTech](https://www.mactech.com/2026/01/12/well-idc-says-global-mac-sales-only-grew-0-2-annual-as-of-the-fourth-quarter-of-2025/amp/); Omdia figure via [Cult of Mac](https://www.cultofmac.com/?p=921135). |
| apple_pppc | 11 | [Apple Platform Deployment: PPPC payload](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web). |
| bp_section3, bp_section6 | 13, 14 | `docs/SparkV-Business-Plan.md` sections 3 and 6a (competitor prices with linked third-party sources; SparkV pricing). |
| feature_guide | 4-8, 10-12 | `docs/SparkV-Feature-Guide.md` (feature behavior, status labels, verification summary, known limits). |
| sparkv_site | Art direction | sparkv.si stylesheet, read 22 Oct 2026. |
