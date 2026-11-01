import AppKit
import Carbon.HIToolbox
import Combine

/// What the notch band says after a pick (see `ColorPickBand.swift`).
struct CPBandInfo: Equatable, Sendable {
    var color: CPColor
    /// The copied text ("#3B82F6") or a status line.
    var value: String
    /// "Copied", "Copied as SwiftUI", "Background", "Esc cancels" …
    var label: String
    /// "blue-500 · Blue", or nil.
    var detail: String?
    var symbol: String?
    var duration: TimeInterval = 2
}

/// Screen color picker: one shortcut (default ⌃⌥P), one pick, already
/// copied. The system loupe (`CPSystemSampler`) needs no permission; the
/// result is converted to sRGB for hex/rgb/hsl/WCAG (Display P3 values are
/// kept), copied in the default format with an `NSColor` beside the text,
/// announced in a short band, and added to the history (last 30, deduped,
/// UserDefaults `ColorPicker.*`).
///
/// Nothing runs while idle: no timers or polling, only the Carbon hotkey.
/// During a pick a single 20 s watchdog task waits to offer "Reset"; after
/// a copy a 1.2 s task clears the ✓, and after a delete an 8 s task retires
/// Undo.
@MainActor
final class ColorPickerController: ObservableObject {
    /// Where the next pick goes.
    enum Slot: Sendable {
        /// The main color: copied, announced, shown in the drawer.
        case main
        /// The contrast checker's text color.
        case foreground
        /// The contrast checker's background.
        case background
    }

    enum Section: String, CaseIterable, Identifiable, Sendable {
        case formats, contrast, shades, palettes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .formats: "Formats"
            case .contrast: "Contrast"
            case .shades: "Shades"
            case .palettes: "Palettes"
            }
        }
    }

    /// Short-lived "copied" check on the row that was copied.
    struct CopyFeedback: Equatable {
        var key: String
        var serial: Int
    }

    // MARK: Published state

    /// The color the drawer shows (last pick, a history entry, or a pasted color).
    @Published private(set) var current: CPColor?
    @Published private(set) var history: [CPHistoryEntry] = []
    @Published private(set) var palettes: [CPPalette] = []
    @Published var selectedPaletteID: UUID? {
        didSet { store.defaults.set(selectedPaletteID?.uuidString, forKey: CPDefaults.Keys.selectedPalette) }
    }
    @Published var defaultFormat: CPFormat {
        didSet { store.defaults.set(defaultFormat.rawValue, forKey: CPDefaults.Keys.defaultFormat) }
    }
    @Published var options: CPFormatOptions {
        didSet { store.save(options, CPDefaults.Keys.options) }
    }
    @Published var contrast: CPContrastPair {
        didSet { store.save(contrast, CPDefaults.Keys.contrast) }
    }
    @Published var section: Section {
        didSet { store.defaults.set(section.rawValue, forKey: CPDefaults.Keys.section) }
    }
    /// Store the front app's name with each pick (on by default; never a window title).
    @Published var remembersApp: Bool {
        didSet { store.defaults.set(remembersApp, forKey: CPDefaults.Keys.rememberApp) }
    }
    /// Start the loupe with SparkV active (the fallback start, see
    /// `CPSystemSampler`). Off by default; turned on when the user resets a
    /// pick that got stuck, and offered as a menu toggle.
    @Published var compatibilityStart: Bool {
        didSet { store.defaults.set(compatibilityStart, forKey: CPDefaults.Keys.compatibilityStart) }
    }
    @Published private(set) var shortcut: ScreenRegionShortcut
    @Published private(set) var hotkeyEnabled: Bool
    /// Set when macOS refused the shortcut (another app owns it).
    @Published private(set) var hotkeyProblem: String?
    @Published private(set) var isPicking = false
    /// A pick has waited 20 s without an answer: offer Reset.
    @Published private(set) var mayBeStuck = false
    @Published private(set) var copyFeedback: CopyFeedback?
    /// Something to undo (a deleted entry, a cleared history, a deleted
    /// palette or palette color). Retires after `undoLifetime` (8 s).
    @Published private(set) var canUndo = false

    // MARK: Wiring (set by the integrator)

    /// Called right before the loupe shows: collapse the drawer so it can't tint pixels.
    var onWillPick: (() -> Void)?
    /// Opens the drawer on the Color Picker page.
    var onOpenDrawer: (() -> Void)?
    /// Posts the confirmation band (`connect(activities:opensTab:)` sets it).
    var bandPresenter: ((CPBandInfo) -> Void)?

    // MARK: Defaults

    static let historyLimit = CPCollections.historyLimit
    /// ⌃⌥P ("pick"). ⌃⌥C is Quick Capture's; ⌃⌥J/R/S/T/F, ⌃⌥1…5, ⌃⌥Space,
    /// ⌃⌥⇧R, ⌥Space and ⌘⇧V are taken by other SparkV features.
    static let defaultShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey))
    /// Choices offered in the menus (none clashes with SparkV's own shortcuts).
    static let shortcutChoices: [ScreenRegionShortcut] = [
        defaultShortcut,
        ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | optionKey)),
        ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey)),
        ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_I), carbonModifiers: UInt32(controlKey | optionKey)),
        ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey | cmdKey)),
    ]
    nonisolated static let defaultWatchdogDelay: Duration = .seconds(20)
    nonisolated static let defaultUndoLifetime: Duration = .seconds(8)
    /// Formats whose text is too long for the band: it shows the hex and
    /// says "Copied as SwiftUI" instead.
    static let longFormats: Set<CPFormat> = [.displayP3, .swiftUI, .uiKit, .appKit]

    let sampler: CPColorSampling
    let pasteboard: NSPasteboard
    let store: CPDefaults
    let watchdogDelay: Duration
    let undoLifetime: Duration

    private let hotkey = ScreenRegionHotkey()
    private var isRunning = false
    private var pickToken = 0
    private var pickSlot: Slot = .main
    private var pickApp: String?
    private var pickStarted: Date?
    private var pickUsedCompatibilityStart = false
    private var resetArmed = false
    private var watchdog: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var feedbackSerial = 0
    private var loggedSpace = false
    /// Only what was removed, with where it was, so Undo puts it back into
    /// the current lists without dropping anything added since.
    private enum Undo {
        case history([CPHistoryEntry])
        case palette(CPPalette, index: Int, wasSelected: Bool)
        case paletteColor(CPColor, index: Int, paletteID: UUID)
    }
    private var undoState: Undo? { didSet { canUndo = undoState != nil } }
    private var undoExpiry: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general, sampler: CPColorSampling? = nil,
         watchdogDelay: Duration = ColorPickerController.defaultWatchdogDelay,
         undoLifetime: Duration = ColorPickerController.defaultUndoLifetime) {
        let store = CPDefaults(defaults: defaults, report: { AppLog.log($0) })
        self.store = store
        self.pasteboard = pasteboard
        self.sampler = sampler ?? CPSystemSampler()
        self.watchdogDelay = watchdogDelay
        self.undoLifetime = undoLifetime
        defaultFormat = defaults.string(forKey: CPDefaults.Keys.defaultFormat).flatMap(CPFormat.init(rawValue:)) ?? .hex
        options = store.load(CPFormatOptions.self, CPDefaults.Keys.options) ?? CPFormatOptions()
        let savedContrast = store.load(CPContrastPair.self, CPDefaults.Keys.contrast)
        contrast = savedContrast.flatMap { $0.foreground.isWellFormed && $0.background.isWellFormed ? $0 : nil } ?? .initial
        section = defaults.string(forKey: CPDefaults.Keys.section).flatMap(Section.init(rawValue:)) ?? .formats
        remembersApp = defaults.object(forKey: CPDefaults.Keys.rememberApp) as? Bool ?? true
        compatibilityStart = defaults.bool(forKey: CPDefaults.Keys.compatibilityStart)
        hotkeyEnabled = defaults.object(forKey: CPDefaults.Keys.hotkeyEnabled) as? Bool ?? true
        if let saved = store.load(ScreenRegionShortcut.self, CPDefaults.Keys.shortcut), saved.isValidGlobal {
            shortcut = saved
        } else {
            shortcut = Self.defaultShortcut
        }
        let loadedHistory = (store.load([CPHistoryEntry].self, CPDefaults.Keys.history) ?? []).filter { $0.color.isWellFormed }
        history = Array(loadedHistory.prefix(Self.historyLimit))
        palettes = (store.load([CPPalette].self, CPDefaults.Keys.palettes) ?? []).map { palette in
            var clean = palette
            clean.colors.removeAll { !$0.isWellFormed }
            return clean
        }
        selectedPaletteID = defaults.string(forKey: CPDefaults.Keys.selectedPalette).flatMap(UUID.init(uuidString:))
        if let id = selectedPaletteID, !palettes.contains(where: { $0.id == id }) { selectedPaletteID = palettes.first?.id }
        current = history.first?.color
        hotkey.onPress = { [weak self] in self?.pickColor() }
    }

    // MARK: Lifecycle

    /// Registers the global shortcut. Nothing else starts.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        updateHotkey()
    }

    func stop() {
        isRunning = false
        hotkey.unregister()
        watchdog?.cancel()
        watchdog = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        undoExpiry?.cancel()
        undoExpiry = nil
    }

    func setHotkeyEnabled(_ enabled: Bool) {
        hotkeyEnabled = enabled
        store.defaults.set(enabled, forKey: CPDefaults.Keys.hotkeyEnabled)
        updateHotkey()
    }

    /// False when the shortcut needs ⌃, ⌥ or ⌘, or macOS refused it.
    @discardableResult
    func setShortcut(_ new: ScreenRegionShortcut) -> Bool {
        guard new.isValidGlobal else { return false }
        shortcut = new
        store.save(new, CPDefaults.Keys.shortcut)
        updateHotkey()
        return hotkeyProblem == nil
    }

    /// The shortcut is registered while it is on, and during every pick even
    /// when it is off: a stuck loupe holds every click, so the shortcut is
    /// the one way to reset it.
    private func updateHotkey() {
        guard isRunning, hotkeyEnabled || isPicking else {
            hotkey.unregister()
            hotkeyProblem = nil
            return
        }
        if hotkey.isRegistered, hotkey.shortcut == shortcut { return }
        if hotkey.register(shortcut) {
            hotkeyProblem = nil
        } else {
            hotkeyProblem = "\(shortcut.displayString) is used by another app"
            AppLog.log("Color Picker: \(shortcut.displayString) is taken")
        }
    }

    /// "⌃⌥P", or "" while the shortcut is off.
    var shortcutLabel: String { hotkeyEnabled ? shortcut.displayString : "" }

    /// True while the global shortcut is live (also during a pick with the
    /// shortcut turned off).
    var isHotkeyRegistered: Bool { hotkey.isRegistered }

    // MARK: Picking

    /// Hotkey, hub tile and menu entry point. While a pick is open a second
    /// press says so; a third resets a stuck sampler.
    func pickColor(into slot: Slot = .main) {
        if isPicking {
            handleRepeatedPick()
            return
        }
        isPicking = true
        mayBeStuck = false
        resetArmed = false
        pickSlot = slot
        pickStarted = Date()
        pickToken &+= 1
        let token = pickToken
        pickApp = remembersApp ? Self.frontAppName() : nil
        pickUsedCompatibilityStart = compatibilityStart
        updateHotkey()
        // Out of the way first, so the drawer can't tint the pixels under the loupe.
        onWillPick?()
        watchdog?.cancel()
        watchdog = Task { [weak self, watchdogDelay] in
            try? await Task.sleep(for: watchdogDelay)
            guard !Task.isCancelled, let self, self.isPicking, self.pickToken == token else { return }
            self.loupeMayBeStuck()
        }
        sampler.sample(activating: compatibilityStart) { [weak self] color in
            self?.finishPick(color, token: token)
        }
    }

    /// 20 s without an answer. The loupe may simply be open, or it may be
    /// holding every click: say how to get out either way. The way out is
    /// the band's label, which never truncates.
    private func loupeMayBeStuck() {
        mayBeStuck = true
        AppLog.log("Color Picker: no answer from the sampler after \(watchdogDelay)")
        let label = hotkey.isRegistered ? "Stuck? Press \(shortcut.displayString) to reset" : "Stuck? Use Reset Picker"
        bandPresenter?(CPBandInfo(color: current ?? .white, value: "Picker still open", label: label,
                                  detail: "Esc cancels", symbol: "exclamationmark.triangle", duration: 6))
    }

    private func handleRepeatedPick() {
        let open = Date().timeIntervalSince(pickStarted ?? Date())
        if resetArmed || mayBeStuck {
            resetPicker()
            return
        }
        // A quick double press is just impatience; ignore it.
        guard open > 1 else { return }
        resetArmed = true
        bandPresenter?(CPBandInfo(
            color: current ?? .white, value: "Picker still open", label: "Esc cancels",
            detail: "press \(shortcut.displayString) again to reset", symbol: "eyedropper", duration: 4
        ))
    }

    /// Ends a stuck pick (offered after 20 s, or on a repeated shortcut).
    /// Resetting an open pick that started without activating SparkV turns
    /// on the compatibility start for later picks.
    func resetPicker() {
        let wasPicking = isPicking
        sampler.reset()
        pickToken &+= 1
        endPick()
        if wasPicking, !pickUsedCompatibilityStart, !compatibilityStart {
            compatibilityStart = true
            AppLog.log("Color Picker: reset a pick that started without activating SparkV; later picks use the compatibility start")
        }
        bandPresenter?(CPBandInfo(color: current ?? .white, value: "Color picker reset", label: "",
                                  detail: nil, symbol: "arrow.counterclockwise", duration: 2))
    }

    private func endPick() {
        isPicking = false
        mayBeStuck = false
        resetArmed = false
        pickStarted = nil
        watchdog?.cancel()
        watchdog = nil
        // Drops the shortcut again if it is off and was only held for the pick.
        updateHotkey()
    }

    /// The sampler's answer (nil after Esc: no band, nothing copied).
    func finishPick(_ picked: NSColor?, token: Int) {
        guard token == pickToken else { return }
        let slot = pickSlot
        let app = pickApp
        endPick()
        guard let picked else {
            AppLog.log("Color Picker: cancelled")
            return
        }
        guard let color = picked.cpColor, color.isWellFormed else {
            AppLog.log("Color Picker: the sampler returned a color without usable RGB components")
            return
        }
        let space = picked.cpSpaceName
        if !loggedSpace {
            loggedSpace = true
            AppLog.log("Color Picker: sampler colors arrive in \(space ?? "an unnamed space")")
        }
        accept(color, slot: slot, space: space, app: app)
    }

    /// Applies a picked color (also the seam the tests use).
    func accept(_ color: CPColor, slot: Slot = .main, space: String? = nil, app: String? = nil) {
        let opaque = CPColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        guard opaque.isWellFormed else {
            AppLog.log("Color Picker: ignored a color that isn't finite or is far outside any display")
            return
        }
        addToHistory(CPHistoryEntry(color: opaque, date: Date(), sourceSpace: space, appName: app))
        switch slot {
        case .main:
            current = opaque
            let format = defaultFormat
            let text = copy(opaque, as: format, feedbackKey: nil)
            if Self.longFormats.contains(format) {
                bandPresenter?(CPBandInfo(color: opaque, value: opaque.hexString, label: "Copied as \(format.title)",
                                          detail: bandDetail(opaque, includesTailwind: true)))
            } else {
                bandPresenter?(CPBandInfo(color: opaque, value: text, label: "Copied",
                                          detail: bandDetail(opaque, includesTailwind: format != .tailwind)))
            }
        case .foreground:
            contrast.foreground = opaque
            bandPresenter?(CPBandInfo(color: opaque, value: opaque.hexString, label: "Text color",
                                      detail: "contrast " + CPContrast.ratioText(CPContrast.ratio(opaque, contrast.background))))
        case .background:
            contrast.background = opaque
            bandPresenter?(CPBandInfo(color: opaque, value: opaque.hexString, label: "Background",
                                      detail: "contrast " + CPContrast.ratioText(CPContrast.ratio(contrast.foreground, opaque))))
        }
    }

    private func bandDetail(_ color: CPColor, includesTailwind: Bool) -> String {
        var parts: [String] = []
        if includesTailwind {
            let tw = CPTailwind.nearest(color)
            parts.append((tw.isExact ? "" : "≈ ") + tw.name)
        }
        parts.append(CPColorFamily.name(color))
        if !color.isInSRGBGamut { parts.append("outside sRGB") }
        return parts.joined(separator: " · ")
    }

    private static func frontAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app.localizedName
    }

    // MARK: Formats and copying

    /// The text `copy` puts on the clipboard.
    func text(_ color: CPColor, _ format: CPFormat) -> String {
        CPFormatter.string(color, format, options: options)
    }

    /// What rows and menus show (a nearest Tailwind class reads "≈ red-500").
    func displayText(_ color: CPColor, _ format: CPFormat) -> String {
        CPFormatter.display(color, format, options: options)
    }

    /// Writes `color` as text in `format` plus an `NSColor` (one pasteboard
    /// item), so a paste into a color well (Keynote, Pages) gets the color.
    @discardableResult
    func copy(_ color: CPColor, as format: CPFormat, feedbackKey: String? = nil) -> String {
        let value = text(color, format)
        copyText(value, color: color, feedbackKey: feedbackKey ?? format.rawValue)
        return value
    }

    /// Copies arbitrary text (a palette export) with an optional color beside it.
    func copyText(_ value: String, color: CPColor? = nil, feedbackKey: String) {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        if let color, let plist = NSColor(cp: color).pasteboardPropertyList(forType: .color) {
            // NSColor's pasteboard form is archive data: store it as is
            // (setPropertyList would wrap the Data in a plist).
            if let data = plist as? Data {
                item.setData(data, forType: .color)
            } else {
                item.setPropertyList(plist, forType: .color)
            }
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        flashCopied(feedbackKey)
    }

    private func flashCopied(_ key: String) {
        feedbackSerial &+= 1
        let serial = feedbackSerial
        copyFeedback = CopyFeedback(key: key, serial: serial)
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, self.copyFeedback?.serial == serial else { return }
            self.copyFeedback = nil
        }
    }

    func isCopied(_ key: String) -> Bool { copyFeedback?.key == key }

    /// Reads a color from the clipboard (a color, or text such as
    /// `#3b82f6` / `rgb(…)` / `oklch(…)` / `Color(red:…)`) and shows it.
    @discardableResult
    func convertClipboard() -> Bool {
        var found: CPColor?
        if let string = pasteboard.string(forType: .string) { found = CPParser.parse(string) }
        if found == nil, let color = NSColor(from: pasteboard)?.cpColor, color.isWellFormed { found = color }
        guard let color = found else {
            bandPresenter?(CPBandInfo(color: current ?? .white, value: "No color on the clipboard", label: "",
                                      detail: "copy a hex, rgb(), hsl() or oklch() value", symbol: "doc.on.clipboard", duration: 2.5))
            return false
        }
        let opaque = CPColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        current = opaque
        addToHistory(CPHistoryEntry(color: opaque, date: Date(), sourceSpace: "Clipboard", appName: nil))
        return true
    }

    /// Shows a color in the drawer without copying it.
    func show(_ color: CPColor) {
        guard color.isWellFormed else { return }
        current = color
    }

    // MARK: History

    private func addToHistory(_ entry: CPHistoryEntry) {
        guard entry.color.isWellFormed else { return }
        history = CPCollections.inserting(entry, into: history, limit: Self.historyLimit)
        saveHistory()
    }

    func select(_ entry: CPHistoryEntry) {
        current = entry.color
    }

    /// Click on a history swatch: show it and copy it again.
    func recopy(_ entry: CPHistoryEntry) {
        current = entry.color
        copy(entry.color, as: defaultFormat, feedbackKey: "history-\(entry.id)")
    }

    func delete(_ entry: CPHistoryEntry) {
        guard history.contains(where: { $0.id == entry.id }) else { return }
        offerUndo(.history([entry]))
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        guard !history.isEmpty else { return }
        offerUndo(.history(history))
        history = []
        saveHistory()
    }

    /// Puts back only what was removed, merged into the lists as they are
    /// now: picks and palette edits made since stay.
    func undo() {
        switch undoState {
        case .history(let removed):
            history = CPCollections.restoring(removed, into: history, limit: Self.historyLimit)
            saveHistory()
        case .palette(let palette, let index, let wasSelected):
            if !palettes.contains(where: { $0.id == palette.id }), palettes.count < CPCollections.paletteLimit {
                palettes.insert(palette, at: min(index, palettes.count))
                if wasSelected { selectedPaletteID = palette.id }
                savePalettes()
            }
        case .paletteColor(let color, let index, let paletteID):
            if let p = palettes.firstIndex(where: { $0.id == paletteID }),
               !palettes[p].colors.contains(where: { CPCollections.sameColor($0, color) }),
               palettes[p].colors.count < CPCollections.colorsPerPaletteLimit {
                palettes[p].colors.insert(color, at: min(index, palettes[p].colors.count))
                savePalettes()
            }
        case nil:
            break
        }
        retireUndo()
    }

    private func offerUndo(_ undo: Undo) {
        undoState = undo
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self, undoLifetime] in
            try? await Task.sleep(for: undoLifetime)
            guard !Task.isCancelled, let self else { return }
            self.undoState = nil
            self.undoExpiry = nil
        }
    }

    private func retireUndo() {
        undoState = nil
        undoExpiry?.cancel()
        undoExpiry = nil
    }

    private func saveHistory() {
        store.save(history, CPDefaults.Keys.history)
    }

    // MARK: Palettes

    var selectedPalette: CPPalette? {
        palettes.first { $0.id == selectedPaletteID } ?? palettes.first
    }

    @discardableResult
    func createPalette(named name: String = "Palette", with colors: [CPColor] = []) -> CPPalette? {
        guard palettes.count < CPCollections.paletteLimit else { return nil }
        var palette = CPPalette(name: CPCollections.uniqueName(name, existing: palettes))
        for color in colors where color.isWellFormed { palette = CPCollections.adding(color, to: palette) }
        palettes.append(palette)
        selectedPaletteID = palette.id
        savePalettes()
        return palette
    }

    func renamePalette(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        let others = palettes.filter { $0.id != id }
        palettes[index].name = CPCollections.uniqueName(trimmed, existing: others)
        savePalettes()
    }

    /// The view asks for confirmation first.
    func deletePalette(_ id: UUID) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        offerUndo(.palette(palettes[index], index: index, wasSelected: selectedPalette?.id == id))
        palettes.remove(at: index)
        if selectedPaletteID == id { selectedPaletteID = palettes.first?.id }
        savePalettes()
    }

    /// Adds to the selected palette (creating "Palette" when there is none).
    func addToPalette(_ color: CPColor, paletteID: UUID? = nil) {
        guard color.isWellFormed,
              let id = paletteID ?? selectedPalette?.id ?? createPalette()?.id,
              let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        palettes[index] = CPCollections.adding(color, to: palettes[index])
        savePalettes()
    }

    func removeColor(at offset: Int, fromPalette id: UUID) {
        guard let index = palettes.firstIndex(where: { $0.id == id }), palettes[index].colors.indices.contains(offset) else { return }
        offerUndo(.paletteColor(palettes[index].colors[offset], index: offset, paletteID: id))
        palettes[index].colors.remove(at: offset)
        savePalettes()
    }

    /// Reorders palettes (menu "Move Left / Right").
    func movePalette(_ id: UUID, by delta: Int) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + delta, 0), palettes.count - 1)
        guard target != index else { return }
        let palette = palettes.remove(at: index)
        palettes.insert(palette, at: target)
        savePalettes()
    }

    /// Moves a color within a palette.
    func moveColor(at offset: Int, by delta: Int, inPalette id: UUID) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        var colors = palettes[index].colors
        guard colors.indices.contains(offset) else { return }
        let target = min(max(offset + delta, 0), colors.count - 1)
        guard target != offset else { return }
        let color = colors.remove(at: offset)
        colors.insert(color, at: target)
        palettes[index].colors = colors
        savePalettes()
    }

    func export(_ palette: CPPalette, as kind: CPPaletteExport) {
        copyText(kind.text(for: palette), feedbackKey: "export-\(palette.id)")
    }

    private func savePalettes() {
        store.save(palettes, CPDefaults.Keys.palettes)
    }

    // MARK: Contrast

    func swapContrast() {
        contrast = CPContrastPair(foreground: contrast.background, background: contrast.foreground)
    }

    var contrastRatio: Double { CPContrast.ratio(contrast.foreground, contrast.background) }

    /// A nearby text color that passes AA (4.5:1), or nil if it already does.
    var contrastSuggestion: CPColor? {
        CPContrast.suggestion(foreground: contrast.foreground, background: contrast.background, target: 4.5)
    }

    func applySuggestion() {
        guard let suggestion = contrastSuggestion else { return }
        contrast.foreground = suggestion
    }
}
