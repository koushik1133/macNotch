import AppKit
import Carbon.HIToolbox
import NaturalLanguage
import SwiftUI
import Vision

// Copy Text: select any part of the screen (or click a window) and the text
// in it goes straight to the clipboard, like TextSniper (⌘⇧2), PowerToys
// Text Extractor (Win⇧T) and macOS Live Text. Reuses the Ask-about-screen
// overlay and capture; OCR is Vision's accurate recognizer with language
// correction, on this Mac only. QR codes and barcodes are read too.

// MARK: - Settings

/// Copy Text options, saved in UserDefaults under `textGrab.*`.
@MainActor
final class ScreenTextGrabSettings: ObservableObject {
    /// ⌃⌥T.
    static let defaultShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(controlKey | optionKey))

    /// Keep the selection's line breaks (on) or join lines into paragraphs (off).
    @Published var keepLineBreaks: Bool { didSet { defaults.set(keepLineBreaks, forKey: Keys.keepLineBreaks) } }
    /// Read QR codes and barcodes; their payload is copied instead of text.
    @Published var detectCodes: Bool { didSet { defaults.set(detectCodes, forKey: Keys.detectCodes) } }
    /// Add to what is on the clipboard instead of replacing it.
    @Published var appendToClipboard: Bool { didSet { defaults.set(appendToClipboard, forKey: Keys.append) } }
    @Published fileprivate(set) var shortcut: ScreenRegionShortcut

    private let defaults: UserDefaults

    enum Keys {
        static let keepLineBreaks = "textGrab.keepLineBreaks"
        static let detectCodes = "textGrab.detectCodes"
        static let append = "textGrab.appendToClipboard"
        static let shortcut = "textGrab.shortcut"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepLineBreaks = defaults.object(forKey: Keys.keepLineBreaks) as? Bool ?? true
        detectCodes = defaults.object(forKey: Keys.detectCodes) as? Bool ?? true
        appendToClipboard = defaults.object(forKey: Keys.append) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.shortcut),
           let saved = try? JSONDecoder().decode(ScreenRegionShortcut.self, from: data), saved.isValidGlobal {
            shortcut = saved
        } else {
            shortcut = Self.defaultShortcut
        }
    }

    fileprivate func save(_ newValue: ScreenRegionShortcut) {
        shortcut = newValue
        if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Keys.shortcut) }
    }
}

// MARK: - Recognition

/// One recognized line. `box` is normalized to the image, origin top-left, y down.
struct ScreenTextLine: Sendable, Equatable {
    var text: String
    var box: CGRect
}

struct ScreenTextCode: Sendable, Equatable {
    var symbology: String
    var payload: String

    /// "QR code", "EAN-13 barcode"…
    var kindName: String {
        let lower = symbology.lowercased()
        if lower.contains("qr") { return "QR code" }
        if lower.contains("aztec") { return "Aztec code" }
        if lower.contains("pdf417") { return "PDF417 code" }
        if lower.contains("datamatrix") { return "Data Matrix code" }
        let name = symbology.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
        return name.isEmpty ? "Barcode" : "\(name) barcode"
    }
}

struct ScreenTextRecognition: Sendable, Equatable {
    var lines: [ScreenTextLine]
    var codes: [ScreenTextCode]
}

/// Vision OCR + barcode detection on a capture. Runs off the main thread.
enum ScreenTextRecognizer {
    /// Captures smaller than this (long edge, pixels) are upscaled before OCR.
    static let upscaleBelow = 900

    static func recognize(_ image: CGImage, detectCodes: Bool) async throws -> ScreenTextRecognition {
        try await Task.detached(priority: .userInitiated) {
            try recognizeSync(image, detectCodes: detectCodes)
        }.value
    }

    /// Vision's text model can take a long time to load the first time a
    /// new build runs it (about a minute here, then ~0.1 s). One tiny OCR at
    /// low priority after launch keeps the first ⌃⌥T fast.
    static func warmUp() {
        Task.detached(priority: .background) {
            let started = Date()
            guard let context = CGContext(
                data: nil, width: 64, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 24))
            guard let image = context.makeImage() else { return }
            _ = try? recognizeSync(image, detectCodes: false)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            await MainActor.run { AppLog.log("Copy Text: OCR warmed up in \(ms) ms") }
        }
    }

    nonisolated static func recognizeSync(_ image: CGImage, detectCodes: Bool) throws -> ScreenTextRecognition {
        do {
            return try recognizeSync(image, detectCodes: detectCodes, level: .accurate)
        } catch {
            // The accurate model can fail to load on a busy machine (seen:
            // "e5rt … precompiled compute operation"); the fast one still reads.
            return try recognizeSync(image, detectCodes: detectCodes, level: .fast)
        }
    }

    nonisolated static func recognizeSync(_ image: CGImage, detectCodes: Bool, level: VNRequestTextRecognitionLevel) throws -> ScreenTextRecognition {
        let prepared = prepare(image)
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = level
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        text.minimumTextHeight = 0
        // Barcodes always run: their modules OCR as junk ("O Hl"), so text
        // inside a code is dropped even when codes aren't copied.
        let barcodes = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: prepared.image, options: [:]).perform([text, barcodes])

        let codeBoxes = (barcodes.results ?? []).map { prepared.mapToOriginal($0.boundingBox).insetBy(dx: -0.01, dy: -0.01) }
        let lines: [ScreenTextLine] = (text.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let box = prepared.mapToOriginal(observation.boundingBox)
            guard !codeBoxes.contains(where: { $0.contains(CGPoint(x: box.midX, y: box.midY)) }) else { return nil }
            return ScreenTextLine(text: trimmed, box: box)
        }
        var codes: [ScreenTextCode] = []
        if detectCodes {
            for observation in barcodes.results ?? [] {
                guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !payload.isEmpty, !codes.contains(where: { $0.payload == payload }) else { continue }
                codes.append(ScreenTextCode(symbology: observation.symbology.rawValue, payload: payload))
            }
        }
        return ScreenTextRecognition(lines: lines, codes: codes)
    }

    /// A small or edge-to-edge crop reads better upscaled and with a margin
    /// in its own background color (Vision misses text that touches the edge).
    struct Prepared {
        var image: CGImage
        /// Normalized rect of the original inside `image`.
        var inner: CGRect

        /// Vision box (normalized, bottom-left origin, in `image`) → normalized
        /// top-left box in the original capture.
        func mapToOriginal(_ box: CGRect) -> CGRect {
            let x = (box.minX - inner.minX) / inner.width
            let yBottom = (box.minY - inner.minY) / inner.height
            let w = box.width / inner.width
            let h = box.height / inner.height
            return CGRect(x: x, y: 1 - yBottom - h, width: w, height: h)
        }
    }

    nonisolated static func prepare(_ image: CGImage) -> Prepared {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return Prepared(image: image, inner: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let scale: CGFloat = max(width, height) < upscaleBelow ? 2 : 1
        let margin = Int((CGFloat(min(width, height)) * scale * 0.08).rounded().clamped(to: 8...48))
        let targetW = Int(CGFloat(width) * scale) + margin * 2
        let targetH = Int(CGFloat(height) * scale) + margin * 2
        guard let context = CGContext(
            data: nil, width: targetW, height: targetH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Prepared(image: image, inner: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        context.setFillColor(cornerColor(of: image))
        context.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        context.interpolationQuality = .high
        let drawn = CGRect(x: margin, y: margin, width: targetW - margin * 2, height: targetH - margin * 2)
        context.draw(image, in: drawn)
        guard let output = context.makeImage() else { return Prepared(image: image, inner: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let inner = CGRect(
            x: drawn.minX / CGFloat(targetW), y: drawn.minY / CGFloat(targetH),
            width: drawn.width / CGFloat(targetW), height: drawn.height / CGFloat(targetH)
        )
        return Prepared(image: output, inner: inner)
    }

    /// The top-left pixel's color (the background, almost always).
    nonisolated static func cornerColor(of image: CGImage) -> CGColor {
        var pixel = [UInt8](repeating: 255, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            // Draw so that the image's top-left pixel lands on our only pixel.
            context.draw(image, in: CGRect(x: 0, y: -CGFloat(image.height - 1), width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.01 else { return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
        return CGColor(srgbRed: CGFloat(pixel[0]) / 255 / alpha, green: CGFloat(pixel[1]) / 255 / alpha,
                       blue: CGFloat(pixel[2]) / 255 / alpha, alpha: 1)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Layout (pure)

/// Turns OCR lines into clipboard text in reading order.
enum ScreenTextLayout {
    /// Lines on the same baseline (overlapping vertically by at least this
    /// share of the smaller height) form one row, left to right.
    static let rowOverlap: CGFloat = 0.5

    /// Rows top to bottom; each row's lines left to right.
    static func rows(_ lines: [ScreenTextLine]) -> [[ScreenTextLine]] {
        let sorted = lines.sorted { $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY < $1.box.midY }
        var rows: [[ScreenTextLine]] = []
        for line in sorted {
            if let index = rows.lastIndex(where: { row in row.contains { sameRow($0.box, line.box) } }),
               index == rows.count - 1 {
                rows[index].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0 && overlap >= rowOverlap * min(a.height, b.height)
    }

    /// One row as text: a space between close pieces, a tab across a wide gap
    /// (table columns paste into Numbers or Sheets as cells).
    static func rowText(_ row: [ScreenTextLine]) -> String {
        var text = ""
        for (index, line) in row.enumerated() {
            if index > 0 {
                let previous = row[index - 1]
                let charWidth = max(0.0001, previous.box.width / CGFloat(max(1, previous.text.count)))
                let gap = line.box.minX - previous.box.maxX
                text += gap > charWidth * 4 ? "\t" : " "
            }
            text += line.text
        }
        return text
    }

    static func text(from lines: [ScreenTextLine], keepLineBreaks: Bool) -> String {
        let rows = rows(lines)
        guard !rows.isEmpty else { return "" }
        let texts = rows.map(rowText)
        if keepLineBreaks { return texts.joined(separator: "\n") }

        // Paragraph mode: join wrapped lines, keep breaks at clear gaps.
        let heights = rows.map { row in row.map(\.box.height).max() ?? 0 }
        let medianHeight = heights.sorted()[heights.count / 2]
        var output = texts[0]
        for index in 1..<rows.count {
            let previousBottom = rows[index - 1].map(\.box.maxY).max() ?? 0
            let top = rows[index].map(\.box.minY).min() ?? 0
            let gap = top - previousBottom
            let next = texts[index]
            if gap > medianHeight * 1.1 {
                output += "\n" + next
            } else {
                output = join(output, next)
            }
        }
        return output
    }

    /// Joins a wrapped line: drops a line-end hyphen before a lowercase
    /// continuation, no space between CJK characters.
    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        if last == "-", first.isLowercase, a.dropLast().last?.isLetter == true { return String(a.dropLast()) + b }
        if isCJK(last) || isCJK(first) { return a + b }
        return a + " " + b
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x3000...0x303F:
            return true
        default:
            return false
        }
    }

    static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}

// MARK: - Outcome

struct ScreenTextGrabOutcome: Equatable {
    enum Kind: Equatable {
        case text(words: Int)
        case code(String)
        case nothing
    }

    var kind: Kind
    /// What went to the clipboard (empty for `.nothing`).
    var copied: String

    /// Band title: "Copied 12 words", "Copied QR code", "No text found".
    var title: String {
        switch kind {
        case .text(let words): words == 1 ? "Copied 1 word" : "Copied \(words) words"
        case .code(let kind): "Copied \(kind)"
        case .nothing: "No text found in the selection"
        }
    }

    /// Decide what to copy. Codes win when present (their payload is what
    /// people want from a QR code); the text is used otherwise.
    static func make(from recognition: ScreenTextRecognition, keepLineBreaks: Bool) -> ScreenTextGrabOutcome {
        if let first = recognition.codes.first {
            let payload = recognition.codes.map(\.payload).joined(separator: "\n")
            let kind = recognition.codes.count == 1 ? first.kindName : "\(recognition.codes.count) codes"
            return ScreenTextGrabOutcome(kind: .code(kind), copied: payload)
        }
        let text = ScreenTextLayout.text(from: recognition.lines, keepLineBreaks: keepLineBreaks)
        guard !text.isEmpty else { return ScreenTextGrabOutcome(kind: .nothing, copied: "") }
        return ScreenTextGrabOutcome(kind: .text(words: ScreenTextLayout.wordCount(text)), copied: text)
    }
}

// MARK: - Controller

/// "Copy Text": hotkey (⌃⌥T) → selection overlay → OCR → clipboard.
@MainActor
final class ScreenTextGrabController: ObservableObject {
    enum Phase: Equatable { case idle, selecting, reading }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastOutcome: ScreenTextGrabOutcome?
    @Published private(set) var hotkeyRegistered = false
    let settings: ScreenTextGrabSettings

    /// Called before the overlay appears (wired to cancel Clicky's ⌃⌥ chord).
    var onWillBegin: (() -> Void)?
    /// True while another overlay owns the screen (Ask about screen).
    var isBusyElsewhere: () -> Bool = { false }
    /// The clipboard. Tests pass a named pasteboard.
    var pasteboard: NSPasteboard = .general

    private let activities: ActivityCenter
    private let overlay = ScreenRegionOverlayController()
    private let hotkey = ScreenRegionHotkey()
    private var task: Task<Void, Never>?

    static let activityID = "screenRegion.textGrab"

    init(activities: ActivityCenter, settings: ScreenTextGrabSettings? = nil) {
        self.activities = activities
        self.settings = settings ?? ScreenTextGrabSettings()
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
    }

    var shortcut: ScreenRegionShortcut { settings.shortcut }
    var isOverlayActive: Bool { overlay.isActive }

    // MARK: Hotkey

    @discardableResult
    func installHotkey() -> Bool {
        hotkeyRegistered = hotkey.register(settings.shortcut)
        if hotkeyRegistered { AppLog.log("Copy Text: hotkey \(settings.shortcut.displayString)") }
        return hotkeyRegistered
    }

    func uninstallHotkey() {
        hotkey.unregister()
        hotkeyRegistered = false
    }

    @discardableResult
    func setShortcut(_ newValue: ScreenRegionShortcut) -> Bool {
        guard newValue.isValidGlobal else { return false }
        let wasRegistered = hotkeyRegistered
        settings.save(newValue)
        return wasRegistered ? installHotkey() : true
    }

    private func hotkeyPressed() {
        switch phase {
        case .selecting: overlay.cancel()
        case .reading: break
        case .idle: begin()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        overlay.cancel()
        uninstallHotkey()
        activities.dismiss(id: Self.activityID)
        phase = .idle
    }

    // MARK: Flow

    /// Shows the overlay; the selection's text goes to the clipboard.
    func begin(mode: ScreenRegionOverlayState.Mode = .region) {
        guard phase == .idle, !isBusyElsewhere(), !ScreenRegionOverlayController.isAnyActive else { return }
        guard ScreenRegionCapture.hasPermission else {
            post(systemImage: "lock.shield", title: "Allow Screen Recording to copy text", detail: "Screen tab → Allow", duration: 4)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        onWillBegin?()
        phase = .selecting
        NSApp.activate()
        var options = ScreenRegionOverlayOptions()
        options.regionHint = "Drag over text to copy it  ·  Click a window  ·  Space: pick window  ·  Esc: cancel"
        options.windowHint = "Click a window to copy its text  ·  Space: drag a region  ·  Esc: cancel"
        options.title = "Copy text from screen"
        overlay.begin(mode: mode, options: options) { [weak self] selection in
            guard let self else { return }
            if let previousApp, !previousApp.isTerminated { previousApp.activate() }
            guard let selection else {
                self.phase = .idle
                return
            }
            self.read(selection)
        }
    }

    private func read(_ selection: ScreenRegionSelection) {
        phase = .reading
        post(systemImage: "text.viewfinder", title: "Reading text…", detail: nil, duration: 120, busy: true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.phase == .reading else { return }
            self.post(systemImage: "text.viewfinder", title: "Reading text…", detail: "the first time after an update takes longer", duration: 120, busy: true)
        }
        task?.cancel()
        task = Task { [weak self] in
            // Let the overlay leave the compositor first.
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !Task.isCancelled else { return }
            do {
                let image = try await ScreenRegionCapture.capture(selection)
                guard !Task.isCancelled else { return }
                _ = try await self.process(image)
            } catch is CancellationError {
            } catch {
                self.post(systemImage: "exclamationmark.triangle", title: ScreenRegionAssistant.message(for: error), detail: nil, duration: 3.5)
            }
            self.phase = .idle
        }
    }

    /// OCR an image and copy the result (also the test entry point).
    @discardableResult
    func process(_ image: CGImage) async throws -> ScreenTextGrabOutcome {
        let started = Date()
        let recognition = try await ScreenTextRecognizer.recognize(image, detectCodes: settings.detectCodes)
        let outcome = ScreenTextGrabOutcome.make(from: recognition, keepLineBreaks: settings.keepLineBreaks)
        lastOutcome = outcome
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch outcome.kind {
        case .nothing:
            AppLog.log("Copy Text: nothing found in \(image.width)x\(image.height) (\(ms) ms)")
            post(systemImage: "text.magnifyingglass", title: outcome.title, detail: "Try a larger or sharper area", duration: 3)
        case .text, .code:
            copy(outcome.copied)
            AppLog.log("Copy Text: \(outcome.title) from \(image.width)x\(image.height) (\(ms) ms)")
            let detail = outcome.copied.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            post(systemImage: isCode(outcome) ? "qrcode" : "doc.on.clipboard",
                 title: settings.appendToClipboard ? outcome.title.replacingOccurrences(of: "Copied", with: "Added") : outcome.title,
                 detail: detail, duration: 3)
        }
        return outcome
    }

    private func isCode(_ outcome: ScreenTextGrabOutcome) -> Bool {
        if case .code = outcome.kind { return true }
        return false
    }

    private func copy(_ text: String) {
        var value = text
        if settings.appendToClipboard, let existing = pasteboard.string(forType: .string), !existing.isEmpty {
            value = existing + "\n" + text
        }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func post(systemImage: String, title: String, detail: String?, duration: TimeInterval, busy: Bool = false) {
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 66, duration: duration) {
            ScreenTextGrabBandView(systemImage: systemImage, title: title, detail: detail, busy: busy)
        })
    }
}

// MARK: - Views

/// Band under the notch: "Copied 12 words  The quick brown fox…".
struct ScreenTextGrabBandView: View {
    let systemImage: String
    let title: String
    let detail: String?
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.success)
            }
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(SparkVTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .tint(SparkVTheme.accent)
    }
}

/// Menu items for the notch's "…" menu (Copy Text and its options).
struct ScreenTextGrabMenuItems: View {
    @ObservedObject var controller: ScreenTextGrabController
    @ObservedObject var settings: ScreenTextGrabSettings

    init(controller: ScreenTextGrabController) {
        self.controller = controller
        self.settings = controller.settings
    }

    var body: some View {
        Button("Copy Text from Screen…  \(settings.shortcut.displayString)") { controller.begin() }
        Button("Copy Text from a Window…") { controller.begin(mode: .window) }
        Toggle("Keep Line Breaks", isOn: $settings.keepLineBreaks)
        Toggle("Read QR Codes and Barcodes", isOn: $settings.detectCodes)
        Toggle("Add to Clipboard Instead of Replacing", isOn: $settings.appendToClipboard)
    }
}
