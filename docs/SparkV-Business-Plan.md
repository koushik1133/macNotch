# SparkV Business Plan: selling SparkV as a paid Mac app

Last researched: 22 October 2026. Prices of other products come from the sources linked inline. Many are third-party listings, so check each vendor's own page before you quote them publicly. INR prices assume about ₹88 per US$1 and are set lower than a straight conversion, matched to what people in India usually pay.

---

## 1. Summary

| Question | Answer |
| --- | --- |
| What we sell | A direct-download, notarized Mac app (macOS 15+, `com.sparkv.app`). Buyers pay, get a license key by email, download a DMG and start using it. |
| Where we sell | Our own website, with a merchant of record handling checkout, tax and license keys. **Lemon Squeezy** is the recommended choice. Paddle with Keygen is the alternative. Not the Mac App Store (see section 5). |
| Recommended pricing | **Free** (notch basics), **Pro** at **$39 one-time** (₹1,499), **Team** at **$8 per seat per month, billed yearly** (₹499). Launch week: Pro at $29 (₹999). 14-day full Pro trial, no card needed. 50% student discount. |
| AI cost to us | **$0.** AI runs on-device (Apple Intelligence, Vision, Speech). Groq is optional and uses the buyer's own key. |
| Fixed costs to start | Apple Developer Program, $99 a year (about ₹8,700 in India, [forum report](https://developer.apple.com/forums/thread/746357)). A domain and static hosting for the site and the Sparkle update feed. Lemon Squeezy has no monthly fee. |
| Blockers to fix before selling | (1) **Face Unlock's ArcFace weights are licensed for non-commercial use only.** (2) The app is signed with a self-signed identity, which only works for local development. It needs a Developer ID certificate and notarization. (3) There is no licensing code in the app yet. (4) UI Audit and Browser Flows need Node.js installed on the buyer's Mac. |

---

## 2. What SparkV actually contains (from the code)

This list comes from `Sources/`, `Sources/Labs/*`, the `Tab` enum in `NotchState.swift` and the tiles in `AgentsHubView.swift`. These names are used in every pricing table below.

| Group | Feature (code location) |
| --- | --- |
| Notch core | Media for any app with scrubber, artwork glow and bookmarks (`MediaEngine`, `Labs/Media`). Volume and brightness HUD (`HUDController`, `SystemKeyInterceptor`). Battery and power band (`PowerMonitor`). Notification mirror (`NotificationMonitor`). Camera mirror. AirDrop target. Tray, 5 items (`TrayView`). Two action capsules that run Shortcuts (`MacroController`, `ShortcutRunner`). Timer and Pomodoro, plus Today with upcoming meetings (`TimerController`, `TodayView`). |
| Widgets | World Clock with changeable time zones, System Gauges, Network Speed, Volume Knob, Habits (`Labs/Widgets`) |
| Wellbeing | Focus mode with app blocker, muter, edge glow and summary (`Labs/Focus`). Modes such as Concentration, Study, Relax, Meeting, Presentation and Night (`Labs/Modes`). Screen Distance (`Labs/ScreenDistance`). |
| Productivity | Clipboard history and Paste Stack (`Labs/Clipboard`). Converter, for on-device PDF, image and document conversion (`Labs/Converter`). File Drop actions (`Labs/FileDropActions`). Downloads watcher, sorter and rules (`Labs/Downloads`). Quick Capture to Spaces, and Screenshot to Clipboard (`Labs/QuickCapture`). Copy Text OCR (`Labs/ScreenRegion`). Screen Recorder (`Labs/ScreenRecorder`). Universal Search (`Labs/UniversalSearch`). Spaces, a knowledge base you can share as `.sparkvspace` packages (`Labs/Spaces`). Flow history and Notes (`FlowStore`). |
| AI assistants | Dictation with hold-fn and AI formatting (`DictationController`, `DictationFormatter`). Clicky voice and screen assistant, which points at what to click (`Clicky*`, `VisionClient`). Ask Screen (`Labs/ScreenRegion`). Reply Drafter, ⌃⌥R (`Labs/ReplyDrafter`). Prompt Refiner (`Labs/PromptRefiner`). Tray AI actions, OCR and calendar (`TrayAI*`). Job Search Agent (`Labs/JobAgent`). |
| Meetings | Meeting recorder, transcriber, summarizer, notes window and capsule (`Meeting*`). Live Translation band and captions (`Labs/LiveTranslation`). |
| Developer tools | UI Audit, which runs Playwright and axe-core against your own site (`Labs/UIAudit`, `Vendor/ui-audit`). Browser Flows, which records and replays browser tasks (`Labs/BrowserRecorder`, `Vendor/browser-recorder`). Flow Canvas, a visual automation planner and runner (`Labs/FlowCanvas`). |
| Security | Face Unlock (`Vendor/glance`). **Not sellable as it is.** See section 8. |
| Setup | Onboarding and the permissions window (`Labs/Onboarding`) |

---

## 3. Comparable products and prices

| Product | What it is | Price | Source |
| --- | --- | --- | --- |
| NotchNook | Notch hub (media, tray) | $25 one-time or $3 a month, 2-day trial. Sold direct and through Setapp. Not on the App Store because it uses private APIs. | [iMore](https://www.imore.com/apps/mac-apps/this-dollar25-app-gives-my-macbook-pro-a-dynamic-island-and-it-was-worth-every-penny), [Lowyat](https://lowyat.net/2024/327211/notchnook-dynamic-island-macbooks-us25), [Smartworld](https://www.smartworld.it/app/notchnook-app-mac-dynamic-island.html) |
| boring.notch | Open-source notch app | Free, GPL-3.0, about 11.1k GitHub stars. Not notarized ("unidentified developer" warning). | [GitHub](https://github.com/TheBoredTeam/boring.notch), [Korben](https://korben.info/en/boring-notch-macbook-notch-finally-useful.html) |
| Alcove | Dynamic Island for the Mac | About $13.99 one-time, 72-hour trial | [appgefahren](https://www.appgefahren.de/alcove-bringt-die-dynamic-island-auf-den-mac-394469.html), [SlashGear](https://www.slashgear.com/2175261/macos-apps-give-features-apple-doesnt-include/) |
| Raycast Pro | Launcher with AI | $10 a month, or $8 a month billed yearly. 14-day trial. Pro+ is $20 a month. | [tech-insider](https://tech-insider.org/raycast-vs-alfred-2026/), [Raycast blog](https://www.raycast.com/blog/changing-how-raycast-ai-is-priced) |
| CleanShot X | Screenshots and recording | $29 one-time with 1 year of updates, then $19 a year (optional). Cloud Pro is $8–10 a month. | [toolradar](https://toolradar.com/tools/cleanshot/pricing), [TrustRadius](https://trustradius.com/products/cleanshot-x/pricing) |
| Wispr Flow | AI dictation | Pro is $15 a month, or $144 a year. Teams from $10 per user per month. Students pay $6 a month. | [getvoibe](https://www.getvoibe.com/resources/wispr-flow-pricing/), [spokenly](https://spokenly.app/blog/wispr-flow-pricing) |
| Granola | AI meeting notes | Business is $14 per user per month. Enterprise from $35. | [Granola](https://granola.ai/blog/granola-pricing-plans-features-roi), [Read AI](https://www.read.ai/it/articles/granola-ai-pricing-alternatives) |
| Paste | Clipboard manager | $3.99 a month, $29.99 a year, or $89.99 lifetime | [App Store](https://apps.apple.com/app/id967805235) |
| Setapp | App subscription bundle | Mac plan about $14.99 a month, or about $8.99 a month billed yearly (prices rose June 2026) | [PricingSaaS](https://pricingsaas.com/companies/setapp/diffs/2026W25), [Setapp](https://setapp.com/app-reviews/setapp-pricing-explained) |

**What this means for us:** SparkV does the work of a notch app, a clipboard manager, a dictation app, a meeting recorder and a screenshot tool in one app. Paying for those separately costs a buyer well over $300 a year. Pure notch apps sell for $14–25 one-time, so a **$39 one-time Pro** is easy to justify, and it is still cheaper than two months of Wispr Flow and Granola together. Because we pay nothing for AI, we can charge once instead of monthly, and that is a selling point against Wispr, Granola and Raycast.

---

## 4. Payment and licensing platforms

A merchant of record (MoR) is the legal seller. It collects and pays VAT, GST and US sales tax around the world, which a solo Indian seller should not try to do alone.

| Platform | Fee | MoR? | License keys | Notes | Source |
| --- | --- | --- | --- | --- | --- |
| **Lemon Squeezy** (owned by Stripe) | 5% + 50¢. About +1.5% on non-US orders and +0.5% on subscriptions. | Yes | **Built in**, with a License API to activate, validate and deactivate keys | Built-in affiliates and file delivery. Payouts to US banks are free, international payouts cost 1%. | [Dodo review](https://dodopayments.com/blogs/lemonsqueezy-review), [fungies](https://fungies.io/lemon-squeezy-stripe-acquisition-saas-founders-2026/), [LS License API](https://docs.lemonsqueezy.com/api/license-api) |
| Paddle | 5% + 50¢ | Yes | Not a full licensing system. Pair it with Keygen. | Mature, used by many Mac indie apps | [Dodo](https://dodopayments.com/blogs/paddle-fees-explained), [Spendflo](https://spendflo.com/vendors/paddle) |
| Gumroad | 10% + 50¢ (30% through Discover), plus card fees. Keeps its fee on refunds. | Yes, since January 2025 | Basic keys | Easiest to start, most expensive | [schoolmaker](https://schoolmaker.com/blog/gumroad-pricing), [ecomm.design](https://ecomm.design/gumroad-review/) |
| FastSpring | Quote-based, about 5.9% + 95¢ (third-party estimate) | Yes | Yes | Aimed at larger software vendors | [Dodo](https://dodopayments.com/blogs/fastspring-pricing-explained/) |
| Stripe + Keygen | Stripe India: 3% on foreign cards, plus 2% for currency conversion. **Not an MoR**, so we would file taxes ourselves. Keygen: free self-hosted CE, or cloud from about $24–49 a month. | No | Keygen | Most control, most work | [Stripe India](https://stripe.com/ja-in/pricing), [Keygen](https://keygen.sh/pricing), [apis.io](https://apis.io/plans/keygen/keygen-plans-pricing/) |
| Setapp (extra channel, not checkout) | 70% of usage-based revenue, up to 90% with the partner fee | — | Setapp's SDK | Reach, not control. Consider it after launch. | [Setapp docs](https://docs.setapp.com/docs/setapp-membership-revenue) |

**Example: what we keep from a $39 Pro sale.** Lemon Squeezy or Paddle: 39 − (1.95 + 0.50) = **about $36.55**, or about $36 with the international surcharge. Gumroad: 39 − 4.40 = $34.60, before card fees.

**Recommendation: Lemon Squeezy.** It is an MoR, it issues license keys, it has a public License API the app can call without a secret, and it has affiliates built in. One merchant account covers the whole plan. Before signing up, confirm in its dashboard that it supports payouts to your country and bank. Fall back to Paddle with Keygen if Lemon Squeezy rejects the account.

---

## 5. Apple requirements for selling outside the App Store

| Item | What to do | Source |
| --- | --- | --- |
| Apple Developer Program | $99 a year (about ₹8,700). Enrol as an individual, or as an organization with a D-U-N-S number if you want the company name shown. Indian users have reported checkout errors; the Apple Developer iPhone app with UPI or net banking has worked for some. | [Apple forums](https://developer.apple.com/forums/thread/832616), [renewal thread](https://developer.apple.com/forums/thread/746357) |
| Developer ID Application certificate | Only the team's Account Holder can create it. **It replaces "NotchIsland Developer".** That self-signed identity is only for local builds. Gatekeeper on buyers' Macs will not trust it. | [Apple Developer ID](https://developer.apple.com/developer-id/) |
| Hardened Runtime and secure timestamp | `build.sh` already signs with the Hardened Runtime. Add `--timestamp`, and sign every nested binary (MediaRemoteAdapter.framework, helpers, `.node` binaries if any). | [Flavio Copes](https://flaviocopes.com/macos-open-anyway/) |
| Notarization | `xcrun notarytool submit SparkV.dmg --wait`, then `xcrun stapler staple`. It is an automated scan, not a human review. | [Apple Developer ID](https://developer.apple.com/developer-id/), [4D KB](https://kb.4d.com/TN/2025/25-01_Notarization.pdf) |
| Why it matters | Since macOS Sequoia, a user can no longer right-click and choose Open on an app that isn't notarized. They have to approve it in System Settings › Privacy & Security, and most paying buyers will treat that as a red flag. | [Eclectic Light](https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/), [Cult of Mac](https://www.cultofmac.com/?p=864843) |
| TCC grants for buyers | With one stable Developer ID, Accessibility, Screen Recording, Camera and Microphone grants survive updates, as the self-signed identity does today. | — |

### Why not the Mac App Store

| SparkV needs | App Store problem | Source |
| --- | --- | --- |
| Accessibility (dictation insert, Reply Drafter, Clicky, notification mirror) | Apple's DTS says Accessibility APIs are **not compatible with the App Sandbox**, and points to Developer ID distribution instead | [Apple forums](https://developer.apple.com/forums/thread/749494), [Blake Crosley](https://blakecrosley.com/blog/window-manager-mac-app-store-sandbox) |
| Posting key events (`CGEvent.post` for paste and insert) and event taps for fn and media keys (`SystemKeyInterceptor`) | Clipboard managers have been rejected for `CGEvent.post` | [Apple forums](https://developer.apple.com/forums/thread/820594) |
| Private `DisplayServices` loaded with `dlopen` (HUD, Modes) | Guideline 2.5.1 allows public APIs only | — |
| Now Playing through `mediaremote-adapter` running under `/usr/bin/perl` | A private MediaRemote workaround. NotchNook stays off the App Store for this same reason. | [Smartworld](https://www.smartworld.it/app/notchnook-app-mac-dynamic-island.html) |
| Starting Node and Playwright, `/usr/bin/shortcuts`, and a visible Chromium | Not allowed in a sandbox | — |

**Decision:** sell directly. Setapp can be added later as a second channel. It allows non-sandboxed apps.

### Auto-updates: Sparkle 2
- Sparkle checks updates against **EdDSA signatures** and Apple code signing, and reads an RSS **appcast** from static hosting. `generate_appcast` builds the feed and the delta updates. ([Sparkle](https://github.com/sparkle-project/Sparkle), [upgrade notes](https://sparkle-project.org/documentation/upgrading/))
- License: MIT. Its bundled bsdiff, sais and ed25519 code has its own notices, which must ship with the app ([LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE)).
- Add the framework as a vendored binary, because CLT-only builds have no SwiftPM GUI. Call `SPUStandardUpdaterController` from AppKit code, with no SwiftUI macros. Add a "Check for Updates…" item to the gear menu.

---

## 6. Pricing

### 6a. Recommended: three plans

| | **Free** | **Pro** (recommended) | **Team** |
| --- | --- | --- | --- |
| USD | $0 | **$39 one-time**, launch price $29. Includes 12 months of updates. Renewal is optional at $19 a year; the app keeps working forever. | **$8 per seat per month, billed yearly** ($96 per seat per year). Minimum 3 seats. |
| INR | ₹0 | **₹1,499**, launch price ₹999. Renewal ₹799 a year. | **₹499 per seat per month**, billed yearly |
| Macs per license | 1 | 2 Macs per person | 1 seat = 1 person, 2 Macs |
| Notch core | Media with scrubber, HUD, battery, notification mirror, camera mirror, AirDrop target, Tray (5 items), 2 Shortcut capsules, Timer and Pomodoro, Today | Everything | Everything |
| Widgets | World Clock (time zones changeable), System Gauges | All widgets (adds Network Speed, Volume Knob, Habits) | All |
| Productivity | Clipboard history (last 25), Copy Text OCR, Flow history | Clipboard and Paste Stack (unlimited), Converter, File Drop, Downloads rules, Quick Capture, Screen Recorder, Universal Search, Spaces, Focus, Modes, Screen Distance | All |
| AI assistants | Dictation without AI formatting | Dictation with AI formatting, Clicky, Ask Screen, Reply Drafter, Prompt Refiner, Tray AI, Job Agent | All |
| Meetings | — | Recorder, transcripts, summaries, Live Translation | All |
| Developer tools | — | UI Audit, Browser Flows, Flow Canvas | All |
| Team extras | — | — | One invoice (PO or bank transfer), seat management through the Lemon Squeezy customer portal or Keygen, shared Spaces packages, priority email support (1 business day), a deployment `.pkg` for MDM |
| Trial | — | **14-day full Pro trial**, no card. After it ends, the app falls back to Free and never locks. | 30-day pilot for up to 5 seats |

Why this shape:
- **Free hooks people.** A useful notch app at $0 takes boring.notch users and lets reviewers and Reddit try it with nothing at stake.
- **One-time Pro fits our costs.** We pay no AI or server costs per user. Buyers on r/macapps prefer one-time prices, and CleanShot X ($29 plus $19 a year for updates) shows the model works.
- **Team adds recurring revenue** from companies that need invoices and support. **Be honest about the scope:** shared Spaces today is a file package (`SpaceSharing.swift`), and live sync does not exist yet, so don't advertise it.

### 6b. Alternative: price per feature pack

Each pack is a one-time purchase on top of Free. The "Everything" bundle equals Pro, so a buyer of two or more packs is pushed toward Pro.

| Pack | Includes (exact SparkV features) | USD | INR |
| --- | --- | --- | --- |
| **Notch & Media** | Media with scrubber, bookmarks and glow; HUD replacement; all Widgets (World Clock, System Gauges, Network Speed, Volume Knob, Habits); Modes; Focus; Screen Distance; unlimited Tray | $9 | ₹499 |
| **Productivity** | Clipboard history and Paste Stack; Converter; File Drop actions; Downloads watcher and rules; Quick Capture; Screenshot to Clipboard; Copy Text; Screen Recorder; Universal Search; Spaces | $15 | ₹799 |
| **AI Assistants** | Dictation with AI formatting; Clicky voice and screen assistant; Ask Screen; Reply Drafter; Prompt Refiner; Tray AI actions; Job Search Agent | $19 | ₹999 |
| **Meetings** | Meeting recorder, transcriber, summarizer and notes window; Live Translation band and captions; calendar join from Today | $15 | ₹799 |
| **Developer Tools** | UI Audit (Playwright and axe-core, for your own sites); Browser Flows recorder and replay; Flow Canvas | $19 | ₹999 |
| **Everything (= Pro)** | All 5 packs | **$39** (packs separately: $77) | **₹1,499** (separately: ₹4,095) |

Same trial (14 days, all packs), same student discount, same 2 Macs per license.

### 6c. Discounts and trial

| Item | Policy |
| --- | --- |
| Trial | 14 days, every feature, no card. The start date is kept in the Keychain, so reinstalling doesn't restart it. |
| Students and teachers | **50% off** Pro ($19.50, or ₹749). Check a `.edu` or `.ac.in` email, or a student ID, through a Lemon Squeezy discount code. Wispr Flow gives students 50% off too ([getvoibe](https://www.getvoibe.com/resources/wispr-flow-pricing/)). |
| Launch week | Pro at $29 (₹999) for the first 7 days or the first 500 buyers |
| Upgrade from packs | The price of packs already bought counts toward Pro |
| Refunds | 30 days, no questions asked (see section 7) |

### 6d. Recommendation

**Launch with the three plans (6a). Don't launch with packs.**
1. One price is easier to explain in a 60-second Product Hunt or YouTube demo, and buyers don't freeze in front of five choices.
2. Gating code is simpler: three plan checks instead of five packs and their combinations.
3. Packs can come later as a cheaper entry. For example, a "Meetings only" pack for people who came for meeting notes. Sections 6b and 9 are written so they can be switched on later without breaking existing licenses.

---

## 7. Legal pages to publish

| Document | Must cover for SparkV |
| --- | --- |
| **Privacy policy** | By default everything stays on the Mac: speech, camera, screenshots, clipboard, Spaces, meeting audio. **Groq is optional.** With the buyer's own key, the screenshot under the mouse and the question go to `api.groq.com`, and only while the buyer is asking. License checks send the key, an anonymous device ID and the app version to Lemon Squeezy. Lemon Squeezy, as MoR, handles payment data. No analytics, unless we add crash reporting, which then has to be opt-in. |
| **EULA / terms** | License grant (per person, 2 Macs). No resale or reverse engineering. Fallback to Free when a trial or subscription ends. **AI outputs have no warranty.** **UI Audit and Browser Flows may only be used on sites and accounts the user owns or is allowed to test.** Face Unlock disclaimer (if it ever ships). Limit of liability. Governing law (India). |
| **Refund policy** | 30 days, no questions. The MoR runs the refund. Gumroad and FastSpring keep their fee on refunds ([schoolmaker](https://schoolmaker.com/blog/gumroad-pricing), [Dodo](https://dodopayments.com/blogs/fastspring-pricing-explained/)), so check the chosen MoR's terms. |
| **GDPR basics (EU and UK buyers)** | Name the controller and a contact email. Legal basis: contract for licensing, consent for crash reports. Rights: access, deletion, portability. Sign the MoR's data processing agreement. Collect as little as possible. Because our data is on-device, it's easy to promise very little. |
| **India DPDP Act 2023 and Rules 2025** | Rules notified 13 November 2025. The **notice and consent duties apply from 13 May 2027.** The notice must list the personal data, state the purpose and be written separately in plain language. Name a grievance contact. The older SPDI Rules 2011 apply until then. ([Mondaq](https://webiis08.mondaq.com/india/data-protection/1706890/a-closer-look-at-the-dpdp-rules-2025), [AZB](https://www.azbpartners.com/bank/update-indias-digital-personal-data-protection-framework-comes-into-effect/), [PIB](https://static.pib.gov.in/WriteReadData/specificdocs/documents/2025/nov/doc20251117695301.pdf)) |
| **Trademarks** | Don't use other products' names in marketing ("Wispr-style", "Clicky"). The README already notes that the icons are SF Symbols and not those logos. Consider renaming the Clicky feature before launch, for example to "SparkV Assist". |

Get a lawyer to review these pages before launch. This plan is not legal advice.

---

## 8. Third-party code shipped in the app

| Component (in `Vendor/`) | License | What we must do | Status |
| --- | --- | --- | --- |
| **glance** (Face Unlock code), © 2026 Jonathan Zhou | MIT | Include the copyright and license text | `build.sh` already copies it to `Resources/glance-LICENSE` |
| **ArcFace model** (`glance/Models/ArcFace.mlmodelc`, InsightFace `w600k_mbf`) | **Non-commercial research only** (`Vendor/glance/PORTING.md`; [InsightFace README](https://gitee.com/Egrt/insightface)) | **We can't ship it in a paid app.** Either take Face Unlock out of the sold build, buy a commercial license from InsightFace, or replace the model with one whose license allows commercial use. Face Unlock also types the user's password at the lock screen, so leaving it out is also the lower-risk choice. | **Blocker** |
| **mediaremote-adapter**, © 2025 Jonas van den Berg and contributors | BSD 3-Clause | Include the copyright, conditions and disclaimer in the docs shipped with the binary. Don't use the authors' names to endorse SparkV. | The LICENSE file is copied next to the adapter. Also list it on the Acknowledgements screen. |
| **playwright-core 1.64.1** (browser-recorder, ui-audit) | Apache-2.0 | Ship the LICENSE **and the NOTICE** file. Mark any files we changed. | Ship it inside `node_modules`. If Browser Flows uses Playwright's own downloaded Chromium (`chromium.executablePath()`), Chromium's licenses apply too. Use the installed Chrome (`channel: 'chrome'`) by default. |
| **axe-core 4.14.0** (ui-audit) | MPL-2.0, plus MIT parts listed in `LICENSE-3RD-PARTY.txt` | Keep its files unmodified. Include the license, and state where the source is available ([github.com/dequelabs/axe-core](https://github.com/dequelabs/axe-core)). MPL is file-level, so SparkV's own code stays closed. ([OpenMRS FAQ](https://openmrs.atlassian.net/wiki/x/hn_RAQ), [Mozilla FAQ](https://www.mozilla.org/MPL/2.0/Revision-FAQ.html)) | Ship the license files as they are |
| **Sparkle 2** (to add) | MIT, plus bsdiff, sais and ed25519 notices | Include its LICENSE | To do |
| `Vendor/clipboard`, `Vendor/ui-audit`, `Vendor/browser-recorder` (our code) | Ours (`UNLICENSED` / private) | — | — |
| boring.notch (reference only) | GPL-3.0 | **Don't copy any code from it.** GPL would require us to open SparkV's source. | Not used |

**To do:** add gear › About › Acknowledgements, which shows every license above. Also bundle `Resources/Acknowledgements.txt`.

**Runtime dependency:** UI Audit needs Node 20 or later, and Browser Flows needs Node 18 or later. The app looks for Node in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. Either list Node as a requirement for the Developer Tools features, or bundle a signed Node binary. That adds about 40–100 MB, and Node has its own MIT license and notices.

---

## 9. AI costs

| Path | Who pays | Cost to us |
| --- | --- | --- |
| On-device: Apple Intelligence / Foundation Models, Vision OCR, Speech, Translation | Nobody | $0 |
| Groq (Clicky vision, optional elsewhere) | **The buyer, with their own key** in Clicky's Keychain item. Groq's free tier works. Paid rates for Llama 4 Scout are about $0.11 per million input tokens and $0.34 per million output tokens ([aggregator](https://anotherwrapper.com/tools/llm-pricing/llama-4-scout-groq/o1); check groq.com). | $0 |

Our margin per sale is the price minus the MoR fee. The only costs that grow are support time and a little bandwidth for DMG downloads (about 20–60 MB each, cheap on a CDN such as Cloudflare R2). Never ship a shared Groq key in the app.

---

## 10. Go-to-market

| Channel | What to do | Source |
| --- | --- | --- |
| **Product Hunt** | Launch on a Tuesday or Wednesday at 12:01 AM PT, with a polished 60–90 s demo video and 5 GIF screenshots. Reply to every comment within minutes. Build a waitlist 2–3 weeks before. | [screenhance](https://screenhance.com/blog/product-hunt-launch-checklist-2026), [HackerNoon](https://hackernoon.com/lite/i-turned-a-failed-product-hunt-launch-into-a-top-3-win-on-a-budget) |
| **r/macapps** | New developers post in the monthly **"App Pile" megathread** in the PCP format (Problem, Comparison, Pricing). Posting in the main feed needs a trust path (public identity and portfolio, or a GitHub project with history) and 10+ subreddit karma. Self-promotion counts toward a 30-day limit. | [r/macapps mirror](https://redlib.groet-infra.nl/r/macapps) |
| **YouTube demos** | One "Your MacBook notch can do THIS" video (2–4 min), plus a 30 s Short for each feature: dictation, Clicky pointing, meetings with translation, Converter, UI Audit. Send free Pro keys to Mac YouTubers with 20k–300k subscribers. | — |
| **Affiliates** | Lemon Squeezy's built-in affiliate program. 30% commission, 30-day cookie. Recruit YouTubers and newsletter writers. | [fungies](https://fungies.io/lemon-squeezy-stripe-acquisition-saas-founders-2026/) |
| **Show HN / Indie Hackers** | Show HN post for the Developer Tools features. A build-in-public thread on X and LinkedIn, aimed at Indian developers and students. | [DEV](https://dev.to/lightningdev123/beyond-product-hunt-a-technical-launch-guide-for-2026-i2j) |
| **Comparison pages** | Pages on our site: "SparkV vs NotchNook", "vs Alcove", "vs boring.notch". Lead with the fact that SparkV replaces five apps. | — |
| **Setapp** (month 3 or later) | Apply once reviews exist | [Setapp docs](https://docs.setapp.com/) |

**Positioning line:** *"Your notch, now an AI command center. Dictation, meetings, screen help and 20 more tools. Private by default, pay once."*

---

## 11. 30-day launch checklist

| Days | Tasks |
| --- | --- |
| **1–3** | Enrol in the Apple Developer Program. Create the Developer ID Application certificate. Sign up for Lemon Squeezy and create the products (Pro, Pro Student, Team, Launch discount) with license keys turned on. Buy the domain. |
| **4–7** | Take Face Unlock out of the sold build, or settle the ArcFace license. Rename "Clicky" if you decide to. Add Acknowledgements. Write the privacy policy, EULA and refund policy. |
| **8–12** | Build licensing, trial and gating (section 12). Add Sparkle. Change `build.sh` to sign with Developer ID plus `--timestamp`, notarize, staple and build the DMG. |
| **13–15** | Do a clean-Mac test on a fresh macOS user account: download the DMG, check that Gatekeeper opens it with no warning, walk through onboarding and every permission, start the trial, activate a key, deactivate it, and update through Sparkle from 1.0 to 1.0.1. |
| **16–18** | Landing page: hero video, feature grid, pricing table (USD, with INR for visitors from India), FAQ, comparison pages, and a waitlist form. |
| **19–22** | Record the demo video and 5 Shorts. Prepare the Product Hunt page, gallery and maker comment. Send keys to 10–15 creators and beta users. |
| **23–25** | Private beta with 30–50 users from the waitlist. Fix crashes. Collect 5 testimonials. |
| **26** | Ship 1.0. Turn on the launch price. |
| **27 (Tue/Wed)** | Launch on Product Hunt. Post in the r/macapps App Pile. Post on X and LinkedIn. Email the waitlist. |
| **28–30** | Reply to every comment and support email. Ship 1.0.1 through Sparkle. Show HN. Open the affiliate program. Write a short retrospective covering conversion rate, refunds and the top requests. |

---

## 12. Engineering plan: adding licensing

Don't use `@State`, `#Preview` or `@Entry`. Use `@StateObject` and `ViewFlag`. Put the new files in `Sources/Labs/Licensing/` and add `cp Sources/Labs/Licensing/*.swift "$WORK/src/"` to `build.sh`.

| Step | Work |
| --- | --- |
| 1. Model | `enum SparkVPlan { free, trial, pro, team }` and `enum SparkVFeature` (one case per row in section 2). `struct Entitlements { func allows(_ f: SparkVFeature) -> Bool }` maps plan to features from one table, so packs (6b) can be added later as a set of `SparkVPack` values. |
| 2. LicenseManager | `@MainActor final class LicenseManager: ObservableObject` (shared). It **activates** a key with Lemon Squeezy's `POST /v1/licenses/activate` (key plus instance name), **validates** it on launch and every 7 days, and **deactivates** it from the gear menu so the buyer can move Macs. It stores the key, instance ID and last validation date in the **Keychain**, in its own item, separate from the Groq key. |
| 3. Offline grace | If a check fails because there is no network, keep Pro for **14 days** after the last successful validation. Never lock someone out because they are offline. |
| 4. Trial | Put the first-run date in the Keychain, plus a marker file in Application Support. Trial = first run + 14 days. Show "Trial: N days left" in the gear menu. When it ends, show a soft paywall once and drop to Free. Data is kept. |
| 5. Gating points | **`NotchWindowController`:** don't create the controllers for gated features (MeetingsController, UIAudit, BrowserRecorder, FlowCanvas, and so on) unless `allows(...)`. This also saves memory. **`AgentsHubView`:** locked tiles show a small lock badge, and tapping one opens the paywall instead of the feature. **`NotchNookLayoutView`:** hide locked tabs in the header and add **gear › License…** and **gear › Check for Updates…**. **Hotkeys** (⌃⌥R, ⌃⌥ for Clicky, Copy Text): check `allows(...)` before acting, and show a band saying "Pro feature, start your trial". |
| 6. Paywall window | An AppKit `NSWindow` with SwiftUI content: plan comparison, **Buy Pro** (opens the Lemon Squeezy checkout URL in the browser), a field to paste the key and an **Activate** button, and **Restore / Deactivate**. |
| 7. Tamper resistance (light) | Run checks in more than one place and sign the cached validation result with HMAC. Don't go further. Determined pirates won't pay anyway, and heavy DRM hurts the people who do. |
| 8. Release pipeline | Read `DEVELOPER_ID` from an environment variable in `build.sh`. When it is set, sign everything with `--options runtime --timestamp`, make the DMG with `hdiutil`, run `notarytool submit --wait`, run `stapler staple`, and run `generate_appcast`. Keep "NotchIsland Developer" for local builds. |
| 9. Tests | Add a harness to `Vendor/clipboard/Tests`, the existing CLT test setup. Cover the plan-to-feature table, trial dates (including clock changes), the offline grace window, and key-response parsing using recorded Lemon Squeezy responses. |

Estimated effort: about 4–6 days for licensing and gating, 1–2 days for Sparkle and notarization, 1 day for the paywall UI.

---

## 13. Risks

| Risk | Mitigation |
| --- | --- |
| A macOS update breaks the private MediaRemote or DisplayServices paths | The fallbacks already exist (Apple Events or media keys for media). Promise "best effort" in the EULA. Ship fixes quickly through Sparkle. |
| Gatekeeper or notarization fails on a new macOS release | Test every beta in a clean VM. Keep one stable Developer ID. |
| Too many permission prompts scare buyers | Onboarding already walks through each permission. Only ask for one when the feature that needs it is first used. |
| Commercial license problems (ArcFace) | Leave Face Unlock out of 1.0 |
| Support load from five feature areas | Docs site, a short video for each feature, and in-app "Report a problem" with logs the user chooses to attach |
