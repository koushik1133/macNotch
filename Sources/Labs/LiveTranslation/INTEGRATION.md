# Live Translation: wiring steps for the lead

Everything lives in `Sources/Labs/LiveTranslation/`. No existing file was edited. Follow these steps in order.

## 1. build.sh

Add this line next to the other `cp Sources/Labs/...` lines:

```zsh
cp Sources/Labs/LiveTranslation/*.swift "$WORK/src/"
```

Also add `LiveTranslation` to the folder list in any typecheck script (`Sources/Labs/{...,LiveTranslation}/*.swift`).

No new frameworks, Info.plist keys or entitlements are needed:
- Translation, NaturalLanguage and FoundationModels are system frameworks that autolink.
- The app is already unsandboxed, so the Groq request needs no network entitlement.
- No new privacy permission is involved, because captions come from the meeting transcript, which already has microphone and screen-audio consent.

## 2. NotchWindowController.swift

Add the property next to `meetingAssistant`:

```swift
    private let liveTranslation: LiveTranslationController
```

In `init()`, right after `meetingAssistant = MeetingAssistant(activities: activities)`:

```swift
        liveTranslation = LiveTranslationController(activities: activities)
```

After `super.init(window: panel)`, next to the other closures, add:

```swift
        liveTranslation.attach(to: meetingAssistant)
```

In the `root` chain, after `.environmentObject(meetingAssistant)`:

```swift
            .environmentObject(liveTranslation)
```

In `tearDown()`, before `meetingAssistant.shutdown()`. This saves the translated transcript and closes the caption and download windows.

```swift
        liveTranslation.stop()
```

`attach(to:)` is all the hookup there is. It subscribes to `meetingAssistant.$phase`, which starts and ends a session, and to `meetingAssistant.$current`. The live transcript is `current.segments`. `MeetingAssistant.ingest(_:)` appends each new segment and replaces a volatile segment in place (same id) with its final version, and every change republishes `current`. MeetingAssistant needs no new hook.

## 3. Settings (gear menu): NotchNookLayoutView.swift → `SettingsMenu`

Add the environment object:

```swift
    @EnvironmentObject private var liveTranslation: LiveTranslationController
```

Inside `Menu("Meetings") { ... }`, after the `Toggle("Allow Meeting Notes to Use My Groq Key", ...)` line:

```swift
                Divider()
                LiveTranslationMenu(controller: liveTranslation)
```

The submenu contains:
- Translate Meetings Live (on/off, default off)
- Translate To (language picker)
- Others Speak (Same as This Mac, or a speech locale such as Spanish (Spain); used by the hook in step 4)
- Show Under the Notch
- Show Caption Window
- Show Original Text
- Translate My Own Speech
- Allow Live Translation to Use My Groq Key (default off)
- Download Languages for On-Device Translation… (shown only when needed)
- Open Caption Window
- Add Translation to Meeting Notes

## 4. Transcriber hook: "Others Speak" (recommended, two small edits)

MeetingTranscriber always listens in `Locale.current`. On an English Mac, a participant speaking Spanish is transcribed by the English model, so there is little left to translate. Teams handles this with a "meeting spoken language" setting, and **Others Speak** is the same setting. `LiveTranslationSpokenLanguage.transcriberLocale(speakerLabel:)` returns the chosen locale for the `others` stream only, and only while Live Translation is on. Otherwise it returns nil, so nothing changes for anyone who doesn't use the feature. The new locale takes effect at the next recording.

In `Sources/MeetingTranscriber.swift`, `MeetingAnalyzerEngine.make(label:onPhrase:onFailure:)`, replace the first guard:

```swift
        let wanted = LiveTranslationSpokenLanguage.transcriberLocale(speakerLabel: label) ?? Locale.current
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            AppLog.log("Meeting[\(label)]: SpeechTranscriber unavailable for \(wanted.identifier)")
            return nil
        }
```

In `MeetingLegacyEngine.init(label:clock:onPhrase:onFailure:)`, replace the recognizer guard's first line:

```swift
        let wanted = LiveTranslationSpokenLanguage.transcriberLocale(speakerLabel: label)
        guard let recognizer = wanted.flatMap({ SFSpeechRecognizer(locale: $0) }) ?? SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
```

A missing SpeechTranscriber model for that locale is already handled by the existing code: it is downloaded in the background, and the meeting falls back to SFSpeechRecognizer, which is still on device (`requiresOnDeviceRecognition = true`). Without this hook, Live Translation still works, but only when the speech recognizer for the Mac's language happens to produce text in another language.

## 5. Optional: button in the Meeting Notes window

`MeetingNotesWindow` gets only the assistant. To add a button there, pass the controller into `MeetingNotesWindowController` and call:

```swift
Button("Add Live Translation") {
    Task { await liveTranslation.addToMeetingNotes(meetingID: meeting.id) }
}
```

For a past meeting, this loads the saved translation from `~/Library/Application Support/SparkV/LiveTranslation/<meeting id>.json`.

## 6. Nothing else

- **Hotkeys:** none.
- **Agents hub tile:** none needed. The feature runs only during a recorded meeting.
- **Band under the notch:** the controller posts it itself as activity `meeting.translation`:
  - priority 66, height 48, no expiry
  - posted when the first caption arrives (and only 10 s or more after the recording starts, so the "Let participants know you're recording" reminder stays visible)
  - dismissed after 9 s without new speech, which hands the notch back to the recording band (priority 65)
  - suggested answers (80) and notifications (70) still show on top of it
