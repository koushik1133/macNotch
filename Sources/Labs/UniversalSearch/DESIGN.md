# Universal Search: design note

One box searches Spaces, meeting notes, Flow history and notes, clipboard
history and the Tray. A mic button dictates the query, and an Ask mode
answers questions with citations, on device.

## How shipping tools do it (research), and what we copied

| Product | What we took |
|---|---|
| **Raycast** root search ([manual: search bar](https://manual.raycast.com/search-bar), [keyboard shortcuts](https://manual.raycast.com/keyboard-shortcuts), [v1.40 changelog](https://www.raycast.com/changelog/macos-v1/1-40-0)) | <ul><li>Fuzzy matching: letters can be typed out of position ("ftime" → FaceTime).</li><li>Ranking that learns from what you open, and from the search term (or a prefix of it) you typed when you opened it.</li><li>A sensitivity threshold.</li><li>↑↓ and ⌃N/⌃P move the selection; ⌘↑/⌘↓ jump between sections.</li><li>Esc closes; ⇥ hands the query to AI ("Quick AI"); an action bar with ↩ and ⌘↩.</li><li>Back to an empty box after a while ("pop to root", 90 s here).</li></ul> |
| **Alfred** | <ul><li>⌥Space as the default hotkey.</li><li>"Knowledge": the item you picked for a query comes first the next time you type that query.</li></ul> |
| **Spotlight** | <ul><li>A "Top Hit" row, then one section per category.</li><li>Title-prefix matches rank first.</li><li>Esc first clears the box, then closes.</li><li>The panel sits in the upper part of the screen.</li></ul> |
| **Rewind / Limitless** "Ask" | <ul><li>Full-text search over meeting transcripts, with excerpts around the hit.</li><li>Scoping by source and date.</li><li>Natural-language answers that cite the retrieved items (retrieve first, then answer only from those items).</li></ul> |
| **fzf** ([src/algo/algo.go](https://github.com/junegunn/fzf/blob/master/src/algo/algo.go), MIT, © Junegunn Choi) | <ul><li>The scoring model: the same constants (match 16, gap −3/−1, boundary 8, whitespace boundary 10, delimiter 9, camelCase 7, consecutive 4, first character ×2) and the same character classes.</li><li>The V1 forward scan plus backward shortening.</li><li>An exact-substring pass that keeps the best-scoring occurrence.</li><li>AND matching of space-separated terms (extended search).</li></ul> |
| **Mozilla Places frecency** | Recency buckets for frecency: 4 days 100, 14 days 70, 31 days 50, 90 days 30, older 10. |
| **Cindori FloatingPanel / Raycast** | <ul><li>A non-activating `NSPanel`: it takes keystrokes but the app you were in stays frontmost, so ⌘↩ "Paste" lands there.</li><li>Clicking outside closes it.</li></ul> |

fzf's scoring was reimplemented in Swift (`UniversalSearchFuzzy.swift`) rather
than vendored: fzf is Go. The credit is in the source header. No proprietary
code, assets or names are used. All icons are SF Symbols.

## Architecture

```
DataSource (stores → Sendable snapshot)       Actions (side effects)
          │                                          ▲
UniversalSearchCorpus.build ─► [Document] ──► UniversalSearchEngine.search ─► sections
  (detached task; folds text once)                (detached task per keystroke)
                                   ▲                      │
                 UniversalSearchKnowledge (frecency +     ▼
                 remembered picks, JSON)      UniversalSearchController (@MainActor)
                                                          │
                     ┌────────────────────────────┬───────┴──────────────┐
          UniversalSearchPanel(Controller)  UniversalSearchDrawerView  UniversalSearchSettingsMenu
          (+ UniversalSearchPanelView)       (Agents hub)               (gear menu)
```

- **Corpus.** One `UniversalSearchDocument` per item. Folded copies are made
  once, and kept as a `String`, a `[Character]` and UTF-8 bytes:
  - The title and keywords are matched fuzzily.
  - The body is matched as text (word prefix, then substring) with `memmem`
    over folded UTF-8. Fuzzy matching over long text only matches noise;
    Raycast and Alfred also match fuzzily on titles only.

  Background work goes through `UniversalSearchBackground.run`, which cancels
  the detached task when the caller is cancelled. A plain `Task.detached`
  ignores its parent's cancellation, so each superseded keystroke's search
  would otherwise scan the whole corpus to the end.

  The corpus is rebuilt off the main thread when any store publishes, and
  only while the panel or drawer is visible. When neither is visible, it is
  marked dirty and rebuilt on the next open.
- **Ranking:** the sum of the term scores, plus:
  - a phrase bonus (+40 when the title starts with the query, +24 when the title contains it, +14 when the body contains it);
  - a recency boost of up to +18, with a two-week half-life;
  - frecency, log-scaled and capped at +30;
  - a remembered-query boost of up to +120 for an exact query, 60 % of that for a prefix.

  Single-letter terms must start a word. Two-letter terms must be adjacent or
  both start words.
- **Spaces semantic search.** `SpaceStore.search` (FTS plus embeddings) runs
  200 ms after the instant results. Its extra hits are merged in and labelled
  "Related".
- **Ask.** Retrieval works like the search, but any non-stopword term can
  match (OR), and it adds two semantic Space hits. Up to 8 numbered sources are
  sent: windows of text around the query terms, about 6,000 characters in all,
  because the model has a 4k-token context.
  - Backends are tried in order:
    1. the on-device Apple Intelligence model, through `MeetingAIBackend.onDevice` (permissive content-transformation guardrails, since this is the user's own content);
    2. Groq, only when this feature's own toggle is on (off by default) and a Clicky key exists;
    3. an extractive answer: the best sentences, cited.
  - The reply is cleaned up:
    - unknown citations are dropped;
    - `[1, 2]` becomes `[1][2]`;
    - sentences that start with citations or make a source the subject are rewritten as a cited statement. For example, "[1] and [4] confirm the budget is $48,000." (a real on-device reply) becomes "The budget is $48,000 [1][4]." The instructions also ask for citations at the end of sentences.
  - Citations are links (`sparkv-cite://n`) that open the cited item.
- **Drawer.** The view sizes itself to the space the notch gives it. On a
  16-inch MacBook Pro the default drawer is 508×75 pt (32 pt notch inset), so
  it shows the search row and two results; a 160 pt drawer shows four. The
  notch panel has no Edit menu, so the drawer's field handles ⌘V/⌘X/⌘A/⌘Z/⌘C
  itself, through a local key monitor that runs only while that field is
  editing in the key window. An Ask left over from a panel that closed on a
  click outside is reset when the drawer shows.
- **Hotkey.** This reuses `ScreenRegionHotkey` (Carbon `RegisterEventHotKey`,
  the KeyboardShortcuts approach), so it needs no Accessibility permission.
  The default is ⌥Space. Settings offers presets and a recorder; a combination
  another app already owns is reported in the menu.
- **Keys.** Arrow keys, ↩, ⇥ and Esc go through the field editor's commands
  (`control(_:textView:doCommandBy:)`). ⌘-keys go through the panel's
  `performKeyEquivalent`. ⌘V, ⌘X, ⌘A and ⌘Z are forwarded to the field editor,
  because this agent app has no Edit menu. ⌘C copies the selected text when
  there is any, otherwise the selected result.

## Privacy and safety

- Search is in memory, on this Mac.
- The only file written is `~/Library/Application Support/SparkV/UniversalSearch/knowledge.json`.
  It holds item ids, open counts and the queries the user picked items for.
  Settings > Search > Clear Search History deletes it. Saves and deletes run
  in order on one serial queue, so a save still in flight can't bring the
  file back after a clear.
- Clipboard items come from `ClipboardController`, which already skips
  concealed/password pasteboard types and excluded apps.
- Ask sends sources to Groq only behind its own opt-in toggle. Nothing is
  logged except error types.
- The prompt tells the model that the sources are data, not instructions.
- Nothing is typed into other apps, except ⌘↩ on a clipboard item. That uses
  `ClipboardController.paste`, the clipboard feature's own Maccy-style paste.

## Tests

The headless harness is in `scratchpad/features2/universal-search/harness/`
(`build-harness.sh`, then `harness-bin <outdir>`). It covers:
- fuzzy and scoring cases;
- query tokens;
- an engine fixture with all five sources;
- controller keyboard, actions, filters, semantic merge, dictation and shortcut recording;
- Ask with an injected model and with the real on-device model;
- performance on 3,900 documents (6.4 MB of transcripts);
- offscreen renders of every panel state and of the drawer.

The tests use a named pasteboard and never register a real hotkey or post
key events.
