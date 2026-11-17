import AppKit
import SwiftUI

// The Fans & Temperatures window: fan speeds on the left, live sensors on
// the right. Read-only; macOS controls the fans.

@MainActor
final class FanControlWindowController: NSObject, NSWindowDelegate {
    static let shared = FanControlWindowController()

    private var window: NSWindow?
    private weak var controller: FanController?

    func show(controller given: FanController? = nil) {
        let controller = given ?? FanController.shared
        self.controller = controller
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Fans & Temperatures"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            LabsBWindowAppearance.follow(window)
            window.minSize = NSSize(width: 700, height: 460)
            window.delegate = self
            window.contentView = NSHostingView(rootView: FanWindowRoot(controller: controller).followsAppearance())
            window.center()
            window.setFrameAutosaveName("SparkV.FanControl")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI tree so its sampling stops (onDisappear detaches).
        window?.contentView = nil
        window = nil
    }
}

// MARK: - Root

struct FanWindowRoot: View {
    @ObservedObject var controller: FanController

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 18)
                .padding(.top, 30)
                .padding(.bottom, 12)
            Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                fansPane
                    .frame(minWidth: 400, maxWidth: .infinity)
                Rectangle().fill(SparkVTheme.stroke).frame(width: 1)
                FanSensorList(controller: controller)
                    .frame(width: 280)
            }
            Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
            FanInfoLine(controller: controller)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .background(LabsBWindowGround(glow: 1).ignoresSafeArea())
        .foregroundStyle(SparkVTheme.text)
        .onAppear { controller.attachViewer() }
        .onDisappear { controller.detachViewer() }
    }

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(SparkVTheme.isApple ? "FANS & TEMPERATURES" : "SPARKV / FANS & TEMPERATURES")
                    .font(SparkVTheme.eyebrow()).tracking(SparkVTheme.isApple ? 0.4 : 1.2)
                    .foregroundStyle(SparkVTheme.textTertiary)
                Text(headline)
                    .font(SparkVTheme.title(20))
                    .tracking(-0.3)
            }
            Spacer()
            settingsMenu
        }
    }

    private var headline: String {
        let count = controller.snapshot.fans.count
        if !controller.snapshot.smcAvailable { return "Reading sensors…" }
        return count == 0 ? "No fans on this Mac" : "\(count) fan\(count == 1 ? "" : "s")"
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Show in the Notch", selection: $controller.settings.activity) {
                Text("Always").tag(FanSettings.ActivityStyle.always)
                Text("Never").tag(FanSettings.ActivityStyle.never)
            }
            Toggle("Show Fahrenheit", isOn: $controller.settings.fahrenheit)
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Fans & Temperatures settings")
    }

    @ViewBuilder
    private var fansPane: some View {
        if controller.snapshot.fans.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "fan.slash").font(.system(size: 30)).foregroundStyle(SparkVTheme.textTertiary)
                Text(controller.snapshot.smcAvailable ? "This Mac has no fans" : "Reading the SMC…")
                    .font(SparkVTheme.headline(14))
                Text("Temperatures still show on the right.")
                    .font(SparkVTheme.body(12)).foregroundStyle(SparkVTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(controller.snapshot.fans) { fan in
                        FanCard(controller: controller, fan: fan)
                    }
                }
                .padding(18)
            }
        }
    }
}

// MARK: - One fan

/// A fan's live speed, its limits and the bar. Read-only.
struct FanCard: View {
    @ObservedObject var controller: FanController
    let fan: FanInfo

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                FanGlyph(size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.name(for: fan.index)).font(SparkVTheme.headline(14))
                    Text("Min \(FanFormat.rpm(fan.minimum)) · Max \(FanFormat.rpm(fan.maximum)) rpm"
                         + (fan.target.map { " · Target \(FanFormat.rpm($0))" } ?? ""))
                        .font(SparkVTheme.caption(10.5).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(FanFormat.rpm(fan.actual))
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("rpm").font(SparkVTheme.caption(11)).foregroundStyle(SparkVTheme.textSecondary)
                }
            }
            FanRPMBar(fan: fan)
        }
        .padding(16)
        .background(shape.fill(SparkVTheme.surface))
        .overlay(shape.strokeBorder(SparkVTheme.stroke))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sensors

struct FanSensorList: View {
    @ObservedObject var controller: FanController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SENSORS").font(SparkVTheme.eyebrow()).tracking(LabsBStyle.eyebrowTracking(1.2)).foregroundStyle(SparkVTheme.textTertiary)
                Spacer()
                Toggle("All", isOn: $controller.settings.showAllSensors)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(SparkVTheme.caption(10))
                    .help("Show every SMC and HID temperature sensor")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(groups, id: \.group) { section in
                        Text(section.group.title.uppercased())
                            .font(SparkVTheme.eyebrow(8.5)).tracking(LabsBStyle.eyebrowTracking(1))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .padding(.top, 8).padding(.bottom, 2)
                        ForEach(section.readings) { reading in
                            HStack {
                                Text(reading.name)
                                    .font(reading.isAggregate ? SparkVTheme.headline(11.5) : SparkVTheme.body(11.5))
                                    .foregroundStyle(reading.isAggregate ? SparkVTheme.text : SparkVTheme.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(controller.temperatureText(reading.celsius))
                                    .font(SparkVTheme.headline(11.5).monospacedDigit())
                                    .foregroundStyle(reading.celsius >= 90 ? SparkVTheme.destructive : reading.celsius >= 75 ? SparkVTheme.warning : SparkVTheme.text)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    if controller.snapshot.sensors.isEmpty {
                        Text("No temperature sensors readable").font(SparkVTheme.body(11.5)).foregroundStyle(SparkVTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }

    private var groups: [(group: FanSensorGroup, readings: [FanSensorReading])] {
        FanSensorGroup.allCases.compactMap { group in
            let readings = controller.snapshot.sensors.filter { $0.group == group }
            guard !readings.isEmpty else { return nil }
            let singles = readings.filter { !$0.isAggregate }.sorted { $0.name < $1.name }
            var summaries = readings.filter(\.isAggregate)
            // "SSD Hottest" next to a lone "SSD" says nothing new.
            if group != .cpu, group != .gpu, singles.count == 1 { summaries.removeAll() }
            return (group, summaries + singles)
        }
    }
}
