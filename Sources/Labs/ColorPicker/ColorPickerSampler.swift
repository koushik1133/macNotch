import AppKit
import Darwin

/// Shows a screen loupe and reports one color. A protocol so tests can
/// replace the system sampler.
@MainActor
protocol CPColorSampling: AnyObject {
    /// Starts a session; `completion` runs once on the main thread with the
    /// picked color, or nil when the user pressed Esc. `activating` asks for
    /// the compatibility start (SparkV made active first).
    func sample(activating: Bool, _ completion: @escaping @MainActor (NSColor?) -> Void)
    /// Gives up on a session that never called back.
    func reset()
}

/// The system color sampler (`NSColorSampler`, macOS 10.15+). The loupe is
/// drawn by the out-of-process ColorSampler.xpc over every app, website,
/// display and Space, and needs **no Screen Recording permission** (one
/// pixel, only after the user's own gesture). There is no cancel API: Esc
/// in the loupe returns nil.
///
/// **Default start: SparkV stays in the background.** Making SparkV active
/// would change the very pixels being sampled: the front app would draw its
/// inactive look (grey accent, selection, default buttons, focus rings and
/// traffic lights), SparkV's own key or main window (Meeting Notes, Flow
/// Canvas) could come to the front over the target, and Stage Manager might
/// switch stages. So the loupe starts from an invisible, *non-activating*
/// titled panel that is ordered in without becoming key, on the next
/// run-loop turn (outside the SwiftUI action).
///
/// **Compatibility start (fallback).** A macOS 27 report (Apple forums
/// 845184, FB24722293) says a sampler shown from SwiftUI in a borderless
/// window can leave ColorSampler.xpc holding every click; the reported
/// workaround starts it from a regular titled window with the app active.
/// The controller asks for that start only after the user had to reset a
/// stuck pick (`ColorPicker.needsActivationWorkaround`, also a menu toggle).
/// It makes an invisible titled window key and main (so activation brings
/// that window forward rather than another SparkV window), activates
/// SparkV, waits for `didBecomeActiveNotification` (at most 150 ms; on
/// macOS 14+ activation is cooperative and asynchronous), then shows the
/// loupe, and gives focus back to the app that was in front afterwards.
///
/// `reset()` ends the user's ColorSampler process (SIGTERM, then SIGKILL
/// after 0.5 s only if it is still running), only when the user asks. The
/// XPC service is per user, so this resets the system color loupe for all
/// apps (the system color panel's eyedropper too).
@MainActor
final class CPSystemSampler: CPColorSampling {
    /// Shows the loupe and calls back once on the main thread.
    typealias LoupePresenter = @MainActor (_ handler: @escaping @MainActor (NSColor?) -> Void) -> Void

    /// How long the compatibility start waits for SparkV to become active.
    static let activationTimeout: Duration = .milliseconds(150)
    nonisolated static let systemProcessName = "ColorSampler"
    /// The host windows' title (also how tests find them).
    static let hostTitle = "SparkV Color Picker"

    /// `NSColorSampler` in the app; tests pass a stand-in so the start
    /// paths run without putting a real loupe on screen.
    private let presentLoupe: LoupePresenter
    /// The process `reset()` ends (tests use a stand-in).
    private let processName: String
    private var quietHost: NSPanel?
    private var activeHost: NSWindow?
    private var previousApp: NSRunningApplication?
    private var session = 0
    private var waitingCompletion: (@MainActor (NSColor?) -> Void)?
    private var activationObserver: (any NSObjectProtocol)?
    private var activationTimer: Task<Void, Never>?

    init(presentLoupe: LoupePresenter? = nil, processName: String = CPSystemSampler.systemProcessName) {
        self.processName = processName
        self.presentLoupe = presentLoupe ?? { handler in
            NSColorSampler().show { color in
                // The SDK runs the handler on the main thread.
                MainActor.assumeIsolated { handler(color) }
            }
        }
    }

    func sample(activating: Bool, _ completion: @escaping @MainActor (NSColor?) -> Void) {
        session &+= 1
        let current = session
        stopWaitingForActivation()
        if activating {
            startActivated(current, completion)
        } else {
            startQuietly(current, completion)
        }
    }

    func reset() {
        session &+= 1
        stopWaitingForActivation()
        endSession()
        CPProcessReset.terminate(named: processName) { AppLog.log("Color Picker: \($0)") }
    }

    // MARK: Starts

    /// The default: nothing is activated and nothing becomes key, so the
    /// front app keeps its active colors.
    private func startQuietly(_ current: Int, _ completion: @escaping @MainActor (NSColor?) -> Void) {
        previousApp = nil
        let host = quietHostPanel()
        place(host)
        host.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.showLoupe(current, completion) }
    }

    /// The fallback: SparkV active, the invisible host key and main.
    private func startActivated(_ current: Int, _ completion: @escaping @MainActor (NSColor?) -> Void) {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let host = activeHostWindow()
        place(host)
        host.orderFrontRegardless()
        host.makeKey()
        host.makeMain()
        if NSApp.isActive {
            DispatchQueue.main.async { [weak self] in self?.showLoupe(current, completion) }
            return
        }
        waitingCompletion = completion
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationSettled(current, timedOut: false) }
        }
        activationTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.activationTimeout)
            guard !Task.isCancelled else { return }
            self?.activationSettled(current, timedOut: true)
        }
        NSApp.activate()
    }

    private func activationSettled(_ current: Int, timedOut: Bool) {
        guard session == current, let completion = waitingCompletion else { return }
        stopWaitingForActivation()
        if timedOut {
            AppLog.log("Color Picker: SparkV wasn't active after \(Self.activationTimeout); showing the loupe anyway")
        }
        // Next run-loop turn, outside the notification callout.
        DispatchQueue.main.async { [weak self] in self?.showLoupe(current, completion) }
    }

    private func stopWaitingForActivation() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        activationTimer?.cancel()
        activationTimer = nil
        waitingCompletion = nil
    }

    private func showLoupe(_ current: Int, _ completion: @escaping @MainActor (NSColor?) -> Void) {
        guard session == current else { return }
        presentLoupe { color in
            guard self.session == current else { return }
            self.endSession()
            completion(color)
        }
    }

    private func endSession() {
        quietHost?.orderOut(nil)
        activeHost?.orderOut(nil)
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate(options: [])
        }
        previousApp = nil
    }

    // MARK: Host windows (1×1, invisible, click-through)

    private func quietHostPanel() -> NSPanel {
        if let quietHost { return quietHost }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        configure(panel)
        // SparkV is usually inactive: a panel that hides on deactivate would never show.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        quietHost = panel
        return panel
    }

    private func activeHostWindow() -> NSWindow {
        if let activeHost { return activeHost }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.titled],
                              backing: .buffered, defer: false)
        configure(window)
        activeHost = window
        return window
    }

    private func configure(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isExcludedFromWindowsMenu = true
        window.title = Self.hostTitle
    }

    private func place(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x, y: mouse.y))
    }
}

/// Ends the current user's processes with a given name: SIGTERM first,
/// then SIGKILL after `grace`, only for the same PIDs if they still run
/// under that name (a freshly relaunched helper has a new PID and is left
/// alone). Uses libproc and kill(2); no shell, no killall.
enum CPProcessReset {
    /// PIDs of the current user's processes called `name`.
    static func pids(named name: String) -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        let uid = getuid()
        return pids.prefix(Int(filled)).filter { pid in
            pid > 0 && processName(pid) == name && owner(pid) == uid
        }
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func owner(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    /// Sends SIGTERM now and SIGKILL after `grace` to those still running.
    /// Returns how many processes were asked to quit; `log` hears the outcome.
    @MainActor
    @discardableResult
    static func terminate(named name: String, grace: Duration = .milliseconds(500),
                          log: @escaping @MainActor (String) -> Void) -> Int {
        let targets = pids(named: name)
        guard !targets.isEmpty else {
            log("no \(name) process to reset")
            return 0
        }
        for pid in targets { kill(pid, SIGTERM) }
        Task { @MainActor in
            try? await Task.sleep(for: grace)
            let stubborn = targets.filter { processName($0) == name }
            for pid in stubborn { kill(pid, SIGKILL) }
            log(stubborn.isEmpty
                ? "ended \(name) (SIGTERM, \(targets.count) process\(targets.count == 1 ? "" : "es"))"
                : "\(name) ignored SIGTERM; sent SIGKILL to \(stubborn.count)")
        }
        return targets.count
    }
}

extension NSColor {
    /// The sampler's color as extended sRGB (nothing clipped), or nil for a
    /// color without RGB components. Never reads components unconverted.
    var cpColor: CPColor? {
        guard let rgb = usingColorSpace(.extendedSRGB) else { return nil }
        return CPColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                       blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }

    /// The name of the space the color came in (e.g. "Color LCD").
    var cpSpaceName: String? {
        guard type == .componentBased else { return nil }
        return colorSpace.localizedName
    }

    /// An sRGB color when it fits, else Display P3, so a paste into a color
    /// well keeps a wide-gamut pick.
    convenience init(cp color: CPColor) {
        if color.isInSRGBGamut {
            let c = color.clamped
            self.init(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
        } else {
            let p = color.displayP3
            self.init(displayP3Red: CGFloat(CPMath.clamp01(p.r)), green: CGFloat(CPMath.clamp01(p.g)),
                      blue: CGFloat(CPMath.clamp01(p.b)), alpha: CGFloat(color.alpha))
        }
    }
}
