# Localization

SparkV in English, Español, Deutsch and हिन्दी.

## How it works

- `Resources/<lang>.lproj/Localizable.strings` hold the tables; `build.sh`
  copies them into `SparkV.app/Contents/Resources` (see INTEGRATION.md).
  SwiftUI looks every literal `Text`, `Button`, `Toggle`, `Label`, `Picker`,
  `Section`, `.help` and accessibility string up there by itself, including
  interpolations (`Text("Version \(v)")` uses the key `Version %@`).
- `InfoPlist.strings` translate the macOS privacy prompts (camera,
  microphone, calendars…).
- SparkV follows the Mac's language order (System Settings › General ›
  Language & Region). Settings › General › Language, or the gear menu's
  Language submenu, picks a language for SparkV only: it writes the app's own
  `AppleLanguages` (what System Settings › Language & Region › Applications
  does) and offers Restart, because macOS reads it at launch.
- `String.sparkVLocalized` translates SparkV's own fixed text held in a
  `String` (row titles passed to shared components, AppKit menu items). Not
  for user content.

## Keeping it up to date

```
python3 -I Sources/Labs/Localization/Scripts/extract_strings.py Sources /tmp/catalog.json
python3 -I Sources/Labs/Localization/Scripts/check_strings.py            # coverage + specifier check
python3 -I Sources/Labs/Localization/Scripts/check_strings.py --missing hi
plutil -lint Resources/*.lproj/*.strings
```

Rules for translators: keep every `%@`, `%lld`, `%d` and `%%`; when the word
order needs the arguments in another order use positional specifiers
(`%2$@ में से %1$@`). Keep product names (SparkV, Clicky, Spaces, AirDrop,
Liquid Glass, Groq) and keyboard symbols as they are. Keys that glue an
English plural "s" on with a trailing `%@` (`%lld dictation%@`) are
translated as a count-neutral label ("Diktate: %lld") that leaves the
trailing argument out; `String(format:)` ignores unused trailing arguments
and `check_strings.py` accepts exactly that case. Use the Mac's own terms:
Ajustes del Sistema / Systemeinstellungen / सिस्टम सेटिंग्स.

## Coverage

`extract_strings.py` tokenizes each file (comments, nested interpolations,
multi-line calls), so it sees every literal SwiftUI resolves by itself,
including both arms of `?:` / `??` inside `Text(…)`, `Button(…)`, `.help(…)`
and the rest. Of the 2,322 such strings, 2,311 are translated in es, de and
hi. The 11 left in English on purpose: `CLICKY`, `Groq`, `Aa`, `ABC`, `abc`
(names and samples), four keys that glue an English word in through an
argument (`click to %@` with "mute"/"unmute", `on-device model%@` with an
English clause), and two whose English plural suffix sits between other
arguments (`%lld Space%@ · %lld items`); those need a source change first
(INTEGRATION.md step 9).

Component titles: 968 strings are passed as `String` to shared rows and
cards; 165 are translated. They start working as each component adopts
`sparkVLocalized` (INTEGRATION.md step 7 does it for hub tiles), and
`check_strings.py --missing de` lists the rest.

Interpolations become format specifiers by name (`count` → `%lld`, other
values → `%@`). Where the guess differs from the real type, that one string
stays English; it never crashes, and `check_strings.py` verifies every
translation keeps the key's specifiers.

The translations were made by hand and have not been checked by native
speakers; the Groq opt-in texts are the first ones to have reviewed.
