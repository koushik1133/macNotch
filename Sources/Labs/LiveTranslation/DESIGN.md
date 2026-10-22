# Live Translation band: design note

While a meeting is recording, SparkV translates what other participants say into the user's language. It shows the translation in the band under the notch and, optionally, in a floating caption window similar to macOS Live Captions. The translated transcript is saved per meeting, and the user can add it to the meeting's notes.

## How production products do it

**Apple Translation** (`Translation.framework`; see developer.apple.com/documentation/translation/translationsession)
- Everything runs on device, using the same models as the Translate app.
- On macOS 15, a `TranslationSession` comes only from SwiftUI's `.translationTask`.
- On macOS 26 and later, `TranslationSession(installedSource:target:)` works without any UI, but it throws when the languages aren't installed.
- Downloads go through `prepareTranslation()` inside `.translationTask`, and the system shows its own consent sheet.
- `LanguageAvailability.status(from:to:)` reports one of three states: installed, supported (downloadable) or unsupported.
- Measured on this Mac (macOS 27):

  | Request | Time |
  |---|---|
  | Cold session (es→en) | 1.8–2.8 s |
  | Warm session, per caption | 0.33–0.8 s |

- The `.lowLatency` strategy (macOS 26.4) returned `notInstalled` for every pair here. SparkV therefore uses it only when `LanguageAvailability(preferredStrategy: .lowLatency)` says the pair is installed.

**Google Meet translated captions / Google Translate "Transcribe"** (research.google/blog/stabilizing-live-speech-translation-in-google-translate; arXiv 2004.03643, "Re-translation versus Streaming for Simultaneous Translation")
- They use *re-translation*: the growing source prefix is translated again from scratch on every update.
- Flicker is controlled by *masking*: the last k words of the translation are hidden until the source sentence ends.
- The authors report this matches or beats streaming models, and masking cut erasure from 2.1 to 0.1 at almost the same quality.

**Microsoft Teams live translated captions** (Teams support pages; Message Center MC1266022)
- Teams detects each speaker's spoken language automatically and updates it as the conversation goes on.
- Each listener picks their own caption language.

**macOS Live Captions**
- A floating, dark, rounded, movable and resizable panel on all Spaces.
- It never takes focus, and it shows the last few lines with the newest at the bottom.

## Decisions for SparkV

1. **Translator order:**
   1. **Apple Translation.** On macOS 26+ SparkV uses a standalone session, cached per language pair. On macOS 15 it uses a bridge: a 1×1 invisible, click-through panel hosts a view whose `.translationTask` closure stays open for the whole meeting and serves queued requests. When the pair changes, SwiftUI cancels that task and opens a new session; jobs queued for the old pair fail cleanly instead of hanging.
   2. **The on-device Apple Intelligence model** (FoundationModels, permissive content-transformation guardrails). It is used when a pair isn't downloaded or Apple Translation fails. Each request uses a fresh session, the next session is prewarmed, and text over 360 characters is split by sentence.
   3. **Groq** (`openai/gpt-oss-20b`, low reasoning effort). It is used only when **Allow Live Translation to Use My Groq Key** is on (default off). The key is read only at that point, and only from Clicky's keychain item.
2. **Incremental re-translation:**
   - Final phrases are translated once, in order, and kept.
   - The phrase still being spoken is re-translated as it grows: at most every 0.6 s with Apple Translation, or every 2 s with a language model, and only for the newest text per speaker.
   - Its last 2 words are masked (for Japanese, Chinese and Thai, the last 4 characters), following Google's mask-k.
   - Finals always go ahead of partials.
   - A late partial never overwrites a final.
   - Results are cached by (source, target, text), so a final whose text matches the last partial is instant.
3. **Source language detection:**
   - `NLLanguageRecognizer`, limited to the 26 languages Translation supports.
   - Short or ambiguous text (for example "sí" or "okay") reuses that speaker's last confident language. With no history, it falls back to the transcriber's language (`Locale.current`, which is what MeetingTranscriber listens in).
   - Speech already in the target language is never sent to a translator. "Same language" means the same language code and script, so en-US speech counts as English for an en-GB reader, while zh-Hans and zh-Hant are different.
4. **Whose speech:** only other participants by default, as in Meet and Teams. **Translate My Own Speech** adds the microphone.
5. **The band:**
   - It replaces the recording band while captions flow, at priority 66, just above recording (65).
   - It keeps the red recording dot and the elapsed time, so the user can still see that the meeting is being recorded.
   - It appears only 10 s or more after recording starts, so the "Let participants know you're recording" reminder stays visible.
   - It returns the notch after 9 s without new speech.
   - It shows a language chip (`ES → EN · Others`) and two lines of caption, truncated at the head so the newest words stay visible.
6. **Caption window:** a non-activating floating panel, 640×150, that remembers its position. It shows each translation with the original underneath (optional), a language menu, Add to Meeting Notes, Copy, and Download Languages… when needed.
7. **Transcript:**
   - It is saved as JSON to `~/Library/Application Support/SparkV/LiveTranslation/<meeting id>.json`. This is deliberately not the Meetings folder, whose loader would treat the file as an unreadable meeting.
   - **Add to Meeting Notes** writes a plain-text block into the meeting's notepad through `MeetingAssistant.setUserNotes(_:meetingID:)`, one line per caption in the form `[mm:ss] Others [ES]: translation`.
   - If the user asks during the meeting, the block is added when the meeting ends, so the minutes are written from the transcript and not from a copy of it.
   - Adding again replaces SparkV's earlier block if it is unchanged; otherwise the new block is appended after the user's own text.
   - When the feature is turned on mid-meeting, only the last 2 phrases are translated live. The rest is backfilled when the user adds the translation to the notes.
8. **Privacy:**
   - Off by default.
   - Translation stays on device unless the user turns on the Groq toggle.
   - Logs record only language pairs, errors and counts, never caption text or keys.

## Hook into MeetingAssistant

`MeetingAssistant` already publishes what is needed:
- `@Published private(set) var phase`: `.recording` starts a session, `.summarizing` drops partials, and `.idle`/`.failed` finish and save.
- `@Published private(set) var current: MeetingRecord?`, whose `segments` is the live transcript. `ingest(_:)` appends new segments and replaces a volatile one in place by id, so every change republishes `current`.

The controller subscribes with Combine (`assistant.$phase`, `assistant.$current`). The pipeline scans only the last few segments on each update, so long meetings stay cheap. No change to MeetingAssistant is needed.

## Spoken language ("Others Speak")

Captions can only be as good as the transcript, and MeetingTranscriber listens in the Mac's own language. Teams asks for the meeting's spoken language for the same reason. The **Others Speak** menu item stores a speech locale (`liveTranslation.othersSpeak`). A two-line hook in MeetingTranscriber (INTEGRATION.md step 4) passes that locale to `SpeechTranscriber.supportedLocale(equivalentTo:)` and `SFSpeechRecognizer(locale:)`, for the others stream only and only while the feature is on. The detector also uses it as the fallback for short text from that stream.

## Robustness (validator pass)

- The pipeline follows every phrase that is still volatile by id, not only the last 6 segments. While a participant keeps talking, the user's own short replies can push the participant's phrase out of the tail window, and its final would otherwise never be translated live.
- `drain()` returns when its task is cancelled, instead of spinning on a cancelled `Task.sleep`.
- On the macOS 15 bridge, a job nobody picks up within 8 s fails with `timedOut`. The pipeline then falls back to another engine and does not wait forever. Whoever removes a job from the queue resumes it, so nothing is resumed twice.
- If a new meeting starts while the last one is still finishing, the last meeting's translation is saved first, and an "add to notes" request for it is still honoured from the saved file. The same happens if the feature is turned off before a meeting whose notes were requested ends.
- `stop()` cancels the worker, the bridge, timers and the prewarmed on-device model session.
- The caption window is anchored to the bottom (newest caption visible when it opens), and failed lines say "Not translated".

## Limits

- The Others Speak hook needs the lead's two-line edit in MeetingTranscriber. Without it, captions depend on what the Mac-language recognizer produces.
- The macOS 15 bridge was exercised on macOS 27 with `forceBridge`. It has not been run on a real macOS 15 machine.

## Credits

No third-party code was vendored. The approach follows Apple's Translation documentation and Google Research's published re-translation and masking method. The icons are SF Symbols (`character.bubble.fill`, `captions.bubble.fill`, `arrow.down.circle.fill`).
