# Sharing SparkV with friends

The quickest way today is to build, package and send one file. Friends click through one macOS warning the first time
they open each version you send.
For a plain double-click install with no warning, see [The proper path](#the-proper-path-developer-id--notarization) below.

## 1. You: build, package, send

```sh
./build.sh                          # build/SparkV.app
./Scripts/package-for-friends.sh    # dist/SparkV.dmg, dist/SparkV.zip, dist/SHA256.txt
```

- **SparkV.dmg** (about 29 MB): a disk image holding SparkV, an Applications shortcut and `Read Me First.txt`. Send this one.
- **SparkV.zip**: the same files, for chat apps or mail services that block `.dmg` files. Use the zip the script makes. Some
  zip tools and chat apps that repackage files break the app's signature, and macOS then calls it "damaged".
- Send it by AirDrop, or upload it to iCloud Drive or Google Drive and share the link.
- The script copies only the signed app. Your settings, Spaces, tray files, meeting notes, browser profile, Face Unlock
  enrolment and API keys live in `~/Library` and your keychain, never inside the app. The script also stops if the
  bundle contains anything that looks personal (`.DS_Store`, logs, databases, browser profiles, API keys).

**Updates:** run the same two commands and send the new file (bump `CFBundleShortVersionString` in `Info.plist` so
friends can tell versions apart; the Read Me shows it). Friends quit SparkV (gear icon in the notch > Quit SparkV), drag
the new copy into Applications, choose Replace, and do the Open Anyway step (step 3 below) once more, because macOS
checks every newly downloaded version. Their permissions carry over **as long as you keep signing with the same
"NotchIsland Developer" certificate**, so back it up: Keychain Access > login > My Certificates > right-click
"NotchIsland Developer" > Export (.p12, with a password). If the certificate is lost, or a build falls back to ad-hoc
signing (the script warns you), every friend has to allow every permission again.

## 2. Friends: install (about 2 minutes)

**Needs:** a Mac with Apple silicon (M1 or later) running macOS 15 or later. Intel Macs can't run this build.

1. **Open SparkV.dmg** (or unzip SparkV.zip) and **drag SparkV onto Applications.** Open it from Applications. If you
   start it from the disk image or Downloads, macOS runs it from a hidden temporary copy and permissions don't stick.
2. **Double-click SparkV in Applications.** macOS shows a dialog: *"SparkV" Not Opened. Apple could not verify "SparkV"
   is free of malware…* with **Move to Trash** and **Done** buttons. Click **Done**.
3. **Open System Settings > Privacy & Security** and scroll down to the **Security** section. A line reads
   *"SparkV" was blocked to protect your Mac.* with an **Open Anyway** button next to it. Click it, enter your Mac
   password or use Touch ID, then click **Open Anyway** once more in the dialog that follows.
   - On macOS 15 and later, right-click > Open no longer skips this warning. Open Anyway in System Settings is the way.
   - No Open Anyway button? It shows only for about an hour after you try to open the app. Repeat step 2, then look again.
   - Comfortable with Terminal? This does the same thing: `xattr -dr com.apple.quarantine /Applications/SparkV.app`
4. **Setup window.** SparkV opens its Setup window: Welcome, then Terms, then a **Permissions** checklist (Accessibility,
   Screen Recording, Camera, Microphone, Speech Recognition, Calendars, Notifications, Bluetooth, Downloads,
   Automation). Click **Allow** only for what you use. Everything else keeps working without it. You can reopen it any
   time from the gear icon in the notch > **Permissions & Setup…** (or the Setup tile in the Agents hub).
   - For Accessibility and Screen Recording, macOS opens System Settings. Drag the SparkV icon from the Setup window into
     the list (or click +), switch it on, and restart SparkV when it asks.
   - Each permission is asked **once**. macOS remembers it, also across updates from the same sender.

SparkV has no Dock icon. It lives in the notch: hover over the notch to open it. On a Mac or display without a notch
it sits at the top centre of the screen. The gear icon holds the settings and **Quit SparkV**.

### Optional extras

| Want | Do this |
| --- | --- |
| On-device AI (summaries, recaps, Clicky without a key) | System Settings > Apple Intelligence & Siri > turn on Apple Intelligence (supported regions and languages) |
| Faster AI that can see the screen | Get a free Groq API key at console.groq.com and paste it in Clicky's settings. It stays in your keychain. Without a key, nothing leaves your Mac. |
| UI Audit and Browser Flows | Install Node.js (`brew install node`, or the installer from nodejs.org), then once: `npx playwright-core@1.64.1 install chromium` |

### If something goes wrong

- **"SparkV is damaged and can't be opened."** The download broke the app's signature. Download the .dmg again; don't use a
  zip from another tool, or a file that a chat app repackaged.
- **A permission is on in System Settings, but SparkV says it's missing.** Remove the old SparkV entry with the − button,
  add it again, and restart SparkV. This happens after installing a build signed differently from the last one.
- **SparkV doesn't open at all on an Intel Mac.** Expected: this build is Apple silicon only.

## Why macOS warns, and why only once

- macOS trusts apps signed with a certificate that **Apple** issued (Developer ID) and **notarized**, meaning Apple
  scanned that exact build. SparkV is signed with "NotchIsland Developer", a certificate you made yourself. Your Mac
  trusts it because you told it to. Your friends' Macs have never heard of it, so Gatekeeper blocks the first launch of
  each version you send until the friend clicks Open Anyway.
- The signature still matters on their Macs. It proves the app wasn't changed on the way, and it keeps the same
  identity across your updates, which is why privacy permissions are granted once per friend and survive updates.
- Permissions are per Mac and per user. Nobody can grant them for someone else, so each friend allows them once.

## Licence note: Face Unlock

Face Unlock recognises faces with an ArcFace model converted from InsightFace's `w600k_mbf` weights, which are licensed
for **non-commercial use only**. Giving SparkV to friends for free is fine. **Selling it is not** while that model is
inside: a paid build has to drop Face Unlock, license the model from InsightFace, or switch to a model whose licence
allows commercial use. The glance sources themselves are MIT (`Contents/Resources/glance-LICENSE`).

## The proper path: Developer ID + notarization

This is what makes SparkV open with a plain double-click on any Mac, with no Open Anyway step. You need it before
selling SparkV or sharing it publicly.

1. **Join the Apple Developer Program** (developer.apple.com/programs, 99 USD a year).
2. **Create a "Developer ID Application" certificate:** developer.apple.com > Certificates, IDs & Profiles > + >
   Developer ID Application. Make the request in Keychain Access (Certificate Assistant > Request a Certificate From a
   Certificate Authority), download the certificate and double-click it. Check it with `security find-identity -v -p codesigning`.
3. **Store notary credentials once:** create an app-specific password at account.apple.com, then
   `xcrun notarytool store-credentials sparkv-notary --apple-id you@example.com --team-id ABCDE12345 --password <app-specific>`
4. **Each release:**
   ```sh
   ./build.sh
   DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)" NOTARY_PROFILE=sparkv-notary ./Scripts/notarize.sh
   ```
   `Scripts/notarize.sh` re-signs a copy of the app (nested framework first, then the app with the Hardened Runtime,
   a secure timestamp and `NotchIsland.entitlements`), submits it with `notarytool`, staples the ticket with `stapler`,
   builds the DMG and zip from it, then signs, notarizes and staples the DMG too. `build/` is never modified. Add
   `DRY_RUN=1` to check your setup and see every command without signing or uploading anything.

Switching to Developer ID changes the app's signing identity, so everyone, you included, allows the permissions once
more after that first notarized version. After that they stick again.

## Auto-updates with Sparkle (outline)

[Sparkle 2](https://sparkle-project.org) is the standard updater for apps outside the App Store. Do this after Developer
ID is in place, because updates must be notarized too.

1. **Vendor it.** Download the Sparkle 2 release tarball and put `Sparkle.framework` in `Vendor/Sparkle/`. build.sh has no
   SwiftPM, so it would copy the framework to `Contents/Frameworks/`, link with `-F Vendor/Sparkle -framework Sparkle
   -Xlinker -rpath -Xlinker @executable_path/../Frameworks`, and sign Sparkle's nested `Autoupdate`, `Updater.app` and
   XPC services before the framework. SparkV isn't sandboxed, so the XPC services can be removed.
2. **Keys.** Run Sparkle's `bin/generate_keys` once. The private EdDSA key stays in your keychain, back it up. Add the
   public key to Info.plist as `SUPublicEDKey`, plus `SUFeedURL` (for example `https://sparkv.si/appcast.xml`).
3. **In the app.** Create one `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
   userDriverDelegate: nil)` at launch and add a "Check for Updates…" menu item that calls `checkForUpdates(_:)`.
4. **Each release.** Bump `CFBundleVersion` (Sparkle compares it), run `notarize.sh`, put `SparkV.dmg` in a releases folder,
   run `bin/generate_appcast <folder>` (it signs each update with your EdDSA key), and upload the DMG and `appcast.xml` over
   HTTPS (GitHub Releases plus GitHub Pages, or the sparkv.si site).

Friends on the current, self-signed build still update by hand as described in section 1.
