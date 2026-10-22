# Download watcher: wiring steps for the lead

Everything lives in `Sources/Labs/Downloads/`. No existing file was edited. Paste the snippets below to wire it in. The watcher is **off by default** and never touches `~/Downloads` until the user turns it on.

## 1. build.sh: compile the folder

Next to the other `Labs` lines:

```zsh
cp Sources/Labs/Downloads/*.swift "$WORK/src/"
```

There are no new frameworks or linker flags. The folder uses CoreServices (FSEvents), Foundation (NSProgress subscription, xattrs), UniformTypeIdentifiers, SwiftUI/AppKit, and FoundationModels (guarded with `#if canImport` and `#available(macOS 26)`). It calls these existing types: `ActivityCenter`/`LiveActivity`, `NotchMetrics`, `NotchState.Tab`, `ViewFlag`, `AppLog`, `SpaceIngestCenter.file(_:userInitiated:)` and `AirDrop.share(urls:)`.

## 2. NotchState.swift: a tab

Add a case to `NotchState.Tab`, after `case screenDistance`:

```swift
        /// Download watcher: progress, recent downloads, sorting.
        case downloads
```

Add it to the Agents hub set:

```swift
        static let agentTabs: Set<Tab> = [.agents, .uiAudit, .jobs, .screen, .promptRefiner, .browser, .clipboard, .screenDistance, .downloads]
```

The drawer is designed for the tall height (508×114 pt), like the Tray, Converter and Clipboard. Add it to `NotchMetrics.expandedSize(for:)`:

```swift
        CGSize(width: expandedSize.width, height: [.tray, .converter, .clipboard, .downloads].contains(tab) ? trayExpandedHeight : expandedSize.height)
```

## 3. NotchWindowController.swift: create, wire, start, stop

Property, next to `private let clipboard: ClipboardController`:

```swift
    private let downloads: DownloadsController
```

In `init()`, next to `clipboard = ClipboardController(activities: activities)`:

```swift
        downloads = DownloadsController(activities: activities)
```

After `super.init(window: panel)`, next to `converter.onAddToTray = …`:

```swift
        downloads.opensTab = .downloads
        downloads.onAddToTray = { [tray] url in tray.addFile(url) }
        downloads.onOpenTab = { [weak self] in
            self?.state.select(.downloads)
            self?.setExpanded(true)
        }
```

Add the environment object to the root view chain, after `.environmentObject(screenDistance)`:

```swift
            .environmentObject(downloads)
```

Start it after `screenDistance.start()` at the end of `init()` (it only starts watching if the user turned it on earlier):

```swift
        downloads.start()
```

In `tearDown()`, after `screenDistance.stop()`:

```swift
        downloads.stop()
```

`sendToSpaceHandler` defaults to `SpaceIngestCenter.file($0, userInitiated: true)` and `airDropHandler` defaults to `AirDrop.share(urls:)`, so neither needs wiring.

## 4. NotchNookLayoutView.swift: the drawer page

In `NotchNookLayoutView`, add:

```swift
    @EnvironmentObject private var downloads: DownloadsController
```

In the `switch state.tab`, after `case .screenDistance: ScreenDistanceDrawerView()` (the switch must stay exhaustive):

```swift
                        case .downloads: DownloadsDrawerView(controller: downloads)
```

A file dragged over the Downloads tab still flips to the Tray (the `isDropTargeted` rule), which is the right behavior.

## 5. AgentsHubView.swift: hub tile

Add to `agents`, after the Distance (`.screenDistance`) tile:

```swift
        Agent(tab: .downloads, title: "Downloads", systemImage: "arrow.down.circle", tint: .blue),
```

Optionally, update the header icon's help text in `NotchNookLayoutView` (`"Agents: UI audit, jobs, screen, prompts, browser flows, clipboard"`) to end with `", downloads"`.

## 6. Settings (gear menu)

In `SettingsMenu` (`NotchNookLayoutView.swift`), add:

```swift
    @EnvironmentObject private var downloads: DownloadsController
```

Then add a submenu after `Menu("Live Activities") { … }`:

```swift
            Menu("Downloads") {
                Toggle("Watch Downloads Folder", isOn: Binding(get: { downloads.isEnabled }, set: { downloads.setEnabled($0) }))
                Toggle("Show Download Progress Under the Notch", isOn: $downloads.showsActivity)
                    .disabled(!downloads.isEnabled)
                Toggle("Suggest Folders with Apple Intelligence", isOn: $downloads.suggestsWithAI)
                Divider()
                Button("Sorting Rules…") { downloads.openRulesEditor() }
            }
```

There is no Groq toggle. Folder suggestions run only on the on-device model, and no key is ever read.

The same three switches are in the drawer's `…` menu and at the top of the rules window. They're stored in `UserDefaults` under `Downloads.enabled` (default off), `Downloads.showsActivity` (default on) and `Downloads.suggestsWithAI` (default on). Rules are saved in `~/Library/Application Support/SparkV/Downloads/rules.json` and the recent list in `history.json` next to it.

## 7. Info.plist: privacy strings

Turning the watcher on lists `~/Downloads`, which is what makes macOS show its Files & Folders prompt. Sorting into Documents or Desktop can prompt for those folders. Add these keys:

```xml
	<key>NSDownloadsFolderUsageDescription</key>
	<string>SparkV shows download progress under the notch and helps you sort finished downloads. Files only move when you choose a folder or turn on an auto-sort rule.</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>SparkV moves a download into your Documents folder when you sort it there.</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>SparkV moves a download to your Desktop when you sort it there.</string>
```

No entitlements are needed, because the app is unsandboxed. If access is denied, the drawer shows "macOS blocked access to Downloads" with Open Settings and Try Again buttons. Ad-hoc rebuilds drop the grant, so the prompt comes back after each rebuild.

## 8. Optional: a hotkey or menu bar entry

There is no hotkey. To open the drawer from elsewhere, call `downloads.onOpenTab?()`, or open the rules with `downloads.openRulesEditor()`.

## Public API (for other features)

```swift
@MainActor final class DownloadsController: ObservableObject {
    init(activities: ActivityCenter, folder: URL? = nil, defaults: UserDefaults = .standard, storage: URL? = nil)
    func start(); func stop(); func setEnabled(_ on: Bool); func retry()
    var opensTab: NotchState.Tab?; var onOpenTab: (() -> Void)?; var onAddToTray: ((URL) -> Void)?
    var sendToSpaceHandler: (URL) -> Void; var airDropHandler: ([URL]) -> Void
    @Published private(set) var status: Status            // .off .starting .running .denied .failed(String)
    @Published private(set) var items: [DownloadItem]     // newest first, in-flight on top
    @Published private(set) var suggestions: [UUID: DownloadSuggestion]
    @Published var showsActivity: Bool; @Published var suggestsWithAI: Bool
    let rules: DownloadRuleStore
    func open(_:), reveal(_:), addToTray(_:), sendToSpace(_:), airDrop(_:)
    func sortWithSuggestion(_:), sort(id:to:ruleName:automatic:), chooseFolder(for:)
    func undo(_:), undoLast(), forget(_:), clearFinished(), openRulesEditor(), openPrivacySettings()
}
struct DownloadsDrawerView: View { init(controller: DownloadsController) }
```
