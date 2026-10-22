# SparkV Customer Deck: Phase 2 Structural Blueprint

| Item | Value |
| --- | --- |
| Deck | SparkV customer / launch deck (16 slides + 2 hidden backup slides) |
| Audience | Mac users, freelancers, creators, students, teams (launch audience: Product Hunt, r/macapps, YouTube, landing page) |
| Goal | Buy Pro or start the 14-day Pro trial (no card) |
| Narrative | Problem → Solution → feature groups → proof (real screenshots, internal test results) → value vs. separate apps → fit (Mac market) → pricing → CTA |
| Canvas | 3840 × 2160 px (16:9, UHD). python-pptx: 13.333 in × 7.5 in, 1 px = 3175 EMU |
| Machine-readable twin | `docs/decks/customer/outline.json` (same content; the generator reads it) |
| Sources | `docs/SparkV-Feature-Guide.md`, `docs/SparkV-Business-Plan.md`, `docs/screenshots/*.png`, sparkv.si live CSS (colour tokens), public market figures cited inline |
| Last updated | 22 Oct 2026 |

---

## 0. Ground rules for anyone finishing this deck

1. **Only real facts.** Every number is from the two docs or a cited public source. Anything the project does not have yet is a visible placeholder in square brackets, e.g. `[TBD: private beta users]`. Never fill a `[TBD]` with a guess.
2. **No traction, users, revenue or team claims.** None exist in the source docs. The proof slide uses internal test results, labelled as such.
3. **Do not advertise:**
   - **Face Unlock.** The ArcFace weights are non-commercial only (business plan §8). It is not in the sold build.
   - **Live team sync of Spaces.** Team "shared Spaces" is a `.sparkvspace` file package today (business plan §6a).
   - **"Controls any app."** Clicky points and explains; it does not click or type for you (feature guide, Known limits 5).
4. **"Needs a live check" features** (Home media, Tray drag, Today, Dictation, Clicky, Reply Drafter, Ask Screen, Meetings, Translation, Focus glow, Modes, Downloads, File Drop, live activities) may only be claimed after the 4K recording in §3 shows them working. If a take fails, cut the claim from the slide; do not fake the take.
5. **Browser Flows is labelled "beta".** Its self-test was not clean on 22 Oct (feature guide §27).
6. **Trademarks.** Competitor names appear only on slide 13, as factual price comparisons, with a legal review before publishing (business plan §7). "Clicky" may be renamed before launch (suggested: "SparkV Assist"); swap the name everywhere through the `feature_names.clicky` key in `outline.json`.
7. **Competitor prices come from third-party listings.** Re-check each vendor's own pricing page on the day the deck is published.
8. **Launch dependencies.** Pricing, the trial and "Buy Pro" only work once Developer ID signing + notarization, Lemon Squeezy licensing and the trial code exist (business plan §1, §12). Do not publish the CTA slide before then.
9. **Requirements to state honestly:** Apple silicon, macOS 15 or later; best on a 14/16-inch MacBook Pro with a notch (elsewhere the island sits in the menu bar). UI Audit and Browser Flows need Node.js.

---

## 1. Complete outline (16 slides)

Quick map:

| # | Layout | Header | Proof asset |
| --- | --- | --- | --- |
| 1 | Key visual header | Your notch, now an AI command center. | 01-home in notch mockup (clip C01) |
| 2 | Minimal body | Your Mac work lives in six apps and six bills. | none (type only) |
| 3 | Key visual header | Hover the notch. Everything is there. | 10-agents-hub (clip C02) |
| 4 | Timeline | A day with SparkV | 06, 36, 50, 07, 28 thumbnails |
| 5 | Feature showcase with screenshot | The notch, finally useful. | 01, 04, 06, 42, 43, 45 (C03, C04) |
| 6 | Feature showcase with screenshot | Talk instead of type. | 50, 11, 17, 20 (C05, C06, C07) |
| 7 | Feature showcase with screenshot | Ask about anything on your screen. | 12, 51, 18, 48 (C08, C09) |
| 8 | Feature showcase with screenshot | Meeting notes, no bot in the call. | 36, 37, 38 (C10, C11) |
| 9 | Feature showcase with screenshot | Every file, clip and note, one search away. | 16, 14, 07, 31, 09 (C12, C13) |
| 10 | Feature showcase with screenshot | Deep work on a schedule. | 28, 29, 33, 34, 27 (C14) |
| 11 | Feature showcase with screenshot | Power tools for builders and job seekers. | 22, 35, 24, 26 (C15, C16) |
| 12 | Metrics dashboard | Private by default. Tested in the real build. | metric tiles |
| 13 | 2-column comparison | One app instead of six. | competitor table + spend chart |
| 14 | Metrics dashboard (market chart) | Made for the Mac you already have. | Mac shipments chart |
| 15 | Pricing table | Pay once. Keep it forever. | pricing table |
| 16 | CTA | Turn on your notch. | 01-home hero loop (C01) |
| A1 (hidden) | Pricing table | Prefer to pay for just what you use? | feature-pack table |
| A2 (hidden) | Metrics dashboard (revenue chart) | Why we can charge once. | per-sale breakdown chart |

All screenshot paths below are relative to `docs/screenshots/`.

---

### Slide 1: Title

- **Layout:** Key visual header
- **Header:** Your notch, now an AI command center.
- **Subtitle:** Dictation, meetings, screen help and 20 more tools. Private by default, pay once.
- **Body copy:**
  - SparkV for macOS
  - Try Pro free for 14 days · sparkv.si
- **Images:** `01-home.png` in the notch mockup (hero, centred under the notch). Optional small `46-compact-wings.png` ghosted above the fold as the "closed" state. Final: replace with still `C01-hero-0008.png` (§3, clip C01).
- **Speaker notes:** "This is the MacBook notch. Most of us look straight past it. SparkV turns it into a drawer: hover, and your music, your files, your day and more than 20 AI agents slide out. The AI runs on your Mac, and Pro is a one-time purchase. Everything you will see today is the real app, not a mock-up."

### Slide 2: Problem

- **Layout:** Minimal body
- **Header:** Your Mac work lives in six apps and six bills.
- **Subtitle:** And the best spot on your screen does nothing.
- **Body copy:**
  - Dictation, meeting notes, clipboard, screenshots, a launcher, a notch app.
  - Bought separately: about $492 in year one.
  - Monthly AI fees for work your Mac can do itself.
  - The notch: prime screen space, zero use.
- **Images:** none. Type-only slide; the "$492" figure is the visual focus.
- **Speaker notes:** "Think about the small tools a busy Mac user pays for: a dictation app, an AI meeting recorder, a clipboard manager, a screenshot tool, a launcher with AI, a notch app. Bought one by one, that comes to about four hundred and ninety-two dollars in the first year; slide 13 shows the breakdown. Many of those charge monthly for AI. Meanwhile, the notch sits in the middle of your screen doing nothing." (Figure: sum of year-one prices on slide 13; third-party listings, re-check before publishing.)

### Slide 3: Solution

- **Layout:** Key visual header
- **Header:** Hover the notch. Everything is there.
- **Subtitle:** One black drawer: media, files, your day, and a hub of 20+ agents.
- **Body copy:**
  - Hover to open. Move away to close.
  - Drop any file on the notch.
  - Every agent is one click or one hotkey away.
- **Images:** `10-agents-hub.png` in the notch mockup (hero). Final: still `C02-hub-0006.png`.
- **Speaker notes:** "Move the pointer onto the notch and the drawer opens; move away and it closes half a second later. The header switches pages: Home, Widgets, Tray, Today, Converter, Spaces. The grid icon opens the Agents hub, 22 tiles that launch every tool in SparkV. Most also have a hotkey, so you rarely need the mouse."

### Slide 4: A day with SparkV

- **Layout:** Timeline (5 nodes, left to right)
- **Header:** A day with SparkV
- **Subtitle:** One notch, every part of your day.
- **Body copy (timeline nodes):**
  1. **09:56** Meeting heads-up under the notch. ⌃⌥J joins.
  2. **10:00** One click records notes. No bot joins the call.
  3. **12:30** Hold fn, talk, release. Clean text appears.
  4. **15:00** Drop a PDF. Convert, compress or OCR it.
  5. **17:00** Focus rounds end with a recap.
- **Images:** thumbnails per node: `06-today.png`, `36-meeting-notes.png`, `50-dictation.png`, `07-converter.png`, `28-focus.png`.
- **Speaker notes:** "Here is what a normal day looks like. A meeting shows up under the notch ten minutes before it starts, with a Join button. One click records it; SparkV listens to your mic and the call audio, so no bot joins. At lunch you answer messages by voice. In the afternoon you convert a PDF without opening a website. You finish with focus rounds and a short recap." (Times are illustrative.)

### Slide 5: Notch essentials (Free)

- **Layout:** Feature showcase with screenshot (hero left, 3 live-activity bands stacked right)
- **Header:** The notch, finally useful.
- **Subtitle:** All of this is in the free plan.
- **Body copy:**
  - Media for any app: artwork glow, scrubber, bookmarks.
  - A Tray for files, with an AirDrop target.
  - Today: meetings with Join, plus a Pomodoro timer.
  - Live activities: volume, battery, notifications.
- **Images:** hero `01-home.png`; secondary `04-tray.png`, `06-today.png`; bands `42-volume-hud.png`, `43-battery.png`, `45-notification.png`. Final: stills from C03, C04.
- **Speaker notes:** "This is the free plan, and it is already a full notch app. Media controls work with any player that reports Now Playing. The Tray holds files you are moving between apps, with AirDrop built in. Today shows your next meetings with a Join button and runs a Pomodoro timer. When the drawer is closed, volume, battery and notifications appear as small live activities around the camera." (Live check required: media, tray drag, AirDrop, calendar, live activities.)

### Slide 6: Talk instead of type

- **Layout:** Feature showcase with screenshot (dictation band hero top, three cards below)
- **Header:** Talk instead of type.
- **Subtitle:** Hold fn anywhere. Talk. Release.
- **Body copy:**
  - Dictation removes filler words and formats lists.
  - Reply Drafter (⌃⌥R) writes a reply in your tone. You press Send.
  - Prompt Refiner turns a rough ask into a clear AI prompt.
  - Add your own words so names are spelled right.
- **Images:** hero `50-dictation.png`; cards `11-flow.png`, `17-reply-drafter.png`, `20-prompt-refiner-panel.png`. Final: stills from C05, C06, C07.
- **Speaker notes:** "Put the cursor in any text field, hold fn, speak, let go. SparkV cleans up the text and types it in. Double-tap fn for hands-free. In Mail, Slack or Messages, Control-Option-R reads the thread and drafts a reply in your tone; you check it and press Send yourself. Prompt Refiner asks two to five quick questions and gives you a structured prompt for whichever AI tool you use." (Live check required: fn key, speech, Reply Drafter.)

### Slide 7: Ask about your screen

- **Layout:** Feature showcase with screenshot (full-frame screen still with the Clicky answer band under the notch and a pointer callout)
- **Header:** Ask about anything on your screen.
- **Subtitle:** Works in any app, on any display.
- **Body copy:**
  - Hold ⌃⌥ and ask. Clicky answers and points to the spot.
  - ⌃⌥S: select a chart or an error, then ask about it.
  - ⌃⌥T: copy text from images, videos and locked PDFs.
- **Images:** hero `51-clicky-answer.png` over a full-frame still; secondary `12-clicky.png`, `18-ask-screen.png`, `48-copy-text.png`. Final: stills from C08, C09.
- **Speaker notes:** "Stuck in an app you don't know? Hold Control-Option and ask out loud. Clicky looks at the screen under your mouse, answers out loud and in the band under the notch, and flies a pointer to the right spot. It points; it doesn't click for you. Control-Option-S lets you select part of the screen and ask about it. Control-Option-T copies the text out of anything: a screenshot, a video frame, a locked PDF." (Without an optional Groq key, Clicky reads screen text on device. Live check required.)

### Slide 8: Meetings

- **Layout:** Feature showcase with screenshot (notes window hero, live-answer band and caption window overlapping)
- **Header:** Meeting notes, no bot in the call.
- **Subtitle:** One click to record. Transcribed on your Mac.
- **Body copy:**
  - Minutes, decisions and your tasks with due days.
  - A suggested answer when someone asks you a question.
  - Live translated captions, on device.
  - Filed into the right Space automatically.
- **Images:** hero `36-meeting-notes.png`; overlays `37-meeting-live-answers.png`, `38-live-translation.png`. Final: stills from C10, C11.
- **Speaker notes:** "Click the red button and SparkV records your microphone and the call's audio. Nothing joins the meeting. If someone asks you a question, a suggested answer appears under the notch. When you stop, you get minutes, decisions, your own tasks with due days, other people's tasks and the full transcript, filed into the right Space. Turn on Live Translation and other people's speech becomes captions in your language, translated on your Mac." (Live check required: audio capture, translation.)

### Slide 9: Files, clipboard and search

- **Layout:** Feature showcase with screenshot (search panel hero centre, four tiles around)
- **Header:** Every file, clip and note, one search away.
- **Subtitle:** ⌥Space searches your Spaces, meetings, dictations, clipboard and Tray.
- **Body copy:**
  - Clipboard history with a paste stack: ⌘⇧V.
  - Converter: PDF, image and document tools that work offline.
  - Downloads sorted by your rules as they finish.
  - Spaces: one memory per client or project, with cited answers.
- **Images:** hero `16-universal-search-panel.png`; tiles `14-clipboard-stack.png`, `07-converter.png`, `31-downloads.png`, `09-spaces-window.png`. Final: stills from C12, C13.
- **Speaker notes:** "Option-Space searches everything SparkV knows: Spaces, meetings, dictations, clipboard and Tray. Press Tab and it writes an answer from your own items with citations. Clipboard history is off until you turn it on, and it skips passwords; Command-Shift-V opens a paste stack right at your cursor. The Converter handles merge, split, compress, OCR and more without uploading anything. Downloads get sorted as they finish." (Search verified on sample data: 21 results for "launch". Downloads and drag need a live check.)

### Slide 10: Focus and wellbeing

- **Layout:** Feature showcase with screenshot (Focus page hero, Modes menu and editor right, distance tile bottom)
- **Header:** Deep work on a schedule.
- **Subtitle:** Focus rounds, one-click Modes and a nudge to sit back.
- **Body copy:**
  - Focus: 25/5, 50/10 or 90/15 rounds, Do Not Disturb and a recap.
  - Modes: one click sets apps, wallpaper, volume and music. Turn it off to restore.
  - Screen Distance: a reminder when you sit closer than 40 cm.
- **Images:** hero `28-focus.png`; secondary `29-focus-settings.png`, `33-modes.png`, `34-mode-editor.png`, `27-screen-distance.png`. Final: stills from C14.
- **Speaker notes:** "Pick a rhythm and start Focus. SparkV turns on Do Not Disturb, runs the rounds, nudges you when you open a distracting app and writes a recap. A glowing border marks the start, breaks and the end. Modes switch your whole setup in one click, Study, Meeting, Presentation, and put everything back when you turn them off. Screen Distance is off by default; switch it on and it reminds you to move back from the screen." (Live check required: DND, glow, modes, camera.)

### Slide 11: Builders and job seekers

- **Layout:** Feature showcase with screenshot (UI Audit window hero, Flow Canvas and Job Agent stacked right)
- **Header:** Power tools for builders and job seekers.
- **Subtitle:** Included in Pro.
- **Body copy:**
  - UI Audit tests your own site and writes a fix prompt for your AI coding assistant.
  - Flow Canvas chains links, PDFs and notes into AI workflows.
  - Job Agent scores your fit and tracks every application.
  - Browser Flows (beta) records a web chore once and replays it.
- **Images:** hero `22-ui-audit-window.png`; secondary `35-flow-canvas.png`, `24-job-agent-window.png`; small `26-browser-flows-window.png` with a "beta" tag. Final: stills from C15, C16.
- **Speaker notes:** "Type your site's address into UI Audit and SparkV walks it like a tester: forms, buttons, mobile and desktop layouts, accessibility and console errors. One button copies a fix prompt you can paste into your AI coding assistant. Flow Canvas is a whiteboard for AI workflows. Job Agent saves a posting with fn plus Control and scores your fit against your resume. Browser Flows is in beta. UI Audit and Browser Flows need Node.js and only run on sites you own or may test." (UI Audit verified end to end; Job Agent scoring verified, fit 81% on sample data; Browser Flows self-test not clean.)

### Slide 12: Proof and privacy

- **Layout:** Metrics dashboard (2 × 3 tiles)
- **Header:** Private by default. Tested in the real build.
- **Subtitle:** Internal checks on the current build, 22 Oct 2026.
- **Body copy (tiles: big number + caption):**
  1. **$0** cloud AI needed. Apple Intelligence, Vision, Speech and Translation run on your Mac.
  2. **50** real app views in this deck. No mock-ups.
  3. **69** issues UI Audit found on a planted-issue test site. Runner self-test: 48/48.
  4. **195 / 195** clipboard and paste-stack checks passed.
  5. **29,283** widget checks passed, 0 failed.
  6. **[TBD: private beta users]** · "[TBD: beta testimonial]"
- **Images:** none (tiles). Optional faint background: blurred `01-home.png`.
- **Speaker notes:** "By default, everything stays on your Mac: speech, screenshots, clipboard, meeting audio. Groq is optional and only used with your own key, only when you turn it on. Every screen in this deck is the real app rendered from the current source. Before launch we ran the test suites: UI Audit found 69 planted issues on a test site, clipboard checks passed 195 of 195, widget checks passed all 29,283. Beta numbers and quotes go here once the private beta has run." (Source: feature guide, Verification summary. These are internal tests, not customer metrics; keep the subtitle.)

### Slide 13: One app instead of six

- **Layout:** 2-column comparison (left: price table; right: spend chart)
- **Header:** One app instead of six.
- **Subtitle:** What the same jobs cost as separate apps.
- **Body copy:**
  - Separate apps, year one: about $492.
  - SparkV Pro: $39 once. Updates after year one are optional.
  - Footnote: Prices from public listings, Oct 2026. Feature sets differ; SparkV does not copy every feature of these apps.
- **Left column table (competitor comparison):**

| Job | Typical app | Its price | In SparkV |
| --- | --- | --- | --- |
| Notch hub | NotchNook | $25 one-time (or $3/mo) | Free plan |
| Notch island | Alcove | about $13.99 one-time | Free plan |
| Launcher with AI | Raycast Pro | $8/mo billed yearly ($10 monthly) | Pro: ⌥Space Universal Search + agents |
| AI dictation | Wispr Flow | $15/mo ($144/yr) | Pro: AI dictation |
| AI meeting notes | Granola Business | $14/user/mo | Pro: Meetings |
| Clipboard manager | Paste | $29.99/yr | Pro: unlimited history + Paste Stack |
| Screenshots and recording | CleanShot X | $29 one-time, then $19/yr updates (optional) | Pro: Copy Text, Quick Capture, Screen Recorder |
| **All of the above** | **SparkV Pro** | **$39 one-time (launch $29)** | |

- **Right column chart ("revenue chart", buyer-side spend): clustered bar, USD**

| Item | Year 1 | Year 2 | Source |
| --- | --- | --- | --- |
| NotchNook | 25.00 | 0.00 | iMore, Lowyat (business plan §3) |
| Raycast Pro (yearly) | 96.00 | 96.00 | Raycast blog, tech-insider |
| Wispr Flow (yearly) | 144.00 | 144.00 | getvoibe, spokenly |
| Granola Business | 168.00 | 168.00 | granola.ai |
| Paste (yearly) | 29.99 | 29.99 | App Store |
| CleanShot X | 29.00 | 19.00 | toolradar, TrustRadius |
| **Separate apps total** | **491.99** | **456.99** | sum |
| **SparkV Pro** | **39.00** | **0.00 (optional 19.00 renewal)** | business plan §6a |

  Chart shows two bars per year: "Separate apps" (stacked by product, neutral tones) vs "SparkV Pro" (accent). Alcove is excluded from the sum (same job as NotchNook).
- **Speaker notes:** "Here is the honest maths. These are the public prices of popular single-purpose apps that do jobs SparkV also does. Bought separately, the first year is about four hundred and ninety-two dollars, and most of it repeats every year. SparkV Pro is thirty-nine dollars once, twenty-nine during launch week. These apps have features we don't have, and we don't claim otherwise; the point is the jobs most people actually use them for." (Legal review required before naming competitors. Re-check every price on vendor sites on publish day.)

### Slide 14: Made for the Mac you already have

- **Layout:** Metrics dashboard with market chart (chart left 60%, stat stack right 40%)
- **Header:** Made for the Mac you already have.
- **Subtitle:** Apple silicon · macOS 15 or later · best on a MacBook Pro with a notch.
- **Body copy:**
  - 100M+ active Macs (Apple, Oct 2018: the latest official figure).
  - 7.1M Macs shipped in Q4 2025 alone (IDC, preliminary).
  - No notch? The island sits in the menu bar.
  - [TBD: share of Macs that are Apple silicon on macOS 15+]
- **Chart (market): column chart, Apple Mac shipments 2025, millions of units (IDC preliminary)**

| Quarter | Units (M) | Source |
| --- | --- | --- |
| Q1 2025 | 5.5 | IDC via AppleInsider, 8 Apr 2025: https://appleinsider.com/articles/25/04/08/apple-gains-ground-as-pc-market-heads-into-rocky-2025 |
| Q2 2025 | 6.2 | IDC via MacTrast, Jul 2025: https://www.mactrast.com/2025/07/new-data-released-by-idc-shows-mac-shipments-are-continuing-to-increase/ |
| Q3 2025 | [TBD: IDC Q3 2025 Mac shipments] | not found in search; leave the bar empty with the label |
| Q4 2025 | 7.1 | IDC via MacTech, 12 Jan 2026: https://www.mactech.com/2026/01/12/well-idc-says-global-mac-sales-only-grew-0-2-annual-as-of-the-fourth-quarter-of-2025/ |

  Stat source: 100 million active Macs, Apple event, 30 Oct 2018: https://techcrunch.com/2018/10/30/there-are-now-100-million-macs-in-use . Confirm all figures against IDC's own press release before publishing; the Q1 attribution comes from a search summary of the AppleInsider article.
- **Speaker notes:** "SparkV is built for Apple silicon Macs on macOS 15 or later, and it is best on a 14 or 16-inch MacBook Pro with a notch. On other displays the island sits in the menu bar. Apple last said there were over 100 million active Macs, back in 2018, and IDC estimates Apple shipped more than seven million Macs in the last quarter of 2025 alone. This is a large and growing group of people who already own the hardware." (Do not imply all of these Macs can run SparkV.)

### Slide 15: Pricing

- **Layout:** Pricing table (3 columns, Pro highlighted)
- **Header:** Pay once. Keep it forever.
- **Subtitle:** Start with a 14-day Pro trial. No card needed.
- **Body copy (under the table):**
  - Launch week: Pro $29 (₹999).
  - Students and teachers: 50% off Pro.
  - 30-day refunds, no questions asked.
  - 2 Macs per license.
- **Table:**

| | Free | **Pro** (recommended) | Team |
| --- | --- | --- | --- |
| Price | $0 | **$39 one-time** · ₹1,499 (launch week $29 · ₹999) | $8 per seat / month, billed yearly · ₹499 · minimum 3 seats |
| Updates | n/a | 12 months included, then optional $19/yr (₹799). The app keeps working. | Included |
| Macs | 1 | 2 per person | 2 per seat |
| Notch core | Media, HUD, battery, notifications, mirror, AirDrop, Tray (5 items), 2 Shortcut buttons, Timer, Today | Everything | Everything |
| Widgets | World Clock, System Gauges | All widgets | All widgets |
| Productivity | Clipboard (last 25), Copy Text, Flow history | Unlimited clipboard + Paste Stack, Converter, File Drop, Downloads rules, Quick Capture, Screen Recorder, Universal Search, Spaces, Focus, Modes, Screen Distance | Everything |
| AI assistants | Dictation (no AI formatting) | AI dictation, Clicky, Ask Screen, Reply Drafter, Prompt Refiner, Tray AI, Job Agent | Everything |
| Meetings | none | Recorder, transcripts, summaries, Live Translation | Everything |
| Developer tools | none | UI Audit, Browser Flows (beta), Flow Canvas | Everything |
| Team extras | none | none | One invoice, seat management, shared Spaces packages, priority email support (1 business day), MDM install package |
| Try it | Free forever | 14-day full trial, no card. Falls back to Free, never locks. | 30-day pilot, up to 5 seats |

- **Speaker notes:** "Three plans. Free is a complete notch app. Pro is thirty-nine dollars once, or fourteen ninety-nine rupees, and includes everything plus a year of updates; after that, updates are optional and the app keeps working. Launch week, Pro is twenty-nine dollars. Teams pay eight dollars per seat per month, billed yearly, with one invoice and priority support. Every Pro feature can be tried free for fourteen days without a card; when the trial ends you simply drop to Free and keep your data." (INR launch price is ₹999 per business plan §6a. Team "shared Spaces" means file packages, not live sync.)

### Slide 16: Call to action

- **Layout:** CTA
- **Header:** Turn on your notch.
- **Subtitle:** Try every Pro feature free for 14 days.
- **Body copy:**
  - sparkv.si
  - Launch price $29 for the first 7 days or first 500 buyers.
  - [TBD: download / checkout URL] · [TBD: QR code to checkout]
- **Images:** `01-home.png` in the notch mockup, smaller than slide 1, with the glow. Final: loop of clip C01 (00:00-00:08) for video exports.
- **Speaker notes:** "Download SparkV from sparkv.si, start the fourteen-day trial, and see what your notch can do. Launch week, Pro is twenty-nine dollars for the first seven days or the first five hundred buyers. Students get half off. Thanks for watching."

### Slide A1 (hidden backup): Feature packs

- **Layout:** Pricing table
- **Header:** Prefer to pay for just what you use?
- **Subtitle:** Feature packs (alternative model; not planned for launch).
- **Table:**

| Pack | Includes | USD | INR |
| --- | --- | --- | --- |
| Notch & Media | Media extras, HUD, all Widgets, Modes, Focus, Screen Distance, unlimited Tray | $9 | ₹499 |
| Productivity | Clipboard + Paste Stack, Converter, File Drop, Downloads, Quick Capture, Screenshot to Clipboard, Copy Text, Screen Recorder, Universal Search, Spaces | $15 | ₹799 |
| AI Assistants | AI dictation, Clicky, Ask Screen, Reply Drafter, Prompt Refiner, Tray AI, Job Agent | $19 | ₹999 |
| Meetings | Recorder, transcriber, summaries, notes, Live Translation, calendar join | $15 | ₹799 |
| Developer Tools | UI Audit, Browser Flows, Flow Canvas | $19 | ₹999 |
| Everything (= Pro) | All 5 packs | $39 (separately $77) | ₹1,499 (separately ₹4,095) |

- **Speaker notes:** "Backup only. The business plan recommends launching with three plans, not packs. Use this if the launch audience asks for a cheaper single-purpose entry, for example Meetings only."

### Slide A2 (hidden backup): Why we can charge once

- **Layout:** Metrics dashboard with revenue chart (waterfall or stacked bar)
- **Header:** Why we can charge once.
- **Subtitle:** Your $39 Pro purchase, and what it pays for.
- **Body copy:**
  - AI runs on your Mac, so there is no per-user AI bill.
  - Groq is optional and uses your own key.
- **Chart (revenue per $39 sale, Lemon Squeezy as merchant of record):**

| Line | USD | Source |
| --- | --- | --- |
| Pro price | 39.00 | business plan §6a |
| Merchant-of-record fee (5% + $0.50) | -2.45 | business plan §4 (Lemon Squeezy; about +1.5% more on non-US orders) |
| Cloud AI cost | 0.00 | business plan §9 |
| Kept by SparkV | 36.55 | business plan §4 |

- **Speaker notes:** "Backup for 'why isn't this a subscription?'. Because the AI runs on Apple's on-device frameworks, we pay nothing per user for AI, so a one-time price is sustainable."

---

## 2. Ultra-HD art direction

### 2.1 Global specs (all styles)

| Spec | Value |
| --- | --- |
| Canvas | 3840 × 2160 px; export PNG/PDF at 3840 wide; PPTX 13.333 × 7.5 in |
| Safe area | 192 px left/right, 160 px top/bottom (content box 3456 × 1840) |
| Grid | 12 columns, 244 px column, 48 px gutter, starting x = 192 |
| Type scale at 4K | Display 176 px / 1.0 line height · H1 128 / 1.05 · H2 88 / 1.1 · Subtitle 64 / 1.25 · Body 48 / 1.35 · Caption 32 / 1.4 · Minimum anywhere 28 px |
| Copy limits | Header ≤ 8 words, subtitle ≤ 14 words, ≤ 4 bullets of ≤ 14 words |
| Screenshot scale rule | Place `docs/screenshots` PNGs at ≤ 1.0× their pixel size (they are 2× renders; 1224 px drawer = 612 pt). Never upscale more than 1.25×. A hero needing more pixels uses a 4K still from §3. |
| Corner radius | Drawer: matches app (do not re-round). Cards: 40 px. Tiles: 32 px. |
| Notch mockup | Vector top strip of a MacBook Pro display, 3456 × 720 px in the hero case: screen bezel `--mockup-bezel`, camera housing (notch) centred at x = 1920, width 420 px, height 74 px, bottom corners 24 px radius. The drawer PNG is placed with its top edge at y = 0 of the screen area so the notch overlaps the drawer header like the real app. The menu bar shows only a clock "[demo time]". |
| Live-activity bands | 180 px renders (42-50) sit centred under the mockup notch at 1:1, with 0.6 opacity "closed island" ghost behind for context |
| Charts | Flat 2D, no 3D, no gradients inside bars. Value labels on bars, 40 px. Axis 28 px muted. Source line bottom-left, 28 px, `--text-muted`. `[TBD]` bars drawn as dashed outline, label in accent. |
| Motion (video/Keynote export) | Builds 400 ms ease-out cubic(0.2,0.8,0.2,1); drawer reveal 520 ms from y = -100% under the notch; no bounces, no spins |
| Accessibility | Text contrast ≥ 7:1 for body on bg, ≥ 4.5:1 for captions; never put text over a screenshot |

### 2.2 Tokens

Every slide spec below uses these tokens only. The generator maps them per style.

| Token | Meaning | A: sparkv.si red/black | B: Apple minimal | C: Dark cyberpunk |
| --- | --- | --- | --- | --- |
| `bg` | slide background | `#09090A` | `#FFFFFF` (alt sections `#F5F5F7`) | `#07060D` |
| `bg-hero` | hero slides 1, 3, 16 | `#080809` | `#000000` (Apple-style black hero) | `#07060D` + 64 px grid lines at `#FFFFFF08` |
| `surface` | cards, tiles | `#111113` | `#FBFBFD` | `#120F22` |
| `line` | hairlines, card borders | `#FFFFFF1F` | `#D2D2D7` | `#2A2547` |
| `text` | primary text | `#F7F7F5` | `#1D1D1F` (on black hero `#F5F5F7`) | `#EAE6FF` |
| `text-muted` | captions, sources | `#9A9AA1` | `#6E6E73` | `#8B86A8` |
| `accent` | key word, CTA, highlighted column | `#F01822` | `#0071E3` | `#FF2A6D` |
| `accent-2` | second data series, links | `#F7F7F5` | `#1D1D1F` | `#05D9E8` |
| `accent-ink` | text on accent | `#FFFFFF` | `#FFFFFF` | `#07060D` |
| `glow` | light behind the drawer | radial `#F01822` at 28% → 0, radius 1400 px, centred 200 px below notch | none; soft shadow `0 60px 160px #00000040` | dual radial `#FF2A6D` 30% (left) + `#05D9E8` 22% (right), radius 1200 px, plus 2 px outer stroke glow on the drawer |
| `mockup-bezel` | MacBook bezel | `#000000` | `#000000` with `#2C2C2E` 2 px edge highlight | `#000000` with 2 px `#05D9E8` 40% rim |
| `chart-1…4` | chart series | `#F01822`, `#F7F7F5`, `#9A9AA1`, `#3A3A40` | `#0071E3`, `#1D1D1F`, `#86868B`, `#D2D2D7` | `#FF2A6D`, `#05D9E8`, `#B967FF`, `#3B3561` |
| `font-display` | headers | SF Pro Display Bold (system sans, as on sparkv.si); key word in italic | SF Pro Display Semibold, tracking -0.02em | Space Grotesk Bold (Google Fonts) |
| `font-body` | body | SF Pro Text Regular | SF Pro Text Regular | Inter Regular |
| `font-mono` | hotkeys, numbers in tiles | SF Mono | SF Mono | JetBrains Mono |

Colour source for style A: live CSS of https://www.sparkv.si (dark theme variables `--background #09090a`, `--surface #111113`, `--foreground #f7f7f5`, `--muted #9a9aa1`, `--line #ffffff1f`, `--red #f01822`, `--hero #080809`; system sans/mono fonts; italic emphasis in the hero headline).

**Where the styles differ (rules, not just colours):**

- **A (sparkv.si):** black slides throughout, one red word per header (set in italic, as the site does), red only for the key word, CTA and the Pro column. Thin `line` hairlines between sections. Glow is red and low; it should read as "lit from under the notch".
- **B (Apple minimal):** white slides for text-heavy slides (2, 12, 13, 14, 15), black for hero and showcase slides (1, 3, 5-11, 16) because the screenshots are dark renders. No glow, no borders; depth only from one soft shadow. Accent blue only on links, the Pro column and the CTA button. More white space: reduce bullets to 3 where possible (`body_min` in outline.json).
- **C (Dark cyberpunk):** all dark, faint 64 px grid on hero slides, 4% scanline texture allowed on backgrounds only (never on screenshots or text). Magenta for the key word and CTA, cyan for data/second series and hotkey chips. Hotkeys set in mono inside 2 px cyan outline chips. Keep glows outside text areas.

### 2.3 Per-slide art direction

**Slide 1 (key visual header).** `bg-hero`. Notch mockup spans the top 720 px; drawer `01-home.png` (or still C01-hero-0008, crop R-DRAWER-HOME) placed at 1.0×, centred at x 1920, top flush with the screen edge. `glow` centred at (1920, 420). Header at y 1180, centred, `font-display` 176 px, "AI command center" in `accent`. Subtitle 64 px `text-muted` at y 1420. Body line 1 ("SparkV for macOS") as a 32 px overline above the header; line 2 as a pill button (`accent` fill, `accent-ink` text) at y 1640. Differences: A italic red "AI command center"; B black hero, white type, blue only on the pill; C cyan rim on the mockup, magenta pill.

**Slide 2 (minimal body).** `bg`. Left-aligned on columns 1-8. Header H1 at y 360. Subtitle H2 `text-muted`. Four bullets as a numbered list, 48 px, 72 px apart. "$492" in bullet 2 set as `accent` 88 px tabular figures. Right columns 9-12 empty except a tiny dimmed notch outline at top-right (empty notch = "zero use"). Differences: B white background, no notch outline glow; C "$492" in mono with cyan underline.

**Slide 3 (key visual header).** `bg-hero`. Mockup with `10-agents-hub.png` at 1.0× (1224 × 456). Header below at y 1260; three short body lines as a horizontal row of three captions (columns 1-4, 5-8, 9-12) at y 1700, each starting with a 40 px icon (hover cursor, file, keyboard; SF Symbols-style line icons drawn in `text-muted`). Glow as slide 1 but 20% weaker.

**Slide 4 (timeline).** `bg`. Horizontal rail at y 1180, 2 px `line`, 5 nodes evenly across x 384…3456. Node: 24 px circle in `accent`, time label above in `font-mono` 40 px, caption below (body 40 px, max 2 lines). Thumbnails above the rail: each screenshot cropped to its drawer body, scaled to 600 px wide (≤ 1.0×), radius matches app, `surface` card behind. Active node (12:30) larger (40 px) to create a focal point. Differences: B no rail glow, thin blue nodes; C rail drawn as cyan gradient line with magenta nodes.

**Slides 5-11 (feature showcase with screenshot).** Shared grid: hero image occupies columns 1-7 (x 192-2148), inside the notch mockup when the asset is a drawer/band, or inside a macOS window frame with shadow when it is a window; copy occupies columns 8-12 (x 2196-3648). Header H1 at y 220 spanning columns 8-12 (or full width if > 2 lines). Bullets 48 px. Hotkeys inside chips: `surface` fill, `line` border, `font-mono` 40 px. Secondary screenshots as `surface` cards, max 3 per slide, overlapping the hero by 80 px for depth. One "hero callout" per slide: a 4 px `accent` ring or arrow pointing at the exact UI element the header talks about.
- 5: hero `01-home` in mockup; under it three live bands stacked (42, 43, 45) at 1:1 with 24 px gaps; Tray and Today cards on the right below the copy. Callout: the scrubber.
- 6: hero `50-dictation` band under the mockup notch over a blurred text editor still (C05); cards 11, 17, 20. Callout: the band. Chip: "hold fn".
- 7: hero = full-frame still C08-clicky-0010 scaled to 2148 × 1208 (0.56×) with `51-clicky-answer` band crisp at 1.0× above it; accent arrow follows the Clicky pointer. Chips ⌃⌥, ⌃⌥S, ⌃⌥T.
- 8: hero `36-meeting-notes` window at 0.9× (1764 × 1188); `37` and `38` overlap the bottom-right. Callout: "Your tasks" section.
- 9: hero `16-universal-search-panel` at 1.0× centred in columns 1-7; four small cards (14, 07, 31, 09) in a 2 × 2 grid under the copy. Chip ⌥Space.
- 10: hero `28-focus` in mockup; `33-modes` menu card and `34-mode-editor` window card on the right; `27-screen-distance` small. In A and C, add a faint `accent` 6 px inner border around the whole slide to echo the Focus screen glow; B uses none.
- 11: hero `22-ui-audit-window` at 0.85× (1836 × 1224); `35` and `24` cards; `26` small with a "beta" tag (`text-muted` outline pill, never `accent`).

**Slide 12 (metrics dashboard).** `bg`. 3 × 2 grid of tiles in the content box, each 1120 × 760 px, `surface`, radius 32. Big number 176 px `font-display` (tile 1 "$0" in `accent`), caption 40 px `text-muted`, max 3 lines. TBD tile: dashed `line` border, number replaced by "[TBD]" in `accent`. Subtitle carries "Internal checks…": keep it visible at 48 px, not a footnote.

**Slide 13 (2-column comparison).** `bg`. Left: table columns 1-7, 36 px rows of 96 px height, zebra with `surface`; SparkV Pro row highlighted with `accent` 4 px left bar and bold. Right: chart columns 8-12, height 1300 px, two clusters (Year 1, Year 2), "Separate apps" stacked in `chart-2…4` neutral tones, "SparkV Pro" single bar in `chart-1`. Data labels on totals only. Source footnote spans full width at y 2000, 28 px. B: white background, black table text; C: cyan stacked tones, magenta SparkV bar.

**Slide 14 (market chart).** `bg`. Column chart columns 1-7: four quarters, `chart-1` bars, Q3 drawn as dashed outline with "[TBD]". Right: three stats stacked, 128 px numbers. Requirements subtitle styled as three chips (Apple silicon · macOS 15+ · notch). Sources in 28 px under the chart.

**Slide 15 (pricing table).** `bg`. Three columns, 1088 px each, 48 px gutters; Pro column raised 40 px with `accent` 4 px border and a "Recommended" pill. Price in 128 px display; launch price as a strikethrough-style pair: "$39" muted, "$29 launch week" accent. Feature rows 36 px with check glyphs; long Pro lists collapse to the six group names with "everything in Free, plus:" on the card and the full table kept in notes/outline.json. Bottom strip: four small facts (launch, student, refund, 2 Macs) as icons + 32 px text.

**Slide 16 (CTA).** `bg-hero`. Mockup + drawer smaller (0.75×) at the top; `glow` stronger (36%). Header 176 px centred, subtitle 64 px. Large button "sparkv.si" (`accent` fill) at y 1560, 960 × 160 px. TBD QR block 360 × 360 px dashed at the right of the button. Launch line 40 px `text-muted` under it.

**A1/A2 (hidden).** Same as slide 15 / slide 12 grids.

---

## 3. 4K screen-recording and screenshot scripts

### 3.1 Rig and coordinate system (read first)

- **Machine:** MacBook Pro 16-inch with notch, Apple silicon, macOS 15+. Built-in display at the default "Default" scaled size 1728 × 1117 pt (3456 × 2234 px).
- **Capture:** a ScreenCaptureKit-based recorder capturing the built-in display at native 3456 × 2234 px, 60 fps, HEVC 10-bit ≥ 80 Mbps or ProRes 422 HQ. Cursor captured (as a separate layer if the tool supports it, so its size can be raised 1.5× in post). System audio off unless stated; record voice-over separately.
- **Edit canvas: 3840 × 2160, 60p.** Place the capture scaled to 111.11% (3840 × 2482), top-aligned (y = 0), so the notch sits at top centre and the bottom 322 px fall off the canvas. **All coordinates below are canvas pixels.** Conversion: canvas_px = points × 2.2222 = render_px (from `docs/screenshots`) × 1.1111. On a 14-inch MBP (1512 × 982 pt, 3024 × 1964 px) use scale 126.98% and canvas_px = points × 2.5397, and recompute the rects.
- **Reference positions** (derived from the renders; verify on the first frame of each clip and shift all rects by the same offset if they differ):
  - Notch centre x = 1920. Drawer body x 1320-2520 (1200 px wide), top y = 0.
  - Drawer bottom: Home/Today/Spaces-size pages ≈ y 253; Widgets/Tray/Converter-size ≈ y 383; Agents hub ≈ y 447.
  - Header icons (y = 41): Home 1381, Widgets 1440, Tray 1498, Today 1556, Converter 1613, Spaces 1671 · Focus 2190, Record 2248, Agents hub 2306, Flow 2363, Clicky 2421, Gear 2468.
  - Hub tile centres: columns x 1420, 1563, 1706, 1849, 1991, 2133, 2277, 2419; rows y 139, 264, 383 (row 1: Search, Focus, Modes, Capture, Copy Text, Reply, Ask Screen, Prompt; row 2: Clipboard, Paste Stack, Record, Widgets, File Drop, Downloads, Translate, UI Audit; row 3: Jobs, Browser, Distance, Canvas, Setup, C).
  - Home: play/pause (1588, 174), volume knob (1851, 161), Dictate capsule (2132, 123), Mirror (2418, 139).
- **Standard crop rects:**

| Name | x | y | w | h | Use |
| --- | --- | --- | --- | --- | --- |
| R-FULL | 0 | 0 | 3840 | 2160 | full frame |
| R-TOP-16x9 | 960 | 0 | 1920 | 1080 | notch close-up (place at 1.0× = 1920 × 1080 in the slide, never upscale) |
| R-DRAWER-HOME | 1260 | 0 | 1320 | 300 | Home/Today/Spaces-size drawer + 60 px margin |
| R-DRAWER-MID | 1260 | 0 | 1320 | 430 | Widgets/Tray/Converter/Clipboard/Downloads/Search page |
| R-DRAWER-HUB | 1260 | 0 | 1320 | 500 | Agents hub |
| R-BAND | 1260 | 0 | 1320 | 240 | closed-island live-activity bands |
| R-WINDOW-C | centred on the window frame + 60 px margin; formula x = 1920 − w/2 − 60, y = window top − 60 | | | | windows (sizes per clip) |

- **Window placement:** before each window shot, centre the window with Window › Move & Resize › Center (macOS 15). Window sizes on canvas from the renders: Spaces 2444 × 1600, UI Audit 2400 × 1600, Job Agent 2622 × 1600, Browser Flows 2311 × 1511, Flow Canvas 2933 × 1867, Meeting notes 2178 × 1467, Translation captions 1422 × 444, Focus settings 1378 × 1600, Mode editor 1822 × 1422, Search panel 1609 × 1138, Clipboard stack 942 × 773, Downloads rules 1733 × 1156. A centred window has its centre at y ≈ 1283 (centre of the visible area below the 84 px menu bar).
- **Outputs (to create when recording; nothing exists yet):** `docs/decks/customer/media/rec/Cxx-name.mov`, stills `docs/decks/customer/media/stills/Cxx-name-SSSS.png` (SSSS = second × 1000 / 1000, e.g. 0008 = 00:08), crops `…/stills/Cxx-name-SSSS-RNAME.png`.

### 3.2 Demo environment and sample data pack (prepare once)

1. **Fresh macOS user "SparkV Demo"** so no personal data, contacts, mail or notifications appear. Dark appearance. Wallpaper: solid `#09090A` (style A/C) or a neutral Apple dark wallpaper (style B). Desktop icons hidden. Menu bar: only the clock; set the clock to a stable time where possible and note `[demo time]`.
2. **SparkV:** the notarized release-candidate build (not built for this task). All permissions granted in Setup before recording, so no prompts appear. Groq **off** (everything shown is on-device). Gear › Live Activities › Hide Message Text **on** except in C03 where the sample notification is from a demo account.
3. **Folder `~/SparkV-Demo/`** with sample files (create them; all fictional and clearly sample):
   - `Acme-Brand-Guide.pdf` (3 pages, own content), `Invoice-0423-sample.pdf`, `hero-v2.png`, `hero-v3.png`, `moodboard.jpg`, `Project-Notes.docx`, `pricing.csv`.
   - `resume-sample.pdf` (fictional person "Alex Rivera"), `job-posting-sample.html` (fictional "Senior Frontend Engineer at Northwind Labs", served on `http://localhost:8080`).
4. **Calendar** (local "Demo" calendar): "Acme design review" starting 10 minutes after record start, with a meeting link you host; "Launch sync" at 13:00; "1:1 with Sam" at 16:00.
5. **Spaces:** "Acme Redesign" (keywords acme, brand; domain acme.example), "SparkV Launch" (launch, product hunt), "Thesis" (chapter, citation). Pre-file 10-20 items by running the features once off-camera, so Search for "launch" returns results.
6. **Music:** a track you hold rights to, with artwork `[TBD: licensed demo track]`. Do not record copyrighted audio; the render's sample track must not appear in public video. Record with audio muted.
7. **Mail:** two demo mail accounts you own; a 4-message thread "Logo files for Friday?" from the second account.
8. **Meeting partner:** a colleague on a second Mac (consenting, on camera only by voice) with a short script, including the question "Alex, what's the status of the API migration?" and, for C11, two sentences in Spanish.
9. **UI Audit target:** the bundled planted-issue test site on 127.0.0.1 (`Vendor/ui-audit/test`), started by whoever records. Never point UI Audit at a third-party site.
10. **Recording overlays in post:** a keystroke HUD (bottom-centre, y 1960, 40 px `font-mono` chips in `surface`) showing each hotkey as pressed; cursor scaled 1.5× with a 60 px soft `accent` halo on clicks.

### 3.3 Clip scripts

Each beat is 4 s unless noted. Cursor paths are canvas coordinates; move at a steady 900-1200 px/s with ease-in-out, pause 0.5 s before every click.

#### C01 Hero hover (slides 1, 16)
- **Setup:** drawer closed; compact wings showing now-playing art (music playing). Home tab is the last tab used. Empty desktop.
- **Sample data:** licensed track playing, artwork visible.
- **Shot list:**
  - 00:00-00:04 Static: closed island with compact wings; cursor parked at (1920, 1300).
  - 00:04-00:08 Cursor travels (1920, 1300) → (1920, 30); drawer opens on Home at ~00:05. Hold.
  - 00:08-00:12 Cursor to play/pause (1588, 174), click (pause), click again (play) at 00:10; scrubber moves.
  - 00:12-00:16 Cursor to knob (1851, 161), scroll up 3 notches; level ring rises.
  - 00:16-00:20 Cursor away to (1920, 1300); drawer closes at ~00:17; wings return.
- **Crops:** R-TOP-16x9 for video; R-DRAWER-HOME for still.
- **Stills:** `C01-hero-0008.png` (R-DRAWER-HOME) → slide 1 hero, slide 16 hero; `C01-hero-0002.png` (R-BAND) → slide 1 ghost of closed state.
- **Overlay:** slide 1 mockup drawer slot (1.0×, centred under the notch at x 1920, y 0 of the mockup screen); slide 16 at 0.75×; 00:00-00:08 loop for video exports of slide 16.

#### C02 Agents hub (slide 3)
- **Setup:** drawer closed, last tab Home.
- **Shot list:**
  - 00:00-00:04 Hover notch at (1920, 30); Home opens.
  - 00:04-00:08 Cursor to Agents hub icon (2306, 41), click; hub opens (taller drawer).
  - 00:08-00:12 Cursor glides along row 1 (1420, 139) → (2419, 139), hovering 0.4 s on Search, Reply, Ask Screen so tooltips with hotkeys show.
  - 00:12-00:16 Cursor down to row 2 (1420, 264) → (2419, 264), then rest on Translate (2277, 264).
  - 00:16-00:20 Cursor away; drawer closes.
- **Crops:** R-DRAWER-HUB (still), R-TOP-16x9 (video).
- **Stills:** `C02-hub-0006.png` (R-DRAWER-HUB) → slide 3 hero.

#### C03 Notch essentials and live activities (slide 5)
- **Setup:** drawer closed. Gear › Live Activities: Volume & Brightness, Hide macOS volume pop-up, Battery, Notifications all on. Laptop on battery at ~60%, charger in reach. Finder window with `~/SparkV-Demo/` open at bottom-left (x 200-1500, y 1300-2100).
- **Shot list:**
  - 00:00-00:04 Press volume up key ×3: SparkV volume HUD replaces the macOS pop-up.
  - 00:04-00:08 Plug in the charger: battery charging band.
  - 00:08-00:12 Demo account sends an iMessage/Mail "Logo files for Friday?": notification preview band (Hide Message Text temporarily off for this take only; sender is a demo account).
  - 00:12-00:20 (8 s) Drag `hero-v3.png` from Finder (700, 1700) → notch (1920, 30); drawer flips to Tray; drop. Then drag `Acme-Brand-Guide.pdf` the same way.
  - 00:20-00:24 Cursor to the Tray's AirDrop tile (right end of the tray, verify x on frame ≈ 2440, y ≈ 230), hover only (do not send).
  - 00:24-00:28 Cursor away; drawer closes.
- **Crops:** R-BAND for the three bands; R-DRAWER-MID for the Tray.
- **Stills:** `C03-band-0002` (volume), `C03-band-0006` (battery), `C03-band-0010` (notification) → slide 5 right stack; `C03-tray-0019` (R-DRAWER-MID) → slide 5 Tray card.

#### C04 Today and Join (slides 4, 5)
- **Setup:** "Acme design review" starts in 4 minutes; drawer closed.
- **Shot list:**
  - 00:00-00:04 Closed island shows the meeting heads-up "in 4 min" with Join.
  - 00:04-00:08 Hover the heads-up: drawer opens on Today with the meeting list and the Pomodoro timer.
  - 00:08-00:12 Cursor to timer start (verify on frame), click: "FOCUS 1/4" counting.
  - 00:12-00:16 Cursor away; press ⌃⌥J: meeting link opens in the browser (cut before any third-party meeting UI shows real people).
- **Crops:** R-BAND (heads-up), R-DRAWER-HOME (Today).
- **Stills:** `C04-today-0002` (R-BAND) and `C04-today-0010` (R-DRAWER-HOME) → slide 4 node 1, slide 5 Today card.

#### C05 Dictation (slides 4, 6)
- **Setup:** TextEdit window, centred, 1600 × 1000 pt, empty document, 20 pt font; cursor in the document. Flow › Words contains "SparkV", "Northwind". Dictation key fn, AI formatting on.
- **Script to speak:** "Um, so for Friday we need three things: the logo files, the pricing page, and, uh, the SparkV launch video."
- **Shot list:**
  - 00:00-00:04 Cursor parked in the document (1920, 1100). Keystroke HUD shows "hold fn".
  - 00:04-00:12 (8 s) Hold fn and speak; the dictation band shows under the notch with live level.
  - 00:12-00:16 Release fn: cleaned text appears formatted as a 3-item list without "um/uh".
  - 00:16-00:20 Hover notch, click Flow icon (2363, 41): History shows the entry with app and time.
- **Crops:** R-BAND (band), R-FULL (before/after text), R-DRAWER-HOME (Flow).
- **Stills:** `C05-dictation-0008` (R-BAND) → slide 6 hero band and slide 4 node 3; `C05-dictation-0015` (R-FULL, downscaled to 0.56×) → slide 6 background; `C05-flow-0019` → slide 6 card.

#### C06 Reply Drafter (slide 6)
- **Setup:** Mail, centred, thread "Logo files for Friday?" selected, reply window open with the cursor in the body. Reply Drafter Tone & Name set to "Alex", friendly-brief.
- **Shot list:**
  - 00:00-00:04 Static on the thread.
  - 00:04-00:08 Press ⌃⌥R (HUD shows it); drafting indicator.
  - 00:08-00:16 (8 s) Draft is written into the message box. Cursor moves to the Send button and stops 0.5 s **without clicking** (the user sends, not SparkV). Cut.
- **Crops:** R-WINDOW-C around the Mail reply window; R-DRAWER-HOME if the Reply page is shown.
- **Stills:** `C06-reply-0014` → slide 6 Reply card (can replace `17-reply-drafter.png`).

#### C07 Prompt Refiner (slide 6)
- **Setup:** Agents hub open.
- **Shot list:**
  - 00:00-00:04 Click Prompt tile (2419, 139).
  - 00:04-00:08 Type "write a launch email for our notch app"; pick target "General".
  - 00:08-00:12 Click Refine; 2-5 question chips appear.
  - 00:12-00:16 Click one chip per question.
  - 00:16-00:20 Structured prompt shown; click Copy.
- **Crops:** crop of the refiner panel (≈ 1360 × 1316 under the notch: x 1240, y 0, w 1360, h 1340).
- **Stills:** `C07-prompt-0018` → slide 6 card (replaces `20-prompt-refiner-panel.png`).

#### C08 Clicky (slide 7)
- **Setup:** Keynote or Pages open full-screen-ish (window centred) on a sample document; you want to show "Where do I change the export format?". Groq off.
- **Shot list:**
  - 00:00-00:04 Cursor resting over the app's toolbar (1400, 300).
  - 00:04-00:10 (6 s) Hold ⌃⌥ and ask "Where do I change the export format?"; Clicky listening band under the notch.
  - 00:10-00:16 (6 s) Release; answer band (as `51-clicky-answer.png`) appears and the pointer flies to the right menu. Record the spoken answer audio on a separate track.
  - 00:16-00:20 Hold on the pointer; then cursor moves away.
- **Crops:** R-FULL (whole screen, used at 0.56× on the slide), R-BAND (answer band at 1.0×).
- **Stills:** `C08-clicky-0010` (R-FULL) → slide 7 hero background; `C08-clicky-0012` (R-BAND) → slide 7 answer band.
- **Live check:** if the pointer does not land on the right control, do not use the take or the claim "points to the spot".

#### C09 Ask Screen and Copy Text (slide 7)
- **Setup:** Preview window centred with a sample chart image and a sample screenshot containing a paragraph.
- **Shot list:**
  - 00:00-00:04 Press ⌃⌥S; drag from (1200, 700) to (2600, 1500) over the chart.
  - 00:04-00:12 (8 s) Panel with quick actions; click "Explain"; answer streams.
  - 00:12-00:16 Press ⌃⌥T; drag over the paragraph (1200, 1600) → (2600, 1900).
  - 00:16-00:20 "Copied N lines" band; paste into TextEdit to prove it.
- **Crops:** R-WINDOW-C on the Ask panel; R-BAND for the Copy Text band.
- **Stills:** `C09-ask-0010` → slide 7 card; `C09-copytext-0017` (R-BAND) → slide 7 card.

#### C10 Meeting notes and live answers (slides 4, 8)
- **Setup:** a call with the meeting partner (§3.2-8) in a browser window you host. Gear › Meetings › Suggest Answers to Questions on. Calendar title "Acme design review".
- **Shot list:**
  - 00:00-00:04 Click the red record icon (2248, 41); recording capsule appears.
  - 00:04-00:12 (8 s) Partner asks "Alex, what's the status of the API migration?"; suggested answer appears under the notch.
  - 00:12-00:16 Click stop.
  - 00:16-00:24 (8 s) Notes window opens: Minutes, Key points, Decisions, Your tasks; scroll slowly to Your tasks.
- **Crops:** R-BAND (live answer), R-WINDOW-C 2178 × 1467 (notes window).
- **Stills:** `C10-answer-0009` → slide 8 overlay; `C10-notes-0022` → slide 8 hero and slide 4 node 2.
- **Consent:** everyone in the call agrees to be recorded; blur any face or name not in the demo script.

#### C11 Live Translation (slide 8)
- **Setup:** Translate tile on, target English, caption window visible (bottom-centre). Spanish language pack downloaded beforehand.
- **Shot list:**
  - 00:00-00:04 Start recording a meeting.
  - 00:04-00:12 (8 s) Partner speaks two Spanish sentences; English captions with the original underneath.
  - 00:12-00:16 Hold; stop.
- **Crops:** R-WINDOW-C 1422 × 444 around the caption window.
- **Stills:** `C11-translate-0010` → slide 8 overlay.

#### C12 Universal Search and Clipboard stack (slide 9)
- **Setup:** Spaces and Flow populated (§3.2-5); clipboard history turned on with 8-10 sample copies (a link, a hex colour, an email address, a code line). TextEdit open, centred.
- **Shot list:**
  - 00:00-00:04 Press ⌥Space; panel opens.
  - 00:04-00:08 Type "launch"; grouped results appear.
  - 00:08-00:12 Press Tab (Ask): cited answer from your items.
  - 00:12-00:16 Esc; click into TextEdit (1920, 1300); press ⌘⇧V: stack at the cursor.
  - 00:16-00:20 Arrow down twice, Return: item pasted.
- **Crops:** R-WINDOW-C 1609 × 1138 (search panel); crop around the stack at the text cursor (≈ 942 × 773 + 60 margin, anchored at the cursor position, verify on frame).
- **Stills:** `C12-search-0007` → slide 9 hero; `C12-stack-0015` → slide 9 card.

#### C13 Converter and Downloads (slides 4, 9)
- **Setup:** Downloads watcher on; a sample file URL you host (e.g. a 50-100 MB file on your own server) to show progress. Finder with `~/SparkV-Demo/`.
- **Shot list:**
  - 00:00-00:04 Hover notch, click Converter (1613, 41).
  - 00:04-00:08 Drag `Acme-Brand-Guide.pdf` from Finder onto the Converter page.
  - 00:08-00:12 Click "Compress"; result appears in the box below.
  - 00:12-00:20 (8 s) Start the sample download in Safari; progress, speed and time left under the notch; on finish click Sort.
- **Crops:** R-DRAWER-MID (Converter, Downloads).
- **Stills:** `C13-converter-0011` → slide 9 card, slide 4 node 4; `C13-downloads-0018` → slide 9 card.

#### C14 Focus and Modes (slides 4, 10)
- **Setup:** Focus rhythm 50/10, 2 rounds; Screen Effects on. Do Not Disturb Shortcuts configured. Mode "Presentation" set up in the editor.
- **Shot list:**
  - 00:00-00:04 Click the moon (2190, 41); Focus page.
  - 00:04-00:08 Click Start Focus; screen glow border appears (record R-FULL to show it).
  - 00:08-00:12 Use Focus › Preview › End to show the end glow and recap (preview, so no 50-minute wait).
  - 00:12-00:16 Press ⌃⌥1 (first Mode): wallpaper/volume change; press again to restore.
  - 00:16-00:20 Open Edit Modes…: editor window, centred.
- **Crops:** R-FULL (glow), R-DRAWER-HOME (Focus page), R-WINDOW-C 1822 × 1422 (editor).
- **Stills:** `C14-focus-0006` (R-FULL at 0.56×) → slide 10 background option; `C14-focus-0003` → slide 10 hero and slide 4 node 5; `C14-modes-0019` → slide 10 card. Screen Distance: use the existing `27-screen-distance.png` (no recording; it needs the camera).

#### C15 UI Audit (slide 11)
- **Setup:** planted-issue test site running on 127.0.0.1 (§3.2-9); UI Audit window centred. Node.js and Playwright Chromium installed.
- **Shot list:**
  - 00:00-00:04 Type `http://127.0.0.1:<port>`, choose "Full frontend".
  - 00:04-00:12 (8 s) Click Start; Chromium walks the site; findings stream in by severity. Speed this section 4× in post and label "4× speed".
  - 00:12-00:16 Click Summarize; on-device summary.
  - 00:16-00:20 Click P; "fix prompt copied" state.
- **Crops:** R-WINDOW-C 2400 × 1600.
- **Stills:** `C15-uiaudit-0011` → slide 11 hero (replaces `22-ui-audit-window.png`).

#### C16 Flow Canvas and Job Agent (slide 11)
- **Setup:** Flow Canvas template "Competitor pricing comparison" loaded with your own sample links/files only; Job Agent with `resume-sample.pdf`; `job-posting-sample.html` open in Safari at localhost:8080.
- **Shot list:**
  - 00:00-00:04 Flow Canvas window (resize to 2400 × 1600 canvas px, centred); click Run all.
  - 00:04-00:08 Cards complete; output card fills.
  - 00:08-00:12 Switch to Safari posting; hold fn + ⌃: saved toast with the fit score.
  - 00:12-00:16 Open Job Agent window: Tracker board with the new posting.
- **Crops:** R-WINDOW-C for each window.
- **Stills:** `C16-canvas-0006` → slide 11 card; `C16-jobs-0015` → slide 11 card.
- **Browser Flows:** no recording until its self-test passes cleanly; keep `26-browser-flows-window.png` with the "beta" tag.

### 3.4 Still-capture checklist (for every still)

1. Export the frame at 3840 × 2160 PNG, sRGB, no compression artefacts.
2. Crop with the named rect; save crops separately (never crop in the slide).
3. Check: no personal data, no real third-party names or faces, no copyrighted artwork, no permission prompts, clock shows `[demo time]`.
4. Check the claim on the slide matches what the frame shows; if a "Needs a live check" feature misbehaved, drop the claim.
5. Update `images[].final` in `outline.json` with the still's path.

---

## 4. Generator notes (`outline.json`)

- `deck.canvas` is 3840 × 2160; every `placement` is in canvas px `{x, y, w, h}`. EMU = px × 3175.
- `deck.image_root` is the absolute path of `docs/screenshots/`; `images[].file` is a file name in it. `images[].final` names the planned 4K still (empty until recorded); the generator should prefer `final` when the file exists.
- `images[].frame`: `notch_mockup`, `window`, `card`, `band` or `none`.
- `chart` objects: `type` (`bar_stacked_clustered`, `column_clustered`, `waterfall`), `categories`, `series[{name, values}]`, `null` values with a `tbd` label must be drawn as dashed outlines with that label. `source` is printed as the footnote.
- `table` objects: `columns`, `rows`, `highlight_column`.
- `styles` holds the three token sets; pick one with `--style a|b|c`.
- Hidden slides have `"hidden": true` (python-pptx: set `show="0"` on the slide element).

---

## 5. Open placeholders

| Placeholder | Slide | Who fills it |
| --- | --- | --- |
| [TBD: private beta users], [TBD: beta testimonial] | 12 | after the 30-50 user private beta (business plan §11, days 23-25) |
| [TBD: IDC Q3 2025 Mac shipments] | 14 | IDC press release |
| [TBD: share of Macs that are Apple silicon on macOS 15+] | 14 | a sourced public figure, or delete the line |
| [TBD: download / checkout URL], [TBD: QR code] | 16 | after Lemon Squeezy products exist |
| [TBD: licensed demo track] | C01, C03 | music you hold rights to |
| [demo time] | all clips | the recorder |
| Clicky final name | 6, 7, 15 | product decision (business plan §7) |
