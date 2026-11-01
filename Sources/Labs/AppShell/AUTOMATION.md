# Controlling SparkV with `sparkv://` links

Shortcuts, scripts and other apps can open `sparkv://` links to open the drawer, start a timer, or show their own live activity on the island. The same list, with Copy and Try buttons, is in SparkV under **Settings › Advanced › Automation Guide…** (also gear menu › Troubleshooting › Automation Guide…).

## Turning it on

Links that only open a window work right away. Everything else needs **Settings › Advanced › Automation › Allow sparkv:// links to change things**, which is **off** by default. While it is off, a blocked link shows a short band on the island that names only the kind of request ("A link asked SparkV to show a live activity", never the link's own text) and says where the switch is, at most every 30 seconds.

Any web page can open a `sparkv://` link, so these rules always apply:

- No link can start the camera, the microphone, a recording, dictation, a shortcut or a script.
- Titles are cut to 60 characters, subtitles to 90. Control and bidirectional-override characters are removed.
- Activity ids are namespaced (`ext.<id>`), so a link can never replace one of SparkV's own activities.
- External activities rank below meetings, notifications, the volume and brightness HUD and recordings.
- Each command (one activity id, one switch) runs at most every 0.25 s. Faster repeats are not lost: the newest one runs when the 0.25 s are up, so the last progress post or "done" of a script always lands.
- At most 20 different activity ids or commands per minute. Updating an activity you already posted never counts against that, and removing one (`dismiss`) is never refused.
- A link never brings back an island that is hidden (full screen, an excluded app in front, screen sharing, hidden by you): `sparkv://open` then reports "The island is hidden right now".
- Switches that send data off the Mac (`update-checks`) or show other apps' content (`notifications`) can be turned off by a link, never on.

## Using links

**Shortcuts:** add the **Open URLs** action and paste a link. Build the link with the **Text** action and variables to pass your own values (for example a title).

**Terminal and scripts:** `open -g` keeps your current app in front:

```sh
open -g "sparkv://timer/start?minutes=25"
open -g "sparkv://activity?id=build&title=Build%20passed&symbol=checkmark.seal.fill&tint=green"
```

Encode spaces as `%20` and `%` as `%25`, or let a tool encode the text, for example `python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "Build passed"`. Shortcuts encodes text for you when you insert a variable into a URL with the **URL Encode** action.

**Other apps:** `NSWorkspace.shared.open(URL(string: "sparkv://…")!)`, AppleScript `open location "sparkv://…"`.

If SparkV isn't running, opening a link starts it; the command runs as soon as launch finishes.

## Commands

### Windows (always allowed)

| Link | Does |
|---|---|
| `sparkv://settings` | Opens Settings on the last pane used. |
| `sparkv://settings/<pane>` or `?pane=<pane>` | Opens a pane: `general`, `island`, `media`, `system`, `activities`, `planner`, `shelf`, `extras`, `appearance`, `accessibility`, `advanced` (also `updates`, `diagnostics`, `automation`, `reset`). |
| `sparkv://about` | About SparkV (version and licenses). |
| `sparkv://diagnostics` | Crash & Hang Reports. |
| `sparkv://meeting/<uuid>` | Opens that meeting in Meeting Notes (links SparkV puts in Reminders and Spaces). |

### Drawer

| Link | Does |
|---|---|
| `sparkv://open?tab=<tab>` or `sparkv://open/<tab>` | Opens the drawer on a tab: `home`, `widgets`, `tray`, `today`, `converter`, `spaces`, `agents`, `flow`, `clicky`, `clipboard`, `focus`, `search`, `downloads`, `fans`, `files`, `reply`, `screen`, `prompt`, `browser`, `jobs`, `ui-audit`, `distance`. Without a tab: the last one. It stays open until the pointer has been over it once (10 s at most). Does nothing while the island is hidden. |
| `sparkv://drawer/close` | Closes the drawer. |
| `sparkv://toggle` (or `sparkv://drawer/toggle`) | Opens or closes it. |

### Timer and Focus

| Link | Does |
|---|---|
| `sparkv://timer/start?minutes=25` | Starts a timer (1 to 600 minutes). `sparkv://timer?minutes=5` works too. |
| `sparkv://timer/pomodoro` | Starts a Pomodoro. |
| `sparkv://timer/pause` | Pauses or resumes. |
| `sparkv://timer/reset` | Resets. |
| `sparkv://focus/start?minutes=50` | Starts a Focus session (`minutes` optional, 5 to 240). |
| `sparkv://focus/end` | Ends it. |

### Your own live activities

```
sparkv://activity?id=<id>&title=<text>&subtitle=<text>&symbol=<sf symbol>&tint=<color>&progress=<0-1 or 40%>&duration=<seconds>&compact=<text>
```

| Parameter | |
|---|---|
| `title` | Required. Up to 60 characters. |
| `subtitle` | Optional second line, up to 90 characters. |
| `id` | Posting again with the same id updates the activity in place (a progress bar that moves). Letters, digits, `.`, `-`, `_`. |
| `symbol` | An SF Symbol name, e.g. `checkmark.seal.fill`, `hammer.fill`, `film.stack`. Unknown names fall back to a generic badge. |
| `tint` | `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `gray`, `white`. In the SparkV Red look every tint shows as the accent red. |
| `progress` | `0.4`, `40` or `40%`. Shows a bar and the percentage; the compact form shows the percentage. |
| `duration` | Seconds, default 6. `0` keeps it until `sparkv://dismiss` (8 hours at most). |
| `compact` | Up to 8 characters beside the notch while the activity rests there (default: the percentage). |

`sparkv://dismiss?id=<id>` (or `sparkv://activity/dismiss?id=<id>`) removes it.

A build script, for example:

```sh
open -g "sparkv://activity?id=build&title=Building&symbol=hammer.fill&progress=0&duration=0"
make && result="Build%20passed&tint=green&symbol=checkmark.seal.fill" || result="Build%20failed&tint=red&symbol=xmark.octagon.fill"
open -g "sparkv://activity?id=build&title=$result&duration=8"
```

### Switches and looks

| Link | Does |
|---|---|
| `sparkv://feature/<name>?on=1` | Turns a feature on (`on=0` off; leave `on` out to toggle). The names in your build are listed under Settings › Advanced › Automation. Built in: `menu-bar-icon`, `update-checks` (off only), `ambient-light`; with the island connected also `now-playing`, `hud`, `battery`, `timer-activity`, `meetings`, `notifications` (off only), `downloads`. |
| `sparkv://appearance?look=sparkv-red` | Switches the look (`apple` or `sparkv-red`). |
| `sparkv://color-picker` | Opens the color picker, when it is part of your build. |
| `sparkv://updates/check` | Opens Software Update. GitHub is contacted only when you click **Check Now** there. |

## What you see when something goes wrong

Settings › Advanced › Automation › **Recent links** lists the last eight links with what happened ("Timer started", "Blocked: Automation is off", "Unknown command", "Missing “title”"). Every link is also written to `~/Library/Logs/SparkV.log` as `Automation: …`.
