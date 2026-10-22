# Shortcuts for the action capsules

NotchIsland has two action capsules. Each one runs a built-in action or any shortcut in your
library. This page lists ten shortcuts that work well there and gives the exact steps to build each one.

## Assigning a capsule

- **Right-click a capsule.** The menu has a **NotchIsland** section with the built-ins and a
  **Shortcuts** section listing your library. It also has **Remove from This Button** and
  **Open Shortcuts…**.
- **Or use the gear menu**, then **Button 1: …** or **Button 2: …**.
- A capsule with nothing assigned, or whose shortcut was renamed or deleted (shown in orange), opens the
  same menu when you click it.

The list refreshes when the drawer opens (at most every 30 seconds) and right after you use
**Open Shortcuts…**, so a shortcut you just made appears the next time you hover the notch.

### The two built-ins

- **Dictate** toggles hands-free dictation, the same as double-tapping fn. The capsule turns red and
  reads "Stop Dictation" until you stop it.
- **Capture to Tray** closes the drawer and starts a screenshot selection (drag a region, press Space
  for a window, Esc to cancel). The result lands in the Tray. It needs Screen Recording permission.

If you only want two buttons, these are the defaults. The shortcuts below are for swapping one or both.

## How capsule shortcuts run

These rules come from how NotchIsland runs shortcuts (`/usr/bin/shortcuts run "<name>"`):

- **No input.** The shortcut gets no Shortcut Input, so start with **Get Clipboard**, **Ask for
  Input**, **Find …** or similar.
- **Output is ignored.** End with **Copy to Clipboard**, **Show Notification** or **Show Result**
  so you can see what happened.
- **60-second limit.** Anything slower is stopped and the capsule shows the error.
- **Short names.** The capsule is about 14 characters wide, so "Fix Text" reads better than
  "Clean Up Clipboard With AI".
- **Grant permissions first.** Run each new shortcut once from the Shortcuts app, so its Calendars,
  Notes, Bluetooth or script prompts appear there. A shortcut whose permission prompt can't show
  when it runs from the command line just fails.
- **Script actions.** **Run Shell Script** and **Run AppleScript** need Shortcuts › Settings ›
  Advanced › **Allow Running Scripts**.

## Your library

`shortcuts list` on this Mac shows **App**, **Arrive**, **Arrive 2**, **Charger**,
**Clean Up Clipboard**, **How Many Days Until**, **Location**, **Make GIF**, **New Note with Date**,
**Show Screenshots**, **Shazam shortcut**, **Word of the Day**, **Ok Google**, **New Shortcut** and
**New Shortcut 2**.

- **Clean Up Clipboard**, **Make GIF** and **New Note with Date** already match #1, #6 and #9
  below. Assign them as they are, or rebuild them from the steps to get the improvements.
- **Shazam shortcut** works well on a capsule: identify the song that's playing in one click.
- **How Many Days Until** and **Location** are fine on a capsule if they end in a notification or
  result.
- **Arrive**, **Arrive 2** and **Charger** read like personal automation shortcuts (arriving
  somewhere, plugging in). They are better left as automations than put on a button.
- **App**, **New Shortcut** and **New Shortcut 2** look like drafts. Rename them before assigning,
  because the capsule shows the shortcut's name.

---

## 1. Fix Text: AI clean-up of the clipboard (Apple Intelligence)

**Why:** copy a messy paragraph, click the capsule, and paste back a clean version. It fixes typos,
tone and structure without opening a chat window.
**Needs:** macOS 26 or later with Apple Intelligence turned on. On-device needs no network, and
Private Cloud Compute stays private.

**Version A: Use Model** (most control)
1. **Get Clipboard**.
2. **Use Model**. Set the model to **On-Device**, or **Private Cloud Compute** for long text. Prompt:
   `Rewrite the following text so it is clear and correct. Fix spelling, grammar and punctuation,
   keep my meaning and tone, keep the same language, and return only the rewritten text:` followed by
   the **Clipboard** variable. Turn **Follow Up** off.
3. **Copy to Clipboard**, with the **Response** from Use Model.
4. **Show Notification** with "Clipboard cleaned up ✨" (optional).

**Version B: Writing Tools** (no prompt to write)
1. **Get Clipboard**.
2. One of the Apple Intelligence Writing Tools actions. Search the action list for **Proofread**,
   **Rewrite**, **Make Concise** or **Adjust Tone** (Friendly or Professional).
3. **Copy to Clipboard**.

**Variations:** change the prompt to "Turn this into bullet points", "Reply to this email politely",
or "Explain this code in two sentences" for one-click helpers. Your existing **Clean Up Clipboard** can
be upgraded by swapping its middle step for **Use Model**.

## 2. Translate: translate the clipboard

**Why:** read a foreign message, or answer one, without opening a browser.
**Needs:** nothing extra. Download languages in Translate for offline use.

1. **Get Clipboard**.
2. **Translate Text**. Set **From** to **Detect Language** and **To** to your language, for example
   English.
3. **Copy to Clipboard**.
4. **Show Result** with the translated text, so you can read it right away.

**Variation:** add **Choose from Menu** before step 2 with options such as "→ English" and
"→ Spanish". Put a **Translate Text** with the matching target in each branch, so one capsule
covers both directions.

## 3. Focus: toggle Do Not Disturb or a Focus

**Why:** one click before a call or a deep-work block, and one click to come back.
**Needs:** nothing.

1. **Set Focus**. Choose **Do Not Disturb**, or your **Work** focus, and change **Turn On** to
   **Toggle**.
2. **Show Notification** with "Focus toggled" (optional).

If your macOS has no **Toggle** option:
1. **Get Current Focus**.
2. **If** *Current Focus* **has any value**:
   **Set Focus** › **Turn Do Not Disturb Off**.
   **Otherwise**: **Set Focus** › **Turn Do Not Disturb On** › **Until Turned Off** (or **For 1 hour**).
3. **End If**.

## 4. Dark Mode: toggle the appearance

**Why:** switch to dark when the room is dim, or back to light for a screen share, without opening
Control Center.
**Needs:** nothing.

1. **Set Appearance**. Change it to **Toggle** (it reads "Toggle Light/Dark Appearance").

That one action is the whole shortcut. NotchIsland always draws dark, so the island won't change, but
everything else will.

## 5. Join Meeting: open the next calendar event's link

**Why:** finds the Zoom, Meet, Teams or Webex link in the next meeting and opens it. You don't need
to open Calendar or search the invite.
**Needs:** Calendars access for Shortcuts.

1. **Find Calendar Events** where **Start Date** **is in the next** **2 hours**, and **Is All Day**
   **is not** checked. Sort by **Start Date**, **Oldest First**, **Limit** on, **1** event.
2. **If** *Calendar Events* **does not have any value**: **Show Notification** "No meeting in the next
   2 hours" › **Stop This Shortcut**. **End If**.
3. **Text** containing three variables from the event: **URL**, **Location** and **Notes**. Tap each
   variable and pick the detail. Separate them with new lines.
4. **Match Text** in that Text with this pattern (Case Sensitive off):
   `https://[^\s"<>]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|facetime\.apple\.com)[^\s"<>]*`
5. **If** *Matches* **has any value**: **Get Item from List** › **First Item** of Matches ›
   **Open URLs**. **Otherwise**: **Show Notification** "No meeting link in *Calendar Event*".
   **End If**.
6. Optional: before **Open URLs**, add **Set Focus** › **Do Not Disturb** › **On** › **Until** the
   event's **End Date**.

## 6. Make GIF: turn the latest screen recording into a GIF

**Why:** record a bug or a UI demo with ⇧⌘5, click the capsule, and paste a GIF into Slack, GitHub
or an email. It also goes nicely with the Tray.
**Needs:** nothing. Screen recordings are saved to the Desktop by default. Change the folder in step 1
if yours go elsewhere.

1. **Get Contents of Folder**: **Desktop**.
2. **Filter Files** where **File Extension** **is** `mov`. Sort by **Creation Date**,
   **Latest First**, **Limit** **1**.
3. **Make GIF** from the result, with **Loop Forever** and **Auto Size** on.
4. **Save File** to a folder such as `~/Pictures/GIFs`, with **Ask Where to Save** off.
5. **Copy to Clipboard** with the saved file.
6. **Show Notification** "GIF ready, paste it or press Paste in the Tray".

Then open the Tray and press **Paste** to keep the GIF on the shelf, where you can drag it into
any app. Your existing **Make GIF** can take this role. If it starts by asking for photos, replace that
step with steps 1 and 2.

## 7. Workspace: open a project's apps and URLs

**Why:** one click sets up a coding session with the editor on the repo, the terminal, the issue
tracker and the local server.
**Needs:** nothing for apps and URLs. **Run Shell Script** needs Allow Running Scripts.

1. **Open File**: pick your project folder, and set **App** to your editor (Xcode, Visual Studio
   Code, Cursor and so on). Or, in **Run Shell Script**: `open -a "Visual Studio Code" ~/Code/my-project`.
2. **Open App**: Terminal (or Ghostty, iTerm).
3. **URL** action with one per line: `https://github.com/you/my-project`,
   `https://linear.app/your-team`, `http://localhost:3000`. Then **Open URLs**.
4. **Set Focus** › **Work** › **On** (optional).
5. **Split Screen Between Apps** with the editor and the browser (optional).

Make one per project ("WS · Notch", "WS · Site") and keep your current one on a capsule.

## 8. AirPods: connect and switch audio to them

**Why:** your AirPods sometimes stay attached to your phone. This pulls them to the Mac and switches
the output in one click.
**Needs:** Bluetooth access. The shell version needs Allow Running Scripts and two Homebrew tools.

**Version A: built-in actions** (if your macOS lists them)
1. **Set Playback Destination**: pick your AirPods.
2. **Show Notification** "AirPods connected".

**Version B: shell** (works on any recent macOS)
1. Install the tools once in Terminal: `brew install blueutil switchaudio-osx`. Get your AirPods'
   address with `blueutil --paired`.
2. **Run Shell Script** (shell zsh):
   ```zsh
   export PATH="/opt/homebrew/bin:$PATH"
   blueutil --connect aa-bb-cc-dd-ee-ff   # your AirPods' address
   sleep 3
   SwitchAudioSource -s "Your AirPods Name" -t output
   ```
3. **Show Notification** "AirPods connected".

Add `blueutil --disconnect aa-bb-cc-dd-ee-ff` to a second shortcut, or use **If** with
`blueutil --is-connected`, to make the button a toggle.

## 9. Quick Note: capture a thought into Notes

**Why:** get an idea out of your head without leaving the app you're in. It pairs well with
dictation.
**Needs:** Notes access for Shortcuts. Dictate Text needs Microphone and Speech Recognition for
Shortcuts.

1. **Ask for Input**, type **Text**, prompt "Note". Or use **Dictate Text** to speak it, or
   **Get Clipboard** to save what you copied.
2. **Text**: `Current Date — Provided Input`. Tap Current Date and pick a short format.
3. **Append to Note**: choose a note such as "Inbox". Or use **Create Note** in a folder, which is
   what your **New Note with Date** probably does.
4. **Show Notification** "Saved to Notes".

Tip: the built-in **Dictate** already types wherever your cursor is. Use this shortcut when you want
the note saved without first opening Notes.

## 10. Stash: send things to the Tray from a shortcut

**Why:** NotchIsland has no URL scheme or Shortcuts action, so a shortcut can't add to the Tray
directly. The Tray's **Paste** button reads the clipboard in this order: files, then images, then
text. So a shortcut that puts the right thing on the clipboard is one click away from the shelf.
**Needs:** Automation access (Shortcuts → Safari) for the AppleScript step, and Allow Running Scripts.

**Stash Tab** puts the current Safari page on the clipboard as a link:
1. **Run AppleScript**:
   ```applescript
   tell application "Safari" to return URL of front document
   ```
2. **Copy to Clipboard** with the result.
3. **Show Notification** "Link ready, press Paste in the Tray".

**Stash Clipboard** turns copied text into a file that stays put:
1. **Get Clipboard**.
2. **Save File** to `~/Documents/Stash`, with **Ask Where to Save** off and the name from **Current
   Date**.
3. **Copy to Clipboard** with the saved file, so Paste adds it as a file and not as text.

Then hover the notch, switch to **Tray** and press **Paste**. For screenshots you don't need a
shortcut: **Capture to Tray**, or the Tray's **Capture** button, puts them there directly.

---

## Suggested pairs

| Capsule 1 | Capsule 2 | For |
| --- | --- | --- |
| Dictate | Capture to Tray | Defaults, no setup |
| Fix Text | Translate | Writing and messaging |
| Join Meeting | Focus | Meeting-heavy days |
| Workspace | Make GIF | Building and shipping |
| Dictate | Quick Note | Thinking out loud |
