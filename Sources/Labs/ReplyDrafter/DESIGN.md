# Reply Drafter: design note

You press ⌃⌥R (or use the Agents tile or the header button) while a chat or an email is open. SparkV reads the conversation in the front window and drafts a reply in your tone, using your most relevant Space for context. It writes the reply straight into the message box, and also into the Subject when you are composing a new email. A small bar next to the field offers **Undo, Redo, Regenerate, Shorter, Longer, More formal, More casual** and **Close**. SparkV never presses Send.

## What production tools do (research)

| Source | What we took |
|---|---|
| **Grammarly for Mac**: [why it needs Accessibility](https://support.grammarly.com/hc/en-us/articles/360059770451-Why-does-Grammarly-need-access-to-accessibility-features), [developer guidance](https://help.superhuman.com/hc/en-us/articles/46242102540813-How-do-I-integrate-Grammarly-with-my-website-or-application) | It reads and writes other apps' text only through the macOS Accessibility API. Apps must expose the text and the selected-text range (`NSTextView` does this out of the box). It also shows a floating widget next to the active field. We follow the same contract: read `AXValue` and `AXSelectedTextRange`, write `AXSelectedText`, and show a floating bar that does not take focus. |
| **Superhuman Go for Mac** ([Accessibility FAQ](https://support.grammarly.com/hc/en-us/articles/44208889475213-Why-does-Superhuman-Go-for-Mac-need-access-to-accessibility-features)), **Superhuman AI** ([blog](https://blog.superhuman.com/superhuman-ai/)) | It reads the screen through Accessibility. Its "write with AI" matches the voice and tone of the emails you already sent. Typing a few words and expanding them is a core flow. In our version, what you typed in the message box becomes the reply's `<intent>`, and the draft replaces it. |
| **Shortwave Ghostwriter** ([blog](https://www.shortwave.com/blog/best-ai-email-writer/)) | Drafts are written "in your voice and tone", learned from the emails you send. We learn tone from the user's own messages that are visible in the thread: greeting, sign-off, length, lowercase, emoji and exclamation habits, plus up to 3 short examples. A tone description in settings adds to this. |
| **Raycast AI**: [Quick Fix, v0.61](https://www.raycast.com/changelog/macos/0-61), [AI Commands](https://manual.raycast.com/ai/ai-commands) | "Takes your selected text … and pastes back" the result. The primary action is either "Paste to Active App" or "Copy to Clipboard". We keep a paste fallback through `TextInserter`, which saves and restores the clipboard and marks the item transient, plus a **Copy** button. |
| **Electron accessibility** ([docs](https://www.electronjs.org/docs/latest/tutorial/accessibility)) | Assistive apps turn on Electron's and Chromium's web accessibility tree by setting `AXManualAccessibility` on the app element. Without it, the Slack, Discord and Teams desktop apps show no message text. |
| **ScreenRegion design note** (this repo: Raycast Screen Awareness, ChatGPT for Mac) | Screen capture runs only on request, checks the permission with preflight first, captures only the target window (`SCContentFilter(desktopIndependentWindow:)`), and stores nothing. The OCR fallback reuses `ScreenRegionCapture` and `TrayAIOCR` unchanged. |

We use no third-party code and vendor no library. Everything is written against Apple's public APIs.

## Pipeline

```
⌃⌥R / tile / header button
  │
  ├─ ReplyAXReader.capture(pid)            off-main, 4,000-node / 2.5 s budget, AXManualAccessibility for Chromium/Electron
  ├─ ReplyContextDetector.detect           bundle id → page URL (AXWebArea.AXURL) → window title
  ├─ ReplyConversationReader.read          message box, Subject, lines (pane = the message box's column), parse
  │     └─ < 40 chars read? → ScreenRegionCapture(window) → TrayAIOCR → ReplyOCRReader.read (same parser)
  ├─ ReplyToneLearner.learn                own messages + settings tone/sign-off
  ├─ SpaceStore.search → ReplySpaceContextBuilder.pick   rank-weighted Space vote, best sentences, Space memory
  ├─ ReplyDraftEngine.draft                Groq (own opt-in) → on-device (plain text; guided JSON only when a subject is needed) → template
  └─ ReplyFieldEditor.insert               plan range → AX write (verified) → paste fallback; history for Undo
```

Every step except the live AX reader and the field writer is pure and has headless tests.

## Detection and parsing

- **Kind.** The bundle id decides native apps: Mail, Outlook, Slack, WhatsApp, Messages, Teams and Discord. In browsers, the page URL decides (`mail.google.com`, `outlook.office.com` / `outlook.live.com`, `app.slack.com`, `web.whatsapp.com`, `teams.microsoft.com`, `linkedin.com`, `discord.com`). If there is no URL, the window title decides, and if nothing matches the kind is generic.
- **Message box.** It is the focused editable field, or an editable field whose label or placeholder looks like a message box ("Message Body", "Message #design", "Type a message", "Write a message…", "iMessage"). Fields for search, To, Cc, Bcc and Subject are never chosen.
- **Reply windows without a thread.** Apple Mail and Outlook open replies in their own window. When no message is found outside the message box, the quoted message inside it becomes the conversation, with the author taken from "On …, Sarah Lee <…> wrote:" or "From: Sarah Lee".
- **Conversation pane.** It is the message box's own column, so sidebars, chat lists and Gmail's left navigation drop out. It includes only text above the message box. When the message box sits inside a dialog (Gmail's pop-up composer), only the dialog counts, so the inbox behind it is not treated as a thread.
- **Who wrote what.** This uses the web clients' stable, human-written class names from `AXDOMClassList`:
  - Gmail: `adn`, `gD` (sender), `g3` (date), `hP` (subject), `gmail_quote`
  - Slack: `c-virtual_list__item`, `c-message__sender…`, `c-timestamp`
  - WhatsApp Web: `message-in` and `message-out`
  - LinkedIn: `msg-s-…`
  - Discord: hashed `username_` and `messageContent_` prefixes
  - Teams: Fluent `fui-ChatMessage` and `fui-ChatMyMessage`

  Without classes (native apps, OCR), the parser falls back to text patterns: "Name  10:42 AM" headers for chats, "Name <email>" and date lines for email, and bubble alignment (outgoing on the right) for WhatsApp and Messages. A group without a sender inherits the previous author, like Slack's collapsed messages. Quoted history ("On … wrote:", `>` lines) is removed.
- **"Me".** Your messages are recognized by your name from settings or the macOS full name, by your first name, or by "me" or "You".

## Drafting

- **The model writes the text, and Swift enforces the format.** The on-device model (FoundationModels, through `MeetingAIBackend.onDevice`, using a DynamicGenerationSchema because the `@Generable` macro isn't in the Command Line Tools) returns `{reply, subject?}`. `ReplyDraftCleaner` then:
  - removes "Here's a draft:" and "Subject:" lines, and replaces `[Your Name]` and `[Recipient]` placeholders
  - adds your learned sign-off to emails and removes sign-offs from chat messages
  - removes emoji if you never use them
  - removes echoed quotes
- **Budget.** The on-device context is 4,096 tokens. The conversation gets up to 3,600 characters, newest messages kept first. Space notes get up to 1,200, and the reply gets 450 tokens. If the model reports `contextTooLarge`, it retries once with half the conversation. If it refuses, it retries once with the content-transformation guardrails.
- **Facts.** The instructions forbid inventing dates, prices, links and promises. Space snippets are labeled "use only what is relevant".
- **Regenerate.** The shared backend decodes greedily, so Regenerate sends the previous draft with a "write a clearly different one" hint and uses a sampled on-device request (top-40, temperature 0.85).
- **Subject.** It is filled only when the Subject field exists and is empty. For a reply in an existing thread, the subject is "Re: <thread subject>", not something the model made up.
- **No model.** If Apple Intelligence is off and Groq isn't allowed, `ReplyTemplate` writes a short, honest draft that invents nothing, and the bar says "Basic template".

## Writing into the field, and Undo

- **Range.** The draft replaces one UTF-16 range:
  - your selection, if there is one
  - otherwise your typed notes (before any `-- ` or "Sent from my…" signature)
  - otherwise an empty spot before the signature
  - never the quoted thread: Apple Mail and Outlook keep the replied-to message inside the message box, so the range stops at "On … wrote:", Outlook's "From: / Sent:" header, "-----Original Message-----" and "> " lines, and at an unmarked signature (a last block that starts with your name, or with a sign-off and your name). With such a signature in the box, the draft keeps its sign-off line and leaves the name to the signature.
- **Write order.**
  1. Select the range with `AXSelectedTextRange` and set `AXSelectedText`, then read the value back to verify it. Browsers and Electron apps often report success without changing anything, so they skip straight to step 3, as `TextInserter` does.
  2. For plain text fields, set `AXValue`.
  3. Select the range and paste through `TextInserter`. If the field ignores the selection, use ⌘A (whole field) or ⌘↑ (start of the field).
- **Undo, Redo and new versions.** `ReplyEditHistory` keeps `[original, v1, v2…]`. Every version replaces exactly the range the previous version occupies. That range is found again with `ReplyTextLocator`, which ignores whitespace that rich editors rewrite (NBSPs, paragraph breaks). So Undo brings back the original text exactly and never touches the quoted thread or the signature. If you edited the reply since SparkV wrote it, the text is no longer found and SparkV refuses to overwrite it. For fields that can't be read at all, Undo and Redo use the app's own ⌘Z and ⇧⌘Z.
- **Focus.** The bar is a `.nonactivatingPanel` that refuses key status, so clicking it never takes focus from the other app or its message box.

## Privacy and safety

- SparkV never sends anything and never presses Return. `ReplyKeys.post` only posts allowlisted keys (A, Z, ↑, Delete); Return and Enter are refused. Close leaves the text in the field.
- **On this Mac by default.** Groq is used only behind "Allow Reply Drafter to use my Groq key", which is off by default. While it is off, the keychain is never read.
- **Logs.** The log records only counts, kinds, timings and error categories, never message text, screen content or keys.
- **Screen capture.** It is used only as the fallback, only after the user asked for a draft, and only if permission was already granted (preflight). It captures only the target window, keeps the image in memory, and writes nothing to disk.
- **Clipboard.** The paste fallback restores the clipboard (see `TextInserter`). Copy is an explicit button.

## Known limits

- Class names of web clients can change. When they do, parsing falls back to the layout heuristics, and then to OCR.
- Apps with no AX text and no Screen Recording permission (some Catalyst builds) can't be read. The bar explains this and offers the permission button. Typing a few words into the message box still works, because those words become the intent.
- Native ⌘Z, ⌘A and ⌘↑ use ANSI key codes. Non-QWERTY layouts are fine for ⌘Z in most apps, but this is untested.
