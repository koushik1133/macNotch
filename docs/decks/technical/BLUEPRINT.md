# SparkV Technical Deck: Phase 2 structural blueprint

Audience: developers and technical partners. Goal: credibility. The deck walks from the notch window to the agents, then to how the code is built, signed and shipped, and ends with the roadmap and a call to action.

Machine-readable twin: `outline.json` in this folder (same slide numbers, copy, images, chart data and placements) for the python-pptx generator.

---

## 0. Ground rules for whoever builds this deck

1. **Every number is real or labelled.** Numbers come from `docs/SparkV-Feature-Guide.md` (FG), `docs/SparkV-Business-Plan.md` (BP), the code in `Sources/` (counted on 22 Oct 2026), or a cited public source. A value the project does not have is written `[TBD: …]` and must stay visibly bracketed in the rendered deck until someone fills it in.
2. **No invented traction, users, revenue or team.** No logos of customers, no testimonials, no "trusted by". The team slide is deliberately absent; add one only with real names.
3. **Status honesty.** Where FG says "Needs a live check" or "Not clean", the slide says so (Browser Flows, live activities). A technical audience finds overclaiming faster than any other audience.
4. **Screenshots are real offscreen renders** from current source with sample data (FG intro). Don't retouch UI content. Crop and place only.
5. **Naming.** "Clicky" is a working name; BP §7 suggests renaming it (for example to "SparkV Assist") before launch. This deck says "Clicky (working name)" once and "Clicky" afterwards. Change it globally if the rename lands.
6. **Face Unlock is out of the commercial build.** The ArcFace weights are licensed for non-commercial use only (BP §8), so the deck mentions Face Unlock only on the roadmap slide, as a blocker.
7. **Recording scripts in §3 are for a human operator.** This blueprint was written without launching SparkV or running `build.sh`.

### Code facts used in the deck (measured 22 Oct 2026)

| Fact | Value | How measured |
| --- | --- | --- |
| Core Swift files / lines | 60 files, 29,441 lines | `Sources/*.swift`, `wc -l` |
| Labs Swift files / lines | 190 files, 79,806 lines | `Sources/Labs/**/*.swift` |
| Total app Swift | 250 files, **109,247 lines** | sum (excludes `Vendor/glance`, Node runners, ObjC adapter) |
| Labs modules | 22 folders, all compiled by `build.sh` | `ls Sources/Labs`, `cp` lines in `build.sh` |
| Drawer pages | 21 (`NotchState.Tab` cases) | `NotchState.swift` |
| Agents hub cells | 22 in an 8x3 grid | FG §8, `AgentsHubView.swift` |
| Long-lived feature objects owned by `NotchWindowController` | 31 (controllers, engines, monitors, stores) plus `NotchState` and `ActivityCenter` | property list in `NotchWindowController.swift` |
| Files importing each framework | FoundationModels 10, Vision 9, Speech 4, Translation 3, ScreenCaptureKit 5, NaturalLanguage 5, AVFoundation 13, PDFKit 6, ApplicationServices 14 | `grep -l "^import X$"` |
| Offscreen renders | 50 PNGs | `docs/screenshots` |

---

## 1. Deck system (applies to every slide)

### 1.1 Canvas and grid

| Item | Spec |
| --- | --- |
| Master canvas | **3840 x 2160 px** (16:9, UHD). PPTX equivalent 13.333 x 7.5 in; 1 in = 288 px; 1 pt = 4 px. |
| Safe margins | 192 px left/right, 160 px top, 144 px bottom (title-safe for projectors that overscan) |
| Grid | 12 columns, 64 px gutters, column = 228 px. Baseline grid 16 px. |
| Header block | Header top at y = 160. Header max width 8 columns. Subtitle 32 px below header. |
| Footer | y = 2040: left `SparkV · Technical briefing`, right slide number `NN / 16`, source line above it at y = 1984 when a slide has data. |

### 1.2 Type scale (px at 3840 wide; divide by 4 for pt)

| Role | Size / line height / weight | Tracking |
| --- | --- | --- |
| Display (slide 1 only) | 240 / 240 / 700 | -2% |
| H1 header | 128 / 140 / 650 | -1.5% |
| Subtitle | 56 / 72 / 450, `text-muted` | 0 |
| Body | 48 / 68 / 450 | 0 |
| Tile number | 144 / 144 / 650, tabular figures | -2% |
| Tile label | 36 / 48 / 500, `text-muted` | +1% |
| Code / mono | 40 / 56 / 500 | 0 |
| Caption / source | 28 / 40 / 450, `text-faint` | +1% |

Max 5 body lines per slide. Max 12 words per line of body copy.

### 1.3 Design tokens (style-agnostic)

Write every slide against these tokens. The three style demos in `docs/decks/style-demos/` already define the values, so the mapping below reuses their variable names.

| Token | Meaning | A: sparkv.si red/black | B: Apple minimal | C: Dark cyberpunk |
| --- | --- | --- | --- | --- |
| `bg` | slide background | `#09090A` (`--ink-950`) | `#F5F5F7` (`--mist`) | `#000000` (`--void`) |
| `bg-deep` | vignette / far plane | `#050506` (`--ink-990`) | `#E8E8ED` (`--page`) | `#000000` |
| `surface` | cards, tiles, table rows | `#111113` | `#FFFFFF` | `#0A0A0C` (`--panel`) |
| `surface-2` | raised card, hover | `#17171A` | `#FFFFFF` + shadow | `#111114` (`--panel-2`) |
| `line` | hairlines, borders | `rgba(255,255,255,.10)` | `#D2D2D7` (`--hairline`) | `#26262B` |
| `text` | primary text | `#FFFFFF` | `#1D1D1F` (`--ink`) | `#F2F2F4` |
| `text-muted` | subtitles, labels | `#A0A0A3` | `#6E6E73` | `#A1A1AA` |
| `text-faint` | captions, sources | `#808088` | `#86868B` | `#6B6B74` |
| `accent` | one key thing per slide | `#F01822` (`--red`) | `#F01822` (used sparingly) | `#FF1E2D` (`--neon`) |
| `accent-text` | accent used as text on dark | `#F8262F` | `#F01822` | `#FF1E2D` |
| `accent-soft` | secondary series, chips | `#FF8A90` | `#AEAEB2` (`--bar`) | `#8A0F18` (`--neon-deep`) |
| `glow` | light bloom behind hero objects | `rgba(240,24,34,.16)` | none (use shadow `0 40px 80px rgba(0,0,0,.18)`) | `rgba(255,30,45,.45)` + `rgba(0,229,255,.28)` chromatic edge |
| `ok` | pass / allowed | `#57D791` (from sparkv.si CSS) | `#248A3D` | `#57D791` |
| `notch` | the island and bezel | `#000000` in every style | `#0A0A0C` bezel (`--bezel`) | `#000000` |
| Fonts | display / body / mono | system sans (SF Pro) / system sans / `ui-monospace` (SF Mono) | SF Pro Display / SF Pro Text / SF Mono | Chakra Petch / Inter / JetBrains Mono |

Fixed semantic colours (same in all styles, because they appear inside the real UI): severity critical `#E5484D`, high `#F59E0B`, medium `#EAB308`, low `#3B82F6`. In style A the accent red and "critical" red are close; on slide 8 make the critical bar the accent and set high/medium/low in their semantic colours at 80% opacity.

**Where the styles differ (global):**
- **A, sparkv.si red/black:** near-black flat panels, one red accent per slide, soft red glow (16%) behind the hero object only, mono labels in caps (`SYSTEM MODEL` style, as on sparkv.si). Hairline borders, no gradients except the glow.
- **B, Apple minimal:** light mist background so the dark renders read as product photography. No glow; a large soft drop shadow under each device. Red appears only on data highlights. Generous whitespace: content occupies at most 60% of the slide area.
- **C, Dark cyberpunk:** pure black, a 64 px grid at 4% opacity, neon red with a 1–2 px cyan chromatic offset on headers and chart highlights, optional 2% scanline overlay. Mono everywhere except body copy. Never put scanlines over screenshots.

### 1.4 Components

**NotchFrame (screenshots in notch mockups).** Drawer and band renders (1224 px wide, 2x of 612 pt) sit inside the top edge of a stylised MacBook display:
- Bezel: `notch` colour, 28 px thick at 3840 scale, outer corner radius 56 px, cropped so only the top 30–45% of a lid shows.
- Screen area: the render's own navy desktop gradient continues to the bezel; extend it with `#2A2E43 → #171925 → #0F1119` (the apple-minimal demo's `--scr-*` values) so there is no seam.
- Place the render top-aligned to the inner bezel, horizontally centred. The island in the render must touch the bezel top edge (that is where the hardware notch is).
- **Upscale limit:** static renders may be scaled to at most **150%** (1224 → 1836 px). Anything bigger uses a frame from the 4K recordings in §3.
- Generic laptop silhouette only. No Apple logo, no Apple product photography.

**WindowFrame (full windows).** Renders of windows (UI Audit, Browser Flows, Flow Canvas, Meeting notes, Setup) get a 1 px `line` border, 24 px corner radius, and shadow `0 48px 120px rgba(0,0,0,.55)` (A, C) or `0 40px 80px rgba(0,0,0,.18)` (B). Scale ≤ 150%.

**Tile (metrics).** `surface` card, 40 px radius, 64 px padding, number in Tile number style, label below, optional source footnote marker `¹`.

**Chart style.** Flat bars, no 3D, no gridlines except a 2 px baseline in `line`. Direct labels on bars in mono. Highlight series = `accent`; other series = `text-muted` at 45% (A, C) or `--bar` `#AEAEB2` (B). Every chart has a source line in caption style. A `[TBD]` value renders as a hatched outline bar with the label `[TBD]`, never as a number.

**Diagram style.** Boxes are `surface` with 2 px `line` borders, 24 px radius; arrows 4 px `text-muted`; the one box being discussed gets an `accent` border and `glow`.

---

## 2. Complete outline (16 slides)

Layout types used: key visual header (1), metrics dashboard (2, 5, 11), feature showcase with screenshot (3, 4, 6, 8, 9, 10), minimal body (7), 2-column comparison (12, 14), pricing table (13), timeline (15), CTA (16).

---

### Slide 1: Title
- **Layout:** key visual header
- **Header:** SparkV
- **Subtitle:** The MacBook notch, rebuilt as an on-device AI runtime
- **Body:**
  - Native Swift · AppKit + SwiftUI · macOS 15+ · Apple silicon
  - Technical briefing for developers and partners · October 2026
  - sparkv.si
- **Images:** `screenshots/01-home.png` in NotchFrame (hero). Motion version: recording R1, crop B.
- **Speaker notes:** SparkV turns the MacBook notch into a control surface: hover the notch and a drawer slides out with media, a file tray, your day, converters, knowledge Spaces and a hub of more than twenty agents. This talk is about how it's built: the window, the activity engine, the on-device AI stack, the privacy model, the developer agents and how we build and ship. Every picture you'll see is a real render from the current source code, not a mock-up. Where something still needs a live check, I'll say so.
- **Art direction:**
  - Composition: header block left (columns 1–6), vertically centred at y ≈ 900. NotchFrame hero on the right two thirds, bleeding off the top edge so the lid reads as "the top of your screen". Render scaled 150% (1836 px wide), island centred at x = 2560.
  - Tokens: `bg`; header in `text`; subtitle `text-muted`; "sparkv.si" in mono `accent-text`; `glow` ellipse 1800 x 700 px behind the drawer, centred on the album-art glow.
  - A: red bloom at 16%, everything else flat. B: mist background, the lid as a black object with a long soft shadow; no bloom; header in ink. C: black, 64 px grid, header with cyan offset, a thin neon underline under "SparkV"; the bloom becomes a red/cyan split glow.

---

### Slide 2: The codebase at a glance
- **Layout:** metrics dashboard
- **Header:** The codebase at a glance
- **Subtitle:** Counted from Sources/ on 22 October 2026
- **Body (tiles):**
  - 109,247 · lines of Swift
  - 250 · source files
  - 22 · Labs feature modules
  - 21 · drawer pages
  - 10 · files on FoundationModels
  - $0 · AI cost per user
- **Footnote:** Excludes vendored GlanceKit, the Node runners and the Now Playing adapter.
- **Chart:** horizontal bar chart "Swift lines per Labs module" (data table below). Highlight UIAudit, BrowserRecorder and FlowCanvas in `accent` (they are the agents of slides 8–10).

| Labs module | Swift lines |
| --- | --- |
| Spaces | 9,644 |
| FlowCanvas | 6,919 |
| Modes | 5,652 |
| JobAgent | 5,300 |
| Clipboard | 5,244 |
| Focus | 4,192 |
| ReplyDrafter | 4,140 |
| UniversalSearch | 3,674 |
| Converter | 3,571 |
| Downloads | 3,481 |
| ScreenRegion | 3,459 |
| PromptRefiner | 3,112 |
| BrowserRecorder | 2,859 |
| Widgets | 2,829 |
| FileDropActions | 2,815 |
| LiveTranslation | 2,374 |
| UIAudit (Swift side; runner is Node) | 2,192 |
| ScreenDistance | 2,187 |
| Onboarding | 1,987 |
| QuickCapture | 1,741 |
| ScreenRecorder | 1,448 |
| Media | 986 |

Source: `wc -l Sources/Labs/<module>/*.swift`, 22 Oct 2026.

- **Images:** none.
- **Speaker notes:** About 109 thousand lines of Swift: 29 thousand in the core (window, activities, media, dictation, meetings, Clicky) and 80 thousand in 22 Labs modules. AI cost per user is zero because inference runs on the buyer's Mac; a cloud model is only used with the buyer's own key. Line counts are a size signal, not a quality claim; the quality evidence is on the testing slide.
- **Art direction:**
  - Composition: 3 x 2 tile grid on the left 7 columns (tiles 548 x 420 px), chart on the right 5 columns, 22 bars at 44 px each with 20 px gaps.
  - Tokens: tiles `surface`; numbers `text`, the "$0" number in `accent-text`; chart bars `text-muted` 45%, three highlighted bars `accent`.
  - A: tiles flat with 1 px `line`; mono labels in caps. B: white tiles, no borders, shadow `0 8px 24px rgba(0,0,0,.06)`; bars `#AEAEB2`, highlight red. C: tiles with a 1 px neon top border, numbers in Chakra Petch, chart labels in JetBrains Mono, highlight bars with a 12 px neon glow.

---

### Slide 3: One panel, thirty-one feature objects
- **Layout:** feature showcase with screenshot (architecture diagram + screenshot)
- **Header:** One panel, thirty-one feature objects
- **Subtitle:** How a non-activating NSPanel becomes a command center
- **Body:**
  - NotchPanel: borderless, non-activating, `.statusBar` level, on every Space
  - Click-through at rest; becomes key only when a control needs it
  - NotchWindowController owns the controllers and one shared ActivityCenter
  - Features live in `Sources/Labs/<Feature>/` with DESIGN.md and INTEGRATION.md
- **Diagram (build as native shapes):**
  ```
  NotchPanel (NSPanel: .borderless + .nonactivatingPanel, level .statusBar,
              .canJoinAllSpaces + .fullScreenAuxiliary, ignoresMouseEvents at rest)
     └─ NotchHostingView (acceptsFirstMouse) ─ NotchNookLayoutView
           ├─ header: 6 tabs left · Focus, Record, Agents hub, Flow, Clicky, gear right
           └─ 21 drawer pages (NotchState.Tab) · AgentsHubView: 22 tiles
  NotchWindowController
     ├─ NotchState · ActivityCenter (shared queue for every live activity)
     ├─ core: MediaEngine, DictationController, ClickyController, HUDController,
     │        TimerController, MeetingsController, MeetingAssistant, …
     └─ Labs: Converter, Spaces, UIAudit, BrowserRecorder, FlowCanvas, Clipboard, … (22)
  Labs contract: DESIGN.md (research + decisions) → INTEGRATION.md (wiring steps)
                 → one `cp Sources/Labs/X/*.swift` line in build.sh
                 → lead wires the shared files (NotchState, NotchWindowController,
                    NotchNookLayoutView, AgentsHubView)
  ```
- **Images:** `screenshots/10-agents-hub.png` in NotchFrame (right column). Motion: R2, crop C.
- **Speaker notes:** The whole app is one borderless, non-activating panel at status-bar level. It joins every Space, including full-screen apps, never steals focus, and lets clicks fall through while the island is closed. AppKit normally pushes windows below the menu bar, so the panel overrides `constrainFrameRect` to sit at the absolute top edge. The window controller owns 31 long-lived feature objects plus the shared ActivityCenter. New features are built in isolation in a Labs folder: a DESIGN.md with the research and decisions, an INTEGRATION.md with exact wiring steps, then one copy line in build.sh. Only the lead touches the four shared files, which is what let us build features in parallel without merge fights.
- **Art direction:**
  - Composition: diagram on the left 7 columns (native shapes, mono labels), NotchFrame with the hub on the right 5 columns, 120% scale. A thin connector line from the diagram's "AgentsHubView" box to the screenshot.
  - Tokens: diagram boxes `surface`, the NotchPanel box with `accent` border + `glow`; code identifiers in mono `text`; contract row in `text-muted`.
  - A: flat boxes, red only on NotchPanel. B: white boxes with hairlines, the diagram is the only "busy" element, so give it 160 px of air. C: boxes as HUD panels with corner ticks, arrows animate as a travelling neon dash (if exported to video).

---

### Slide 4: Live activities with Dynamic Island rules
- **Layout:** feature showcase with screenshot
- **Header:** Live activities with Dynamic Island rules
- **Subtitle:** A priority queue that never covers your work
- **Body:**
  - Compact wings grow sideways inside the menu bar, 30–112 pt per side
  - Alerts of 8 s or less queue by priority; time runs only on screen
  - Preempted alerts resume; anything waiting 12 s is dropped
  - Persistent activities peek for 4 s, then rest in the wings
- **Images (strip of bands, each in a mini NotchFrame, 100% scale):** `screenshots/46-compact-wings.png`, `42-volume-hud.png`, `43-battery.png`, `44-airpods.png`, `45-notification.png`, `47-screen-recording.png`. Motion: R3, crop B (bands) and crop D (wings).
- **Status line (caption):** Bands render from source; key interception, banners and Bluetooth need a live check.
- **Speaker notes:** The closed island follows Dynamic Island rules. Compact activities grow sideways inside the menu-bar height, so nothing below the menu bar is covered. Short alerts go into a priority queue whose clock only runs while they're visible, so a notification can't eat the charging alert. Volume and brightness are live feedback: newest wins and they're never replayed. Long-running things like a timer, a meeting or a recording peek in the band for four seconds and then tuck into the wings. All of this is one `ActivityCenter`, and every feature posts a `LiveActivity` with a priority, an optional compact form and a tab to open on hover. Honest status: the bands render from source, but key interception, banners and AirPods need the running app to confirm.
- **Art direction:**
  - Composition: body on the left 5 columns; on the right a vertical stack of six mini NotchFrames (each 1224 x 180 at 100% → height 180 px plus bezel), 32 px apart, with a mono priority label at the right of each ("volume · live", "battery · 8 s", …). The wings frame (46) on top, highlighted.
  - Tokens: frames `notch`; labels `text-faint`; highlighted frame gets `glow`.
  - A: one red tick mark next to the highlighted frame. B: frames sit on white cards with shadows; labels ink-2. C: each frame gets a scanning neon line passing left to right (video export only); labels in JetBrains Mono caps.

---

### Slide 5: The on-device AI stack
- **Layout:** metrics dashboard
- **Header:** The on-device AI stack
- **Subtitle:** Apple frameworks first; the network is opt-in
- **Body (tiles):**
  - FoundationModels · dictation cleanup, summaries, replies, prompts, plans
  - Vision · OCR everywhere, face landmarks for Screen Distance
  - Speech · SpeechAnalyzer on macOS 26+, SFSpeechRecognizer fallback
  - Translation · TranslationSession cached per language pair
  - ScreenCaptureKit · stills for Ask Screen, SCStream audio for meetings
  - NaturalLanguage · language ID and entities for Spaces
- **Chart:** column chart "Source files importing each framework".

| Framework | Files |
| --- | --- |
| ApplicationServices | 14 |
| AVFoundation | 13 |
| FoundationModels | 10 |
| Vision | 9 |
| PDFKit | 6 |
| ScreenCaptureKit | 5 |
| NaturalLanguage | 5 |
| Speech | 4 |
| Translation | 3 |

Source: `grep -l "^import <Framework>$"` over `Sources/`, 22 Oct 2026.

- **Images:** none (tiles + chart).
- **Speaker notes:** Ten files use the on-device Apple Intelligence model through FoundationModels: Tray AI, Clicky, dictation formatting, meeting summaries and answers, Reply Drafter, Prompt Refiner, Live Translation's fallback, Ask Screen, Flow Canvas and Downloads. One constraint shaped the code: we build with the Command Line Tools only, and the `@Generable` macro plugin isn't part of them, so guided generation uses `DynamicGenerationSchema` built at runtime. The model has a 4096-token context, so meeting transcripts are chunked. Speech uses the new SpeechAnalyzer and SpeechTranscriber on macOS 26 and falls back to SFSpeechRecognizer. ScreenCaptureKit gives us stills with SparkV's own windows excluded, and an SCStream with `capturesAudio` for meeting audio, which is why no bot has to join a call.
- **Art direction:**
  - Composition: 3 x 2 tiles left (framework name as the tile number in 88 px semibold, purpose as label), column chart right. FoundationModels tile is the accent tile.
  - Tokens: accent tile border `accent` + `glow`; chart highlight FoundationModels, Vision, Speech, Translation, ScreenCaptureKit, NaturalLanguage in `accent` (AI frameworks); ApplicationServices, AVFoundation, PDFKit in `text-muted`.
  - A: flat, red accent on one tile. B: white tiles, framework names in ink, no icons. C: tiles as terminal panes with a blinking cursor after the name; chart columns with neon caps.

---

### Slide 6: AI in the loop: speech, meetings, translation
- **Layout:** feature showcase with screenshot
- **Header:** AI in the loop
- **Subtitle:** Speech in, structured text out, on the Mac
- **Body:**
  - Dictation: hold fn → on-device transcript → cleanup → typed at the cursor
  - Meetings: mic plus system audio, no bot joins, guided JSON summaries
  - Translation order: Apple Translation → on-device model → Groq if allowed
  - Warm translation: 0.33–0.8 s per caption
- **Images:** `screenshots/50-dictation.png` (NotchFrame, top), `37-meeting-live-answers.png` (WindowFrame, centre), `38-live-translation.png` (caption panel, overlapping lower right). Motion: R4 (dictation) and R5 (meeting + translation).
- **Chart:** small range chart "Apple Translation latency, measured on macOS 27".

| Request | Low (s) | High (s) |
| --- | --- | --- |
| Cold session (es→en) | 1.8 | 2.8 |
| Warm session, per caption | 0.33 | 0.8 |

Source: `Sources/Labs/LiveTranslation/DESIGN.md`, measured on the development Mac.

- **Status line:** Audio capture and the fn key need a live check; views render from saved data.
- **Speaker notes:** Three pipelines share one pattern: capture on device, recognise on device, structure with the on-device model. Dictation formats text with a prewarmed LanguageModelSession so the cleanup is fast when you release fn. Meetings record your mic and the meeting's audio through ScreenCaptureKit, transcribe on device and produce minutes, decisions and your tasks as guided JSON. Live Translation tries Apple Translation first, falls back to the on-device model when a language pair isn't downloaded, and uses Groq only if the user turned on that specific toggle. Cold sessions take two to three seconds; warm ones under a second per caption, which is why sessions are cached per pair.
- **Art direction:**
  - Composition: left 5 columns body + latency range chart under it (2 horizontal range bars). Right 7 columns: layered collage, meeting window at 85% scale as the base, dictation band floating above at top, caption panel overlapping its lower right corner with a 32 px offset shadow.
  - Tokens: range bars `accent` (warm) and `text-muted` (cold); collage shadows per WindowFrame.
  - A: collage sits on a faint red glow. B: collage on white with three distinct shadows, no glow; generous spacing so windows barely overlap. C: windows tilted 0° (no 3D), cyan aberration on the caption panel edge only.

---

### Slide 7: Private by default
- **Layout:** minimal body
- **Header:** Private by default
- **Subtitle:** Nothing leaves the Mac unless the user brings a key
- **Body:**
  - On device: speech, camera, screenshots, clipboard, Spaces, meeting audio
  - Groq: per-feature toggle, off by default, the buyer's own key
  - While a toggle is off, the keychain is never read
  - Clipboard history starts off; concealed and transient copies are skipped
  - 12 permissions, each asked only when the user clicks Allow
- **Images:** `screenshots/41-onboarding-permissions.png` in WindowFrame, small (right 4 columns, 70% scale). Motion: R6.
- **Speaker notes:** The privacy model is simple to state and easy to audit. Speech, camera, screen captures, clipboard, Spaces and meeting audio stay on the Mac. Groq is the only cloud path, and it's opt-in per feature: Clicky, Tray AI, meetings, Live Translation, Flow Canvas and UI Audit summaries each have their own switch, default off, using the buyer's own key. When a switch is off the code doesn't even read the keychain item. Clipboard history is off until you turn it on, and it honours the pasteboard conventions password managers use to mark concealed or transient copies. Setup asks for nothing up front: each of the 12 permissions is requested only when you click Allow, and every feature works in a reduced way without it. License checks, when they ship, will send the key, an anonymous device ID and the app version to Lemon Squeezy, and nothing else. There are no analytics.
- **Art direction:**
  - Composition: big header (H1 at 160 px for this slide), five short lines with generous 96 px leading, screenshot small and quiet on the right. 50% of the slide is empty.
  - Tokens: one word in `accent-text`: "unless" in the subtitle. Everything else `text`/`text-muted`.
  - A: no glow on this slide; the restraint is the message. B: the most "Apple" slide; ink on mist, screenshot with soft shadow. C: replace the screenshot frame with a thin neon outline; add a small mono tag `LOCAL_ONLY=true` top right.

---

### Slide 8: UI Audit, a QA agent for your own site
- **Layout:** feature showcase with screenshot
- **Header:** UI Audit: a QA agent for your own site
- **Subtitle:** Playwright and axe-core, started from the notch
- **Body:**
  - Swift spawns `node audit.mjs`: JSON lines out; pause, resume, stop in
  - Crawl, forms, axe-core WCAG 2.2 AA, 1440/390 px layout, Tab order
  - Origin allow-list; writes blocked off test hosts; risky clicks skipped
  - **P** copies a fix prompt for Claude Code, Cursor or Copilot
- **Metric strip (under body):** 6 pages · 69 findings · 51,666-char fix prompt · self-test 48/48
- **Images:** `screenshots/22-ui-audit-window.png` (WindowFrame, hero, right), `screenshots/21-ui-audit.png` (NotchFrame, small, above the window: "started from the notch"). Motion: R7, crop G.
- **Chart:** bar chart "Findings by severity, planted-issue test site".

| Severity | Findings |
| --- | --- |
| Critical | 3 |
| High | 15 |
| Medium | 34 |
| Low | 17 |

Source: FG §25 (end-to-end run through `UIAuditController` on 127.0.0.1, 6 pages, 69 findings); medium/low split from the run's status badges in `22-ui-audit-window.png`.

- **Speaker notes:** UI Audit audits websites you own. The Swift controller writes a run config, starts a Node runner with Playwright and axe-core, and talks to it over JSON lines: plan, page, step and finding events come out; pause, resume and stop go in. If the app dies, stdin closes and the runner stops, so you never leak a crawler. The runner crawls, checks layout at 1440 and 390 pixels, walks the Tab order, runs axe-core for WCAG 2.2 A and AA, and fills forms with type-correct test data. The safety model is strict: navigation outside the allowed origins is aborted, every non-GET request is blocked unless the host is local or test or you opt in for this run, and anything that looks like pay, delete or log out is never clicked. The numbers are from a real end-to-end run against our planted-issue test site: 69 findings, an on-device summary, and a 51,666-character fix prompt. The runner's own self-test passes 48 of 48, including the checks that it never hit the logout or delete URLs. It needs Node 20 and Playwright's Chromium on the machine today.
- **Art direction:**
  - Composition: window at 120% (2592 x 1728) anchored bottom-right, bleeding 96 px off the right edge; drawer render small (100%) floating over the window's top-left corner with a connector "starts here". Body + metric strip + severity chart in the left 4 columns.
  - Tokens: severity colours fixed; critical bar `accent` in A; metric strip numbers mono `text`, separators `text-faint`.
  - A: red glow behind the P button area of the window (bottom-right). B: no glow; draw a 4 px red ring around the P button. C: a neon scan line across the findings list; the P button gets a cyan offset glow.

---

### Slide 9: Browser Flows, record once and replay with data
- **Layout:** feature showcase with screenshot
- **Header:** Browser Flows: record once, replay with data
- **Subtitle:** Self-healing selectors; secrets are never stored
- **Body:**
  - Each step stores ranked selectors and an element fingerprint
  - Healing accepts a match of 0.6 or more that clearly beats the runner-up
  - Passwords become `{{password}}`, asked at replay, sent over stdin
  - CSV loop: one replay per row, up to 500 rows
- **Status line (visible, caption style with a `text-muted` dot):** Self-test not yet clean under load: one replay timed out, one CSV loop hung. Fix before launch.
- **Images:** `screenshots/26-browser-flows-window.png` (WindowFrame, hero), `screenshots/25-browser-flows.png` (NotchFrame, small). Motion: R8, crop H.
- **Speaker notes:** Browser Flows records a browser task once and replays it. Each recorded step keeps an ordered list of selectors, in the spirit of Selenium IDE's targets list, plus a fingerprint of the element: tag, role, accessible name, text, attributes and ancestor path. When every selector fails, the runner scores all elements against the fingerprint and accepts the best one only if it scores at least 0.6 and clearly beats the runner-up, then writes the healed selector first. Password, card, CVV, OTP and SSN fields are never read: they become variables and are passed over stdin at replay, never on the command line. Flows that mention purchase, payment or delete need an explicit confirmation. Honest status: the recorder self-test isn't clean yet; under heavy load one replay timed out and a CSV loop hung. That's on the roadmap before launch.
- **Art direction:**
  - Composition: mirror of slide 8 (window bottom-left, body right) so 8 and 9 read as a pair. Highlight the "masked" chip on step 4 of the render with an annotation callout "never saved".
  - Tokens: callout line 3 px `accent`, label mono `accent-text`; status dot `text-muted` (not red: it's a known issue, not an alarm).
  - A: callout in red. B: callout as a thin ink line with a red dot at its end. C: callout as a neon bracket.

---

### Slide 10: Flow Canvas, workflows as a graph
- **Layout:** feature showcase with screenshot
- **Header:** Flow Canvas: workflows as a graph
- **Subtitle:** Sources in, actions chained, run on this Mac
- **Body:**
  - Drop links, PDFs, screenshots and notes as source cards
  - Chain extract, compare, summarize, report and chat-with-sources
  - "Suggest steps" plans the chain from one sentence
  - Export to Markdown, PDF, CSV, Tray, Notes or a Space
- **Images:** `screenshots/35-flow-canvas.png` (WindowFrame, full-bleed hero). Motion: R9, full frame.
- **Speaker notes:** Flow Canvas is a whiteboard for AI workflows. Source cards hold links, PDFs, screenshots or notes; action cards extract fields, compare, summarize or write a report; edges carry data between them, and Run all executes the graph. You can also describe the goal in one sentence and Suggest steps builds the chain. It ships with four templates, including the competitor pricing comparison you see here. The engine indicator top right says "On this Mac": FoundationModels, Vision OCR and Apple Translation do the work. Groq is a separate opt-in for this feature only. Canvases are plain versioned JSON in Application Support, and dropped files are copied into the canvas's assets folder; originals are never moved.
- **Art direction:**
  - Composition: the canvas render at 140% (3696 px wide) full-bleed behind a dark gradient scrim on the left 40% that carries header and body. Let the green edges of the graph run under the scrim.
  - Tokens: scrim `bg` 0% → 92% left-to-right reversed; body `text`.
  - A: keep the render's own green edges (don't recolour UI). Add a red glow behind the "Run all" button. B: no scrim; place the render as a WindowFrame at 100% on mist, header above it. C: scrim with a 64 px grid, glow on Run all in neon red with cyan edge.

---

### Slide 11: Engineering practices
- **Layout:** metrics dashboard
- **Header:** Engineering practices
- **Subtitle:** A small toolchain and strict habits
- **Body (tiles):**
  - CLT-only · one zsh build script, no Xcode project required
  - No macro plugins · no @State, #Preview, @Entry, @Generable
  - Temp-dir builds · iCloud can't modify files mid-compile
  - Stable signing · permission grants survive every rebuild
  - Hardened Runtime · explicit camera, mic, calendar, Apple Events entitlements
  - Real-source harnesses · Swift 5 and 6, private pasteboards
- **Chart:** horizontal bar chart, log scale, "Harness checks passing on 22 Oct 2026".

| Harness | Passing checks | Result |
| --- | --- | --- |
| Widgets (clocks, time zones, knob, habits, gauges, network) | 29,283 | 0 fail |
| Clipboard history + paste stack | 195 | 0 fail |
| Copy Text OCR + screen recorder | 63 | 0 fail |
| UI Audit runner self-test | 48 | 48/48 |
| Browser Flows recorder self-test | — | not clean (shown as a hatched bar labelled "not clean") |

Source: FG "Verification summary".

- **Speaker notes:** We build with the Command Line Tools only. `build.sh` copies sources into a temp folder, compiles GlanceKit as a static library with its own concurrency settings, compiles the app, builds the Now Playing adapter framework with clang, signs nested code first and then the app with the Hardened Runtime. The temp folder exists because the project lives on iCloud Desktop, which touches files mid-build and adds Finder attributes codesign rejects. No Xcode means no macro plugins, so the code avoids `@State`, `#Preview`, `@Entry` and `@Generable`. A stable self-signed identity, "NotchIsland Developer", gives every build the same designated requirement, so Accessibility and Screen Recording grants survive rebuilds. Tests are harnesses that compile the real app sources, for example the clipboard harness runs against private named pasteboards, never the general one, in both Swift 5 and Swift 6 modes. The log scale is there because the widget harness sweeps time zones and has far more checks than the others; don't read it as a coverage ranking.
- **Art direction:**
  - Composition: 3 x 2 tiles left with the tile "number" being the short label (CLT-only, No macro plugins…) at 72 px; log-scale bar chart right with tick labels 10, 100, 1k, 10k, 100k.
  - Tokens: pass bars `ok`; Browser Flows hatched `text-faint`; tile titles `text`, descriptions `text-muted`.
  - A: one tile, "Stable signing", gets the red accent border. B: plain; pass bars in `#248A3D`. C: tiles as terminal panes showing a fake-free real command (`./build.sh` → `Signed with: NotchIsland Developer`, which is the script's real log line).

---

### Slide 12: Shipping outside the Mac App Store
- **Layout:** 2-column comparison
- **Header:** Shipping outside the Mac App Store
- **Subtitle:** What the sandbox blocks, and the release pipeline we're adding
- **Left column, "Why not the App Store":**
  - Accessibility APIs don't work in the App Sandbox
  - Event taps and `CGEvent.post` for fn, media keys and paste
  - Private DisplayServices and MediaRemote (via `/usr/bin/perl`)
  - Spawning Node, Playwright and `/usr/bin/shortcuts`
- **Right column, "Developer ID pipeline (planned)":**
  - Developer ID Application cert replaces the local identity
  - Sign nested code with `--options runtime --timestamp`
  - `notarytool submit --wait`, then `stapler staple`
  - Sparkle 2 updates with an EdDSA-signed appcast
  - Lemon Squeezy License API: activate, validate, deactivate
- **Images:** none.
- **Speaker notes:** SparkV can't be sandboxed. Apple's DTS says Accessibility APIs aren't compatible with the App Sandbox, and we also need event taps for the fn key, posted key events for paste, private DisplayServices for the HUD, the MediaRemote adapter for Now Playing, and child processes for Node and Shortcuts. NotchNook stays off the App Store for the same MediaRemote reason. So we ship direct: a Developer ID certificate replaces today's local identity, every nested binary is signed with the Hardened Runtime and a secure timestamp, the DMG is notarized and stapled, and Sparkle 2 delivers updates from a signed appcast. Since Sequoia, an un-notarized app can't be opened with right-click Open, so notarization isn't optional for a paid product. The local identity stays for development builds. Sources for the sandbox constraints are in BP §5.
- **Art direction:**
  - Composition: two equal columns (6 + 6) separated by a 2 px `line` divider; left list prefixed with a small "×" glyph in `text-faint`, right list with numbered steps 1–5 in mono `accent-text` (it's a pipeline). Optional thin arrow under the right column running 1 → 5.
  - Tokens: left header `text-muted`, right header `text`; step numbers `accent-text`.
  - A: right column on `surface`. B: both on mist; right numbers in red. C: right column as a pipeline of HUD chips connected by a neon line.

---

### Slide 13: Pricing built on zero AI cost
- **Layout:** pricing table
- **Header:** Pricing built on zero AI cost
- **Subtitle:** One-time Pro, because inference runs on the buyer's Mac
- **Table:**

| | Free | Pro (recommended) | Team |
| --- | --- | --- | --- |
| Price | $0 | **$39 one-time** · launch $29 | **$8 per seat per month**, billed yearly |
| India | ₹0 | ₹1,499 · launch ₹999 | ₹499 per seat per month |
| Updates | — | 12 months included, optional $19/yr renewal | included |
| Notch core | Media, HUD, battery, tray, timer, Today | Everything | Everything |
| AI assistants | Dictation without AI formatting | Dictation with AI, Clicky, Ask Screen, Reply Drafter, Prompt Refiner, Tray AI, Job Agent | Everything |
| Developer tools | — | UI Audit, Browser Flows, Flow Canvas | Everything |
| Extras | — | 14-day trial, no card · 2 Macs | Invoice, seat management, MDM .pkg · min 3 seats |

- **Chart (small, right of or under the table):** "Net per sale after merchant-of-record fees".

| Item | List price | Fee (5% + $0.50) | Net to SparkV |
| --- | --- | --- | --- |
| Pro, student (50% off) | $19.50 | $1.48 | $18.03 |
| Pro, launch | $29.00 | $1.95 | $27.05 |
| Pro | $39.00 | $2.45 | $36.55 |
| Team, per seat-year | $96.00 | $5.78 (incl. +0.5% subscription) | $90.22 |

Source: derived from BP §4 Lemon Squeezy fees (5% + 50¢, +0.5% on subscriptions). Excludes the ~1.5% non-US surcharge and payout fees.

- **Revenue scenario (table only, no chart until filled):** Pro units [TBD] x $36.55 + Team seats [TBD] x $90.22 = year-one revenue [TBD]. Do not draw this chart with invented values.
- **Alternative (footnote):** Per-pack pricing ($9–$19 per pack, "Everything" = Pro) is designed but not launched (BP §6b).
- **Speaker notes:** For partners, the business model matters because it's shaped by the architecture. We pay nothing per user for AI, so we can charge once instead of monthly. Pro is $39 one-time with a $29 launch price, ₹1,499 in India. Team is $8 per seat per month billed yearly. Developer tools sit in Pro. After merchant-of-record fees we keep about $36.55 of a $39 sale. We don't have sales yet, so there's no revenue chart with numbers; the scenario row stays a placeholder until we do.
- **Art direction:**
  - Composition: table across 8 columns, Pro column raised: `surface-2`, 8 px `accent` top border, "Recommended" chip. Net-per-sale bars in the right 4 columns.
  - Tokens: prices in Tile-number style at 96 px; row labels `text-muted`; table lines `line`.
  - A: Pro column with red glow at 10%. B: white cards per column, Pro with a red "Recommended" text label, no glow. C: Pro column with neon border and corner ticks; prices in Chakra Petch.

---

### Slide 14: One app, not a six-app stack
- **Layout:** 2-column comparison
- **Header:** One app, not a six-app stack
- **Subtitle:** Comparable tools, and the platform SparkV runs on
- **Left column, chart: "First-year cost of comparable tools (USD)":**

| Product | Category | First-year cost | Basis | Source (BP §3) |
| --- | --- | --- | --- | --- |
| Granola Business | Meeting notes | 168.00 | $14/user/mo x 12 | granola.ai |
| Wispr Flow Pro | Dictation | 144.00 | $144/yr | getvoibe.com |
| Raycast Pro | Launcher + AI | 96.00 | $8/mo billed yearly | raycast.com blog |
| Paste | Clipboard | 29.99 | $29.99/yr | App Store |
| CleanShot X | Screenshots | 29.00 | one-time, 1 yr updates | toolradar |
| NotchNook | Notch hub | 25.00 | one-time | iMore |
| **Stack total** | | **491.99** | | |
| **SparkV Pro** | all of the above categories | **39.00** (launch 29.00) | one-time | BP §6a |

Footnote: Overlap is by category, not feature parity. Prices are third-party listings; check vendor pages before quoting publicly.

- **Right column, chart: "Apple's active installed base":**

| Date | Active Apple devices (billions) | Source |
| --- | --- | --- |
| Jan 2024 | 2.20 | Apple FQ1 2025 call, prior-year figure ([supportplan.com](https://supportplan.com/apple-has-more-than-2-35-billion-active-devices-up-550-million-since-2022)) |
| Jan 2025 | 2.35 | Apple FQ1 2025 earnings call ([supportplan.com](https://supportplan.com/apple-has-more-than-2-35-billion-active-devices-up-550-million-since-2022)) |
| Jan 2026 | 2.50 | Apple FQ1 2026 earnings call ([9to5Mac](https://9to5mac.com/2026/01/29/apple-reveals-it-has-2-5-billion-active-devices-around-the-world/)) |

Plus three stat lines under the chart:
  - Mac active base: 100M+ (Apple, October 2018; latest Mac-only figure Apple published, [AppleInsider](https://forums.appleinsider.com/discussion/208001))
  - Notched Apple-silicon MacBooks on macOS 15+: [TBD: sourced estimate]
  - SparkV waitlist / users: [TBD: monthly active users]

- **Speaker notes:** A buyer who wants what SparkV does would otherwise assemble a stack: a notch app, a clipboard manager, dictation, meeting notes, a launcher with AI and a screenshot tool. Year one of that stack is about $490; SparkV Pro is $39. That's a category comparison, not a claim that every feature matches. On the right, platform context: Apple reports 2.5 billion active devices across all products. Apple hasn't published a Mac-only figure since "over 100 million" in 2018, so the number we actually need, notched MacBooks on macOS 15 or later, is marked to be sourced. We have no user numbers to show yet.
- **Art direction:**
  - Composition: left 7 columns: horizontal bars sorted descending, a gap, then the SparkV bar in `accent` with the label "$39". A bracket spanning the six competitor bars labelled "$491.99". Right 5 columns: three-column chart, then three stat lines, the two `[TBD]` lines in hatched outline chips.
  - Tokens: competitor bars `text-muted` 45%; SparkV `accent`; TBD chips `text-faint` dashed border.
  - A: SparkV bar with glow. B: competitor bars `#AEAEB2`, SparkV red, no glow. C: SparkV bar neon with cyan edge; installed-base columns drawn as wireframe.

---

### Slide 15: Roadmap
- **Layout:** timeline
- **Header:** Roadmap
- **Subtitle:** From a local build to a notarized 1.0 in 30 days
- **Timeline (days from start, start date [TBD: launch kickoff date]):**
  - Days 1–3 · Developer ID cert, Lemon Squeezy products, domain
  - Days 4–7 · Face Unlock out of the sold build (ArcFace is non-commercial); acknowledgements; legal pages
  - Days 8–12 · Licensing, trial and gating in `Labs/Licensing`; Sparkle; notarized DMG
  - Days 13–15 · Clean-Mac test: Gatekeeper, onboarding, trial, key, 1.0 → 1.0.1 update
  - Days 16–25 · Landing page, demo video, private beta of 30–50 users
  - Days 26–27 · Ship 1.0, launch price on, Product Hunt
  - Days 28–30 · 1.0.1 through Sparkle, Show HN, affiliates
- **After 1.0 (second row):** Fix the Browser Flows self-test · Decide: bundle a signed Node (+40–100 MB) or require it · Feature packs · Setapp (month 3+) · Spaces live sync (not built yet; today Spaces share as `.sparkvspace` packages)
- **Speaker notes:** The launch plan is thirty days. The engineering-heavy parts are days 8 to 15: licensing with Lemon Squeezy's License API, Keychain-stored trial dates, a 14-day offline grace window, gating at the window controller so locked features never even instantiate, Sparkle, and a notarized DMG, then a clean-Mac test on a fresh user account. Two known blockers are explicit: Face Unlock comes out of the commercial build because of the ArcFace licence, and UI Audit and Browser Flows currently need Node on the buyer's Mac. After 1.0 the first engineering item is making the Browser Flows self-test pass reliably. Shared Spaces today is a file package; live sync doesn't exist and we don't advertise it.
- **Art direction:**
  - Composition: one horizontal rail at y = 1000 across 10 columns, seven milestones as nodes with day ranges above (mono) and labels below (body 40 px, max 2 lines). Second rail at y = 1600, dashed, "After 1.0", five chips.
  - Tokens: rail `line`; nodes `surface` with `accent` ring on days 26–27 (ship); blockers (ArcFace, Node) marked with a small `text-faint` warning glyph, not red.
  - A: flat, the ship node glows. B: thin ink rail, red dot for ship. C: rail as a neon trace with travelling pulses; nodes as hex chips.

---

### Slide 16: Build on the notch with us
- **Layout:** CTA
- **Header:** Build on the notch with us
- **Subtitle:** Early access for developers and technical partners
- **Body:**
  - Beta: run UI Audit and Browser Flows against your own staging sites
  - Partners: [TBD: partnership tracks]
  - sparkv.si · [TBD: contact email]
- **Images:** `screenshots/51-clicky-answer.png` in NotchFrame (centre, 130%). Motion: loop of R2 or R1 end frame.
- **Speaker notes:** If you build websites, the fastest way to judge SparkV is to point UI Audit at your own staging site and read the fix prompt it produces. We're looking for beta testers for the developer tools and for partners; the specific partnership tracks and the contact address are being finalised. Questions.
- **Art direction:**
  - Composition: centred stack: NotchFrame at the top edge (island touching the slide top), header centred at y ≈ 1100, body centred below, URL in mono `accent-text` at 64 px.
  - Tokens: `glow` behind the island; button-like pill for "sparkv.si" in `accent` with `text` on it (A, C) or ink outline (B).
  - A: big red bloom from the notch downward (the only time the glow exceeds 16%: use 24%). B: white, the lid shadow, red URL. C: neon bloom with cyan rim, faint grid, the URL typed out in mono with a cursor.

---

## 3. 4K screen-recording and screenshot scripts

### 3.0 Global setup (do once, before every session)

**Operator note:** these scripts are for a person recording on a MacBook. Use your own judgement for system prompts; never click a destructive control.

| Item | Setting |
| --- | --- |
| Machine | 16-inch MacBook Pro with notch, Apple silicon, macOS 15+ (26+ for SpeechAnalyzer and standalone Translation sessions). Built-in display only (the notch exists only there). |
| Display scaling | System Settings › Displays › **Default** (looks like 1728 x 1117 pt; native 3456 x 2234 px). |
| Capture | Native pixels, 60 fps, ProRes 422 HQ (or HEVC 10-bit ≥ 80 Mbps), cursor visible, no click highlighting. Capture with OBS or QuickTime, **not** SparkV's own recorder (its red band would sit in the notch), except where a script says so. |
| Normalising to 4K ("N-frame") | Scale every recording by 3840 / 3456 = **1.1111** to 3840 x 2482, then keep rows y = 0–2160 (top-anchored, the notch is at the top). All crop rectangles and cursor coordinates below are N-frame pixels (x, y, w, h), origin top-left. Conversion: **N px = points x 2.2222**. On a 14-inch MacBook Pro (3024 x 1964 px native) use N px = points x 2.5397 and recompute. |
| Island geometry (16", Default) | Island centred at x = 1920. Drawer is 612 pt wide → 1360 N px (x 1240–2600). Heights: Home/Today/Flow pages 141 pt → 313 px; Widgets/Tray/Converter 186 pt → 413 px; Agents hub 228 pt → 507 px. Render pixel (rx, ry) of a 1224-wide drawer render maps to N (1920 + (rx − 612) x 1.1111, ry x 1.1111). |
| Header icon targets (N px, y = 41) | Home 1381 · Widgets 1440 · Tray 1498 · Today 1556 · Converter 1614 · Spaces 1671 · Focus 2190 · Record 2248 · Agents hub 2304 · Flow 2363 · Clicky 2420 · gear 2468. Verify against a test frame before the real take; adjust ±10 px. |
| Clean account | A separate macOS user "SparkV Demo" with no personal data (the renders were made the same way, in a throwaway home folder). Build signed with the stable identity so grants persist. |
| Desktop | Wallpaper: vertical gradient `#2A2E43 → #171925 → #0F1119` (matches the renders). Hide desktop icons, Dock set to auto-hide, only the clock in the menu bar. Do Not Disturb on (except R3 take 4). |
| Appearance | Dark mode (all renders are dark). |
| Audio | Record system audio on a separate track only for R5. Music for R1/R3: a track you have rights to, with artwork. The renders show "Midnight City · M83"; don't use a commercial track in a published video without a licence. |
| Sample data | Seed Spaces, Flow history and Tray with the same kind of sample data as the renders (fictional projects, a PNG, a JPG, a PDF, a DOCX and a link). Fictional names only. |
| Reset between takes | Close the drawer, park the cursor at (2900, 1200), wait 2 s so the island returns to rest. |
| Exports | Per shot: ProRes master in N-frame, plus PNG stills at the listed timestamps. File names `R<n>-<shot>-<take>.mov`. |

Crop presets used below (N-frame, x, y, w, h):

| Crop | Rect | Aspect | Use |
| --- | --- | --- | --- |
| A | 0, 0, 3840, 2160 | 16:9 | Full-frame hero |
| B | 1080, 0, 1680, 472 | 32:9 | Drawer pages up to 413 px tall, bands |
| C | 1000, 0, 1840, 690 | 8:3 | Agents hub |
| D | 1440, 0, 960, 270 | 32:9 | Compact wings close-up |
| G | 400, 100, 3040, 1710 | 16:9 | UI Audit window at pt origin (324, 90) |
| H | 480, 120, 2880, 1620 | 16:9 | Browser Flows (origin 344, 95), Meeting notes (origin 374, 100), Setup (origin 474, 100) |

Window placement: drag the window by its title area until its top-left corner sits at the listed point position. Press ⌘⇧4 and hover to read point coordinates, then Esc.

---

### R1. Hero: the drawer opens (slides 1 and 16)

- **Setup:** Music playing (compact wings visible). Drawer closed. Home is the last-used tab.
- **Shot list:**

| Time | Action | Cursor path (N px) |
| --- | --- | --- |
| 00:00–00:02 | Hold on the closed island: artwork on the left wing, level bars on the right | parked at (2900, 1200) |
| 00:02–00:04 | Glide to the notch; drawer springs open on Home | (2900, 1200) → (1920, 24), 1.2 s ease-in-out |
| 00:04–00:06 | Scroll up 3 ticks on the volume knob; the ring fills | → (1853, 156), hold, scroll |
| 00:06–00:09 | Click Widgets, Tray, Today, 0.8 s apart (crossfade + height spring) | (1440, 41) → (1498, 41) → (1556, 41) |
| 00:09–00:11 | Click Home | → (1381, 41) |
| 00:11–00:12 | Leave downward; the drawer closes after 0.5 s | → (1920, 900), 0.6 s |

- **Crops:** A for the full hero; B for slide 1's NotchFrame (overlay at 200% only from this 4K source, never from the PNG render).
- **Stills:** 00:05 (Home with knob), 00:08 (Today).
- **Overlay in deck:** Slide 1 right two thirds (NotchFrame, island centre at x = 2560); slide 16 centre top (end frame 00:05).

### R2. Agents hub (slide 3; optional loop on slide 16)

- **Setup:** As R1, music optional.
- **Shot list:**

| Time | Action | Cursor path (N px) |
| --- | --- | --- |
| 00:00–00:02 | Open the drawer | (2900, 1200) → (1920, 24) |
| 00:02–00:03 | Click the Agents hub icon; the 8x3 grid appears | → (2304, 41) |
| 00:03–00:06 | Sweep across row 1 tiles, 0.35 s per tile (Search → Prompt) | (1420, 133) → (2419, 133), straight line |
| 00:06–00:08 | Rest on UI Audit until the tooltip shows its shortcut | → (2419, 267), hold 1.5 s |

- **Crop:** C. **Still:** 00:07.
- **Overlay in deck:** Slide 3 right 5 columns (NotchFrame at 120% of the 4K crop width 1840 → fit 1380 px).

### R3. Live activities (slide 4)

- **Setup:** Drawer closed. gear › Live Activities: all on, "Hide macOS volume pop-up" on, AirPods battery enabled. Second device ready to send a message. DND **off** for take 4 only.
- **Takes (record continuously, cut later):**

| Time | Action | Expected | Crop |
| --- | --- | --- | --- |
| 00:00–00:04 | Press volume up (F12) x3, then volume down (F11) x2 | HUD band with level, newest wins | B |
| 00:05–00:09 | Plug in the charger | Charging band, then rests | B |
| 00:10–00:14 | Open the AirPods case next to the Mac | Left/right/case battery band | B |
| 00:15–00:19 | From a second device, send: "Demo: build is green" (fictional sender "Demo Bot") | Notification band (use "Hide Message Text" off for this take) | B |
| 00:20–00:24 | Play music, wait for the track change | Wings: artwork left, level bars right, title marquee for 8 s | D |
| 00:25–00:29 | Press ⌃⌥⇧R, then Return to record the whole display; stop at 00:29 with ⌃⌥⇧R | Red recording band with elapsed time (here SparkV's recorder is the subject; keep OBS running too) | B |

- **Cursor:** parked at (2900, 1200) the whole time; nothing should hover the island.
- **Stills:** 00:02, 00:07, 00:12, 00:17, 00:22, 00:27.
- **Overlay in deck:** Slide 4 right stack of six mini NotchFrames, each a B or D crop scaled to 1280 px wide.
- **Note:** FG flags the compact wings as sitting too high in offscreen renders; check the live result and prefer the recorded still over `46-compact-wings.png` if they differ.

### R4. Dictation (slide 6)

- **Setup:** TextEdit, plain-text document, window 1100 x 500 pt at origin (314, 200) → N (698, 444)–(3142, 1555). Font 24 pt. gear › Dictation: key fn, AI Formatting on. Microphone and Speech allowed.
- **Script to speak:** "um so the release checklist is sign with developer ID then notarize then staple and then ship the update"
- **Shot list:**

| Time | Action | Cursor |
| --- | --- | --- |
| 00:00–00:01 | Click into the document | (1920, 900) |
| 00:01–00:06 | Hold fn and speak; the dictation band shows under the notch | still |
| 00:06–00:09 | Release fn; cleaned text is typed in (fillers removed, list formatted) | still |
| 00:09–00:10 | Hold | still |

- **Crops:** B (band, 00:03) and (960, 400, 1920, 1080) for the typed result (00:09).
- **Overlay in deck:** Slide 6 collage, band at top right; typed result optional as a second still.
- **Note:** Output wording varies per take; keep the take whose result is correct and plain.

### R5. Meeting notes, live answers and Live Translation (slide 6)

- **Setup:** gear › Meetings › Suggest Answers to Questions on; Live Translation on, target English, caption window on (640 x 200 pt; drag it to origin (544, 700) pt → N (1209, 1556)–(2631, 2000)). Spanish language pair already downloaded. Prepare a 20-second audio clip with two fictional speakers, played from QuickTime Player (system audio):
  1. Spanish, 00:02–00:08: "Buenos días a todos. Hoy revisamos la migración de la API y el plan de lanzamiento."
  2. English, 00:09–00:13: a question addressed to the name the demo account uses in SparkV (FG's example: "…, what's the status of the API migration?").
  3. Silence.
- **Shot list:**

| Time | Action | Cursor path (N px) |
| --- | --- | --- |
| 00:00–00:02 | Open drawer, click the red Record icon; recording band appears | (1920, 24) → (2248, 41), then away to (2900, 1200) |
| 00:02–00:08 | Spanish clip; translated captions in the caption window and band | still |
| 00:09–00:14 | English question; a suggested answer appears under the notch | still |
| 00:15–00:16 | Stop: open drawer, click Record again | (1920, 24) → (2248, 41) |
| 00:16–00:20 | Meeting notes window: Minutes, Key points, Decisions, your tasks | move window to origin (374, 100) beforehand |

- **Crops:** B (answer band, 00:12); caption window (1120, 1500, 1600, 560) (00:07); H (notes window, 00:19).
- **Overlay in deck:** Slide 6 collage base = notes window, caption panel lower right.
- **Note:** Results depend on the on-device model; record several takes. Don't use real meeting audio.

### R6. Setup and permissions (slide 7)

- **Setup:** Fresh demo account where 6 of 12 permissions are allowed and Calendars is "Not asked yet" (matches the render).
- **Shot list:**

| Time | Action | Cursor path (N px) |
| --- | --- | --- |
| 00:00–00:02 | Open drawer → Agents hub → Setup tile | (1920, 24) → (2304, 41) → (1990, 383) |
| 00:02–00:04 | Setup window appears; move it to origin (474, 100) (or pre-position and cut) | — |
| 00:04–00:06 | Advance to Permissions with the primary button (bottom right) | → (2647, 1662) |
| 00:06–00:09 | Scroll the list slowly; hover "Allow…" on Calendars, don't click | scroll at (1920, 1100) → hover (2523, 1478) |
| 00:09–00:10 | Hold on the "6/12 allowed" ring | still |

- **Crop:** H. **Still:** 00:09.
- **Overlay in deck:** Slide 7 right 4 columns, WindowFrame at 70%.

### R7. UI Audit run (slide 8)

- **Setup:**
  - Node 20+ at `/opt/homebrew/bin/node`; Playwright Chromium present (`npx playwright-core install chromium` if missing).
  - In Terminal, from the project folder: `node Vendor/ui-audit/test/server.mjs 4965 "$TMPDIR/sparkv-demo-hits.jsonl"`. This serves the bundled planted-issue site on 127.0.0.1:4965 (local only).
  - Open gear › Agents › UI Audit…; place the window at origin (324, 90) → N (720, 200)–(3120, 1800).
  - Max pages 6, depth 3, both toggles off (local hosts submit anyway).
- **Shot list:**

| Time | Action | Cursor path (N px) |
| --- | --- | --- |
| 00:00–00:03 | Click the URL field, paste `http://127.0.0.1:4965` | → (1380, 307) |
| 00:03–00:05 | Click "Full frontend" | → (2731, 307) |
| 00:05–00:06 | Click Start | → (2976, 307) |
| 00:06–00:18 | Chromium opens (let it sit on the right; second camera crop for B-roll); live log and findings stream in. Speed-ramp 4–8x in edit and show a "4x" tag | park at (3300, 2000) |
| 00:18–00:21 | Status reads "Done: 6 pages · 69 issues". Click Summarize; on-device summary appears | → (2474, 1714) |
| 00:21–00:25 | Click the first critical finding to show its detail and screenshot | → (1920, 746) |
| 00:25–00:28 | Click **P**; fix prompt copied | → (3051, 1714) |
| 00:28–00:30 | Optional: paste into a coding agent's input to show its length | — |

- **Crop:** G. **Stills:** 00:19, 00:24.
- **Overlay in deck:** Slide 8 hero window (bottom-right, 120% of the crop's native 2400 px window width → use the 4K still, not the 2160 px render, if you go above 150%).
- **Note:** If a new run's counts differ from 6 pages / 69 findings, update the slide copy to the recorded run or keep the slide's numbers tied to the documented run and use the render.
- **After:** stop the fixture server (Ctrl-C).

### R8. Browser Flows: record, edit, replay with healing (slide 9)

- **Setup:**
  - Serve the bundled fixture site, variant v1: in Terminal, `cd Vendor/browser-recorder/test/site/v1 && python3 -m http.server 47811 --bind 127.0.0.1`.
  - Open gear › Agents › Browser Flows…; window at origin (344, 95) → N (764, 211)–(3075, 1722).
  - Sample values: email `demo+flows@example.com`, password `Demo-Pass-123` (fake), plan "Team", referral `FRIEND10`, avatar `Vendor/browser-recorder/test/avatar.png`.
- **Shot list:**

| Time | Action | Cursor path (N px) |
| --- | --- | --- |
| 00:00–00:02 | Type `http://127.0.0.1:47811/index.html` in the start-page field, click Record | → (1804, 304) → (2324, 304) |
| 00:02–00:12 | In Chromium: fill email, password, choose Team, referral code, tick terms, upload avatar, submit. Steps appear in SparkV as you go | in the Chromium window |
| 00:12–00:13 | Stop recording (same button) | → (2324, 304) |
| 00:13–00:16 | Click "Make Variable" on the referral step | → (2486, 1299) |
| 00:16–00:18 | Click Graph, then Steps | → (2075, 381) |
| 00:18–00:20 | Off camera: stop the server, serve `site/v2` on the same port | — |
| 00:20–00:28 | Click Replay; enter the fake password when asked; replay runs; a healed selector badge appears on the moved element | → (2948, 381) |
| 00:28–00:30 | Hold on the finished run | still |

- **Crop:** H. **Stills:** 00:15 (masked password step visible), 00:27.
- **Overlay in deck:** Slide 9 hero window (bottom-left).
- **Honesty rule:** the self-test is not clean under load. If a replay fails on camera, don't fake it: re-take on an idle machine, or show the step failure and its screenshot as part of the story.

### R9. Flow Canvas (slide 10)

- **Setup:**
  - Five local fixture pages with **fictional** products (for example "Acme Notes", "Beta Clips", "Gamma Dictate", "Delta Shelf", "Echo Snap"), each with a price, plans and features list. Serve them with `python3 -m http.server 8088 --bind 127.0.0.1` from a scratch folder. Don't use real competitors' pages in the video.
  - Agents hub › Canvas. Window 1320 x 840 pt at origin (204, 60) → N (453, 133)–(3387, 2000). Engine shows "On this Mac".
- **Shot list:**

| Time | Action | Cursor path (N px) |
| --- | --- | --- |
| 00:00–00:03 | Click the template "Competitor pricing comparison" | → (739, 683) |
| 00:03–00:09 | Paste the five fixture URLs into the five link cards, clicking Add each time | fields at (1392, 492), (1392, 801), (1392, 1106), (1392, 1415), (1392, 1723); Add at x = 1553 on each row |
| 00:09–00:11 | Click Run all | → (2382, 1922) |
| 00:11–00:20 | Cards go from "Not run" to done; speed-ramp 4x, tag it | park at (3600, 2050) |
| 00:20–00:25 | Click the "Competitor report" card; the result shows | → (2887, 954) |
| Alt take 00:00–00:06 | Type "Compare these pricing pages and write a one-page brief" in "What do you want to do with these?" and click Suggest steps | (1685, 211) → (2624, 211) |

- **Crop:** A (window fills 76% of the frame). **Stills:** 00:02 (empty template), 00:24 (report).
- **Overlay in deck:** Slide 10 full-bleed hero behind the left scrim.

### Static screenshot plan (when video isn't needed)

All deck stills can come from `docs/screenshots/` at ≤ 150% scale. Use the 4K stills from R1–R9 only when a slide needs more than 150% (slide 1 hero, slide 10 full bleed, slide 8 above 1.5x).

---

## 4. Placeholder register (must be resolved or stay visibly bracketed)

| Slide | Placeholder |
| --- | --- |
| 13 | Pro units [TBD], Team seats [TBD], year-one revenue [TBD] |
| 14 | Notched Apple-silicon MacBooks on macOS 15+ [TBD: sourced estimate]; SparkV users [TBD: monthly active users] |
| 15 | Kickoff date [TBD: launch kickoff date] |
| 16 | Partnership tracks [TBD]; contact email [TBD] |

## 5. Sources

- Project: `docs/SparkV-Feature-Guide.md`, `docs/SparkV-Business-Plan.md`, `Sources/` (NotchPanel.swift, NotchWindowController.swift, NotchState.swift, LiveActivity.swift, ACTIVITY-SHELL-INTEGRATION.md, MeetingAIBackend.swift, DictationController.swift, VisionClient.swift), `Sources/Labs/UIAudit/DESIGN.md`, `Sources/Labs/BrowserRecorder/DESIGN.md`, `Sources/Labs/FlowCanvas/INTEGRATION.md`, `Sources/Labs/LiveTranslation/DESIGN.md`, `build.sh`, `NotchIsland.entitlements`, `Vendor/clipboard/Tests/run-tests.sh`.
- Brand tokens: sparkv.si stylesheet (`--red #f01822`, `--red-on-dark #f8262f`, `--surface #111113`, background `#08080a`) and `docs/decks/style-demos/*/index.html`.
- Public figures: [9to5Mac, 29 Jan 2026](https://9to5mac.com/2026/01/29/apple-reveals-it-has-2-5-billion-active-devices-around-the-world/); [supportplan.com](https://supportplan.com/apple-has-more-than-2-35-billion-active-devices-up-550-million-since-2022); [AppleInsider forums, 100M active Macs](https://forums.appleinsider.com/discussion/208001). Competitor prices: the sources listed in BP §3.
