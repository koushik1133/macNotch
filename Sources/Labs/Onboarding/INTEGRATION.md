# Onboarding and permissions: wiring steps for the lead

Everything lives in `Sources/Labs/Onboarding/` and `Scripts/create-signing-identity.sh`. No existing file was edited. The module depends only on `AppLog`. It does not touch any other controller.

## Why SparkV says Accessibility is missing after you allowed it

`build.sh` signs ad hoc when no certificate exists. The designated requirement of an ad-hoc app is its exact code hash:

```
$ codesign -d -r- build/SparkV.app
designated => cdhash H"a2150f3d99ae8877724b778a7d6104b45fe4ab2b"
```

TCC stores each grant together with that requirement. Every rebuild produces a new hash. The old SparkV row in System Settings › Accessibility (and Screen Recording) keeps its switch on, but it no longer matches the running binary, so `AXIsProcessTrusted()` returns false. Signed with a certificate, the requirement becomes `identifier "com.sparkv.app" and certificate leaf = H"…"`, which every later build satisfies. This was verified in the scratch tests: two different binaries signed with a test certificate had the same requirement.

The user fixes it once:

1. `./Scripts/create-signing-identity.sh`, which creates "NotchIsland Developer" in the login keychain. It is idempotent.
2. `./build.sh`. The log ends with `Signed with: NotchIsland Developer`.
3. In System Settings › Accessibility and Screen Recording, remove SparkV with − and add `build/SparkV.app` again. This is the last time.

Until then, the Permissions window spots the stale grant and offers buttons that fix it.

## 1. build.sh: compile the folder

Add this next to the other `Labs` lines:

```zsh
cp Sources/Labs/Onboarding/*.swift "$WORK/src/"
```

No new frameworks or linker flags are needed. The module imports AVFoundation, CoreBluetooth, EventKit, Speech, UserNotifications, ApplicationServices and Security, all of which are already linked through autolinking.

Info.plist already has every usage string the checklist needs: Camera, Microphone, Speech, Calendars (full access), Bluetooth, Downloads and Apple Events. Notifications need none. The entitlements already include camera, audio-input, calendars and apple-events.

## 2. AppDelegate.swift: show on first launch

In `applicationDidFinishLaunching`, right after `notchController = controller`:

```swift
        // First launch / new terms version / Accessibility grant that
        // belonged to an earlier build: Welcome → Terms → Permissions.
        OnboardingController.shared.showIfNeeded()
```

`shouldShowOnLaunch` is true when:
- terms were never accepted, or `OnboardingTerms.version` was raised, or
- Accessibility worked for an earlier build (its cdhash is remembered) and doesn't work for this one. This opens straight to Permissions with the fix card, at most once per build.

## 3. NotchNookLayoutView.swift: menu items

In `SettingsMenu`, just above `Button(FaceUnlock.isSetUp ? …`:

```swift
            OnboardingMenuItems()
```

This adds "Permissions & Setup…" and "Terms & Privacy…". It uses `OnboardingController.shared`, so no environment object is needed.

## 4. Optional: react when a permission turns on

While the window is open, statuses refresh every second. When any permission becomes allowed, the module posts `OnboardingController.permissionsDidChange` on the main thread. Features that currently poll, such as "Notifications: waiting for Accessibility", can listen for it and start right away:

```swift
NotificationCenter.default.addObserver(forName: OnboardingController.permissionsDidChange, object: nil, queue: .main) { _ in … }
```

## What it stores (UserDefaults, `SparkV.onboarding.*`)

| Key | Meaning |
|---|---|
| `termsVersion` / `termsAcceptedAt` | accepted terms version and date |
| `completedAt` | when Done was clicked |
| `downloadsRequested` | the Downloads row was clicked (only then is the folder read for status) |
| `accessibilityTrustedBuild` / `…IsAdHoc` | cdhash of the last build that had Accessibility |
| `staleNoticeBuild` | build for which the stale-grant window already opened on launch |

## Behavior notes

- Nothing prompts unless the user clicks. Statuses use non-prompting APIs: `AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, `authorizationStatus` calls, `UNUserNotificationCenter.notificationSettings`, and `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` on a background queue.
- Automation can only be checked while the target app runs. "Open Mail…" launches the app without activating it, then asks.
- Downloads: SparkV isn't sandboxed, so there is no security-scoped bookmark. The first read of `~/Downloads` (off the main thread) shows the TCC prompt.
- Screen Recording applies after a restart. After the user clicks Allow, the row shows "Restart SparkV". That button relaunches the app, and only on a click.
- In the stale-grant card, "Remove Old Entry & Ask Again" runs `tccutil reset Accessibility com.sparkv.app`, which affects SparkV only, then prompts. "Open Accessibility & Show SparkV" opens the pane, selects the app in Finder and shows a floating drag card. Users can drag the icon straight into the list, as the PermissionFlow library does.
- Screen Recording goes stale the same way. Its row also has "Already on in System Settings?"; the card then covers it too, and the reset button also runs `tccutil reset ScreenCapture com.sparkv.app` (SparkV only) and asks again with `CGRequestScreenCaptureAccess()`. The row then offers "Restart SparkV".
- "Restart SparkV" starts a tiny `/bin/sh` helper that waits (up to 30 s) until this process has really exited, then runs `open build/SparkV.app`. Quitting can take a few seconds while a screen recording is saved (`applicationShouldTerminate` returns `.terminateLater`), so a fixed delay would only re-activate the copy that is still quitting.
- Automation consent requests run on their own queue; the once-a-second status checks never wait behind an open consent alert. While the Downloads alert is up, the folder isn't read a second time.
- A row stops showing "Waiting…" as soon as its permission reads as allowed, even when the request's callback never returns (Bluetooth, or an alert left open while the switch was flipped in Settings).
- `OnboardingCodeIdentity.current()` shows how the build is signed. The footer note says whether grants survive rebuilds.
