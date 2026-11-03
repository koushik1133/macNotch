# Localization: integration

Ships SparkV in English, Spanish (es), German (de) and Hindi (hi), plus a
per-app language picker. Apply the steps in order. Every **Find** block occurs
exactly once in the file named above it; replace it with the **Replace with**
block.

What this package adds (already in the repo, nothing to paste):

| Path | What |
| --- | --- |
| `Resources/en.lproj/Localizable.strings` | English base table, 3,290 keys (key = value) |
| `Resources/{es,de,hi}.lproj/Localizable.strings` | 2,476 translated keys each: 2,311 of the 2,322 strings SwiftUI translates by itself, plus 165 component titles |
| `Resources/{es,de,hi}.lproj/InfoPlist.strings` | The 12 privacy-prompt texts from Info.plist |
| `Sources/Labs/Localization/LocalizationModel.swift` | `SparkVLanguage`, `LocalizationPreferences`, `String.sparkVLocalized` (pure logic) |
| `Sources/Labs/Localization/LocalizationSettings.swift` | `LocalizationController`, `LocalizationSettingsSection`, `LocalizationMenuItems` |
| `Sources/Labs/Localization/Scripts/` | `extract_strings.py`, `check_strings.py` |

Contracts:

- **Settings section:** `LocalizationSettingsSection()` goes in the **General** pane, wrapped in the card lane (step 5). It is a self-drawn card and fills the width it is given.
- **Gear menu:** `LocalizationMenuItems()` (a "Language" submenu with a globe; when SparkV runs in another language the title also says "Language" in English, e.g. "Sprache · Language") goes above Restart / Quit (step 4).
- **Controller:** `LocalizationController.shared` (`@MainActor ObservableObject`, `start()` / `stop()`). The views use `.shared` themselves, so no `.environmentObject` and no NotchWindowController wiring is needed: the Settings section calls `start()` on appear and `stop()` on disappear. `start()` only adds an `NSLocale.currentLocaleDidChangeNotification` observer (no timer, no polling).
- **Hub tile:** none (a language switch is a setting, not an agent).
- **Hotkeys:** none.
- **Network:** none. Translations ship in the bundle.
- **Settings keys:** `localization.language` (SparkV's record of the choice) and the app-domain `AppleLanguages` that macOS reads at launch (removed again for "Same as Mac").

## 1. build.sh: compile the lab

File: `build.sh`

Find:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```

Replace with:
```
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/Localization/*.swift "$WORK/src/"
```

## 2. build.sh: copy the .lproj folders into the bundle

File: `build.sh`

Find:
```
cp Info.plist "$STAGED/Contents/Info.plist"
```

Replace with:
```
cp Info.plist "$STAGED/Contents/Info.plist"
# Translations (Resources/<lang>.lproj: Localizable.strings, InfoPlist.strings).
# SwiftUI looks literal Text/Button/Toggle/Label/.help strings up here.
for LPROJ in Resources/*.lproj(N); do
  cp -R "$LPROJ" "$STAGED/Contents/Resources/"
done
```

## 3. Info.plist: declare the localizations

File: `Info.plist`

Find:
```
	<key>CFBundleDevelopmentRegion</key>
```

Replace with:
```
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>es</string>
		<string>de</string>
		<string>hi</string>
	</array>
	<key>CFBundleAllowMixedLocalizations</key>
	<true/>
	<key>CFBundleDevelopmentRegion</key>
```

`CFBundleAllowMixedLocalizations` lets system-provided UI (open panels,
share sheets) follow the user's language even where SparkV has no table.

## 4. Gear menu: Language submenu

File: `Sources/NotchNookLayoutView.swift`

Find:
```
            // Quits cleanly (the same work as Quit) and opens SparkV again:
```

Replace with:
```
            LocalizationMenuItems()
            // Quits cleanly (the same work as Quit) and opens SparkV again:
```

## 5. Settings › General: the Language card

The General pane is a grouped `Form`; a self-drawn card goes in through
AppShell's card lane (`SettingsCardRow`), which drops the Form's row
background, insets and separators, so there is no card inside a card.

File: `Sources/Labs/AppShell/AppShellSettingsPanes.swift`

Find:
```
            // ▸ General: add sections above this line
```

Replace with:
```
            SettingsCardRow { LocalizationSettingsSection() }
            // ▸ General: add sections above this line
```

## 6. Modes band: one translatable "… on" string

`Text(mode.name) + Text(" on")` glues an English word onto the name, which
German and Hindi need in another order. One interpolated `Text` makes it the
key `%@ on` (already translated: "%@ an", "%@ activado", "%@ चालू"); the name
keeps its own weight and color.

File: `Sources/Labs/Modes/ModeViews.swift`

Find:
```
                    (Text(mode.name).fontWeight(.semibold).foregroundColor(SparkVTheme.text)
                     + Text(" on").foregroundColor(SparkVTheme.textSecondary))
```

Replace with:
```
                    Text("\(Text(mode.name).fontWeight(.semibold).foregroundColor(SparkVTheme.text)) on")
                        .foregroundColor(SparkVTheme.textSecondary)
```

## 7. (Recommended) Agents hub tile titles

Hub tiles receive their titles as `String`, which `Text(title)` shows
verbatim. These three edits route them through the string table; the titles
and help texts are already translated.

File: `Sources/AgentsHubView.swift`

Find:
```
        .help(help ?? title)
        .accessibilityLabel(title)
```

Replace with:
```
        .help((help ?? title).sparkVLocalized)
        .accessibilityLabel(title.sparkVLocalized)
```

File: `Sources/AgentsHubView.swift`

Find:
```
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(isHighlighted || hover.isOn || contrast ? 1 : 0.82))
```

Replace with:
```
            Text(title.sparkVLocalized)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(isHighlighted || hover.isOn || contrast ? 1 : 0.82))
```

File: `Sources/AgentsHubView.swift`

Find:
```
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(lit ? SparkVTheme.text : SparkVTheme.textSecondary)
```

Replace with:
```
            Text(title.sparkVLocalized)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(lit ? SparkVTheme.text : SparkVTheme.textSecondary)
```

## 8. (Recommended) A neutral relaunch log line

Every "Restart SparkV" button (gear menu, Onboarding, Island settings,
Language) goes through `PermissionCenter.relaunch(from:)`, which logs
"relaunching for Screen Recording" whatever the reason. The Language picker
already logs "Localization: restarting to apply <code>" first; this makes
the shared line truthful for every caller.

File: `Sources/PermissionCenter.swift`

Find:
```
        AppLog.log("Permissions: relaunching for Screen Recording (\(feature))")
```

Replace with:
```
        AppLog.log("Permissions: relaunching SparkV (\(feature))")
```

## 9. Pattern for every other package (no anchors, do it as you touch files)

SwiftUI translates a **literal** (`Text("Show Lyrics")`, `Button("Save")`,
`Toggle("…", isOn:)`, `Label("…", systemImage:)`, `.help("…")`,
`.accessibilityLabel("…")`, both arms of `Text(flag ? "On" : "Off")`,
interpolations like `Text("Version \(v)")`) with no code change. It does
**not** translate a `String` variable: shared rows and cards that take
`title: String` and show `Text(title)` stay English. For those, show
`Text(title.sparkVLocalized)` (and the same for `detail`, `subtitle`,
`.accessibilityLabel(title)`). 968 such argument strings are extracted;
165 are translated so far, and `check_strings.py --missing de` lists the rest.

Also avoid gluing English words: `Text(a) + Text(" on")`, or an interpolated
English word such as `"Click to \(muted ? "unmute" : "mute")"`, cannot be
translated well. Use two whole sentences (`muted ? "Click to unmute." :
"Click to mute."`) or one interpolated key.

Never feed user content, file names, AI output or app names through
`sparkVLocalized`: only SparkV's own fixed English text.

## Check

```
plutil -lint Resources/*.lproj/*.strings
python3 -I Sources/Labs/Localization/Scripts/check_strings.py   # 0 specifier mismatches
```
