import AppKit
import SwiftUI

// The Fan Control window, laid out like Macs Fan Control: fans with their
// control on the left, live sensors on the right, presets on top.

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
            window.title = "Fan Control"
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
    @StateObject private var presetDraft = FanPresetDraft()

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 18)
                .padding(.top, 30)
                .padding(.bottom, 12)
            presetBar
                .padding(.horizontal, 18)
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
            footer
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
                Text(SparkVTheme.isApple ? "FAN CONTROL" : "SPARKV / FAN CONTROL")
                    .font(SparkVTheme.eyebrow()).tracking(SparkVTheme.isApple ? 0.4 : 1.2)
                    .foregroundStyle(SparkVTheme.textTertiary)
                Text(headline)
                    .font(SparkVTheme.title(20))
                    .tracking(-0.3)
            }
            Spacer()
            if controller.manualFanCount > 0 {
                Label("\(controller.manualFanCount) fan\(controller.manualFanCount == 1 ? "" : "s") under manual control", systemImage: "hand.raised.fill")
                    .font(SparkVTheme.caption(11))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(SparkVTheme.red))
            }
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
            Toggle("Restore My Fan Settings When SparkV Starts", isOn: $controller.settings.restoreOnLaunch)
            Picker("Show in the Notch", selection: $controller.settings.activity) {
                Text("While a Fan Is Manual").tag(FanSettings.ActivityStyle.whileManual)
                Text("Always").tag(FanSettings.ActivityStyle.always)
                Text("Never").tag(FanSettings.ActivityStyle.never)
            }
            Toggle("Show Fahrenheit", isOn: $controller.settings.fahrenheit)
            Divider()
            Button("Copy Install Command") { copy(FanHelperInstaller.terminalCommand(install: true)) }
            Button("Copy Uninstall Command") { copy(FanHelperInstaller.terminalCommand(install: false)) }
            if controller.helperState != .notInstalled {
                Button("Uninstall Fan Helper…") { controller.runHelperInstaller(install: false) }
                    .disabled(!FanHelperInstaller.isBundled || controller.isInstallingHelper)
            }
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Fan Control settings")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var presetBar: some View {
        HStack(spacing: 6) {
            ForEach(controller.presets) { preset in
                Button(preset.name) { controller.applyPreset(preset) }
                    .buttonStyle(FanPresetButtonStyle(selected: controller.activePresetID == preset.id))
                    .help(preset.subtitle)
                    .disabled(!controller.hasFans)
                    .contextMenu {
                        if preset.builtin == nil {
                            Button("Delete “\(preset.name)”") { controller.deletePreset(preset.id) }
                        }
                    }
            }
            Spacer(minLength: 8)
            if presetDraft.isEditing {
                TextField("Preset name", text: $presetDraft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit(savePreset)
                Button("Save", action: savePreset)
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .disabled(presetDraft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { presetDraft.isEditing = false }
                    .buttonStyle(SparkVSecondaryButtonStyle())
            } else {
                Button("Save as Preset…") {
                    presetDraft.name = ""
                    presetDraft.isEditing = true
                }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .disabled(!controller.hasFans)
            }
        }
    }

    private func savePreset() {
        controller.saveCurrentAsPreset(named: presetDraft.name)
        presetDraft.isEditing = false
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

    private var footer: some View {
        HStack(spacing: 10) {
            FanHelperLine(controller: controller)
            if controller.helperState == .notInstalled, controller.hasFans {
                Button("Copy Terminal Command") { copy(FanHelperInstaller.terminalCommand(install: true)) }
                    .buttonStyle(FanSmallButtonStyle())
                    .help(FanHelperInstaller.terminalCommand(install: true))
            }
            if controller.wantsManual || controller.manualFanCount > 0 {
                Button("All Fans to Auto") { controller.resetAllToAuto() }
                    .buttonStyle(SparkVPrimaryButtonStyle())
            }
        }
    }
}

final class FanPresetDraft: ObservableObject {
    @Published var name = ""
    @Published var isEditing = false
}

struct FanPresetButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SparkVTheme.headline(12))
            .foregroundStyle(selected ? Color.white : SparkVTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(selected ? SparkVTheme.red : (configuration.isPressed ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .strokeBorder(selected ? Color.clear : SparkVTheme.stroke)
            )
            .contentShape(Rectangle())
            .animation(SparkVMotion.hover(), value: selected)
            .modifier(FanPressFeedback(isPressed: configuration.isPressed))
    }
}


// MARK: - One fan

/// Draft values while a slider moves; committed when the drag ends, so the
/// SMC sees one change per gesture instead of dozens.
final class FanCardDraft: ObservableObject {
    @Published var rpm: Double = 0
    @Published var sensorID = FanPreset.hottestCPU
    @Published var startC: Double = 50
    @Published var maxC: Double = 80

    func load(_ mode: FanControlMode, limits: ClosedRange<Double>?) {
        switch mode {
        case .auto:
            if let limits, !limits.contains(rpm) { rpm = limits.lowerBound }
        case .constant(let value):
            rpm = value
        case .sensor(let id, let start, let maxT):
            sensorID = id
            startC = start
            maxC = maxT
        }
        if let limits, rpm == 0 { rpm = limits.lowerBound }
    }
}

struct FanCard: View {
    @ObservedObject var controller: FanController
    let fan: FanInfo
    @StateObject private var draft = FanCardDraft()

    private enum Kind: Hashable { case auto, constant, sensor }

    private var mode: FanControlMode { controller.mode(for: fan.index) }
    private var kind: Kind {
        switch mode {
        case .auto: .auto
        case .constant: .constant
        case .sensor: .sensor
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(get: { kind }, set: { newKind in
            guard newKind != kind else { return }
            switch newKind {
            case .auto: controller.setMode(.auto, for: fan.index)
            case .constant: controller.setMode(.constant(rpm: draft.rpm), for: fan.index)
            case .sensor: controller.setMode(.sensor(id: draft.sensorID, startC: draft.startC, maxC: draft.maxC), for: fan.index)
            }
        })
    }

    var body: some View {
        let manual = controller.isManual(fan.index)
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                FanGlyph(manual: manual, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(controller.name(for: fan.index)).font(SparkVTheme.headline(14))
                        FanModeBadge(manual: manual, waiting: mode.isManual && !manual,
                                     elsewhere: controller.isControlledElsewhere(fan.index))
                    }
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
            FanRPMBar(fan: fan, manual: manual)

            Picker("Control", selection: kindBinding) {
                Text("Auto").tag(Kind.auto)
                Text("Constant RPM").tag(Kind.constant)
                Text("Sensor-based").tag(Kind.sensor)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(fan.validLimits == nil || controller.helperState == .notInstalled || controller.isControlledElsewhere(fan.index))

            if let limits = fan.validLimits {
                switch kind {
                case .auto where controller.isControlledElsewhere(fan.index):
                    Text("\(controller.otherFanApp ?? "Another app") is controlling this fan. Set it to Auto there to control it from SparkV.")
                        .font(SparkVTheme.body(11.5)).foregroundStyle(SparkVTheme.warning)
                case .auto:
                    Text(controller.helperState == .notInstalled
                         ? "macOS controls this fan. Install the fan helper to set its speed."
                         : "macOS controls this fan.")
                        .font(SparkVTheme.body(11.5)).foregroundStyle(SparkVTheme.textSecondary)
                case .constant:
                    constantControls(limits)
                case .sensor:
                    sensorControls(limits)
                }
            } else {
                Text("This fan does not report its speed limits, so SparkV leaves it on Auto.")
                    .font(SparkVTheme.body(11.5)).foregroundStyle(SparkVTheme.textSecondary)
            }
        }
        .padding(14)
        .background(shape.fill(manual ? SparkVTheme.redSoft : SparkVTheme.surface))
        .overlay(shape.strokeBorder(manual ? SparkVTheme.red.opacity(0.45) : LabsBStyle.chipStroke))
        .onAppear { draft.load(mode, limits: fan.validLimits) }
        .onChange(of: mode) { _, newMode in draft.load(newMode, limits: fan.validLimits) }
    }

    private func constantControls(_ limits: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speed").font(SparkVTheme.caption(11)).foregroundStyle(SparkVTheme.textSecondary)
                Spacer()
                Text("\(Int(draft.rpm)) rpm").font(SparkVTheme.headline(12).monospacedDigit())
            }
            Slider(value: $draft.rpm, in: limits, step: 25) { editing in
                if !editing { controller.setMode(.constant(rpm: draft.rpm), for: fan.index) }
            }
            .tint(SparkVTheme.accent)
            .accessibilityLabel("Speed")
            HStack {
                Text("\(Int(limits.lowerBound)) (fan minimum)")
                Spacer()
                Text("\(Int(limits.upperBound))")
            }
            .font(SparkVTheme.caption(9.5).monospacedDigit())
            .foregroundStyle(SparkVTheme.textTertiary)
        }
    }

    private func sensorControls(_ limits: ClosedRange<Double>) -> some View {
        let current = controller.snapshot.sensor(draft.sensorID)?.celsius
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Sensor", selection: Binding(get: { draft.sensorID }, set: { id in
                    draft.sensorID = id
                    commitCurve()
                })) {
                    ForEach(sensorChoices, id: \.id) { sensor in
                        Text(sensor.name).tag(sensor.id)
                    }
                }
                .font(SparkVTheme.body(11.5))
                curveSlider("Start", value: $draft.startC, range: 20...100)
                curveSlider("Max speed at", value: $draft.maxC, range: 25...110)
                Text("Fan minimum at \(Int(draft.startC)) °C and below, maximum at \(Int(draft.maxC)) °C and above.")
                    .font(SparkVTheme.caption(10)).foregroundStyle(SparkVTheme.textTertiary)
            }
            FanCurvePreview(startC: draft.startC, maxC: draft.maxC, limits: limits, current: current,
                            fahrenheit: controller.settings.fahrenheit)
                .frame(width: 150, height: 92)
        }
    }

    /// The saved sensor first, even if it is not in this reading.
    private var sensorChoices: [FanSensorReading] {
        var list = controller.curveSensors
        if !list.contains(where: { $0.id == draft.sensorID }) {
            list.insert(FanSensorReading(id: draft.sensorID, name: FanControlMode.sensorFallbackName(draft.sensorID),
                                         group: .other, celsius: 0, isAggregate: true), at: 0)
        }
        return list
    }

    private func curveSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(SparkVTheme.caption(11)).foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: 1) { editing in
                if !editing { commitCurve() }
            }
            .tint(SparkVTheme.accent)
            .accessibilityLabel(title)
            Text(controller.temperatureText(value.wrappedValue))
                .font(SparkVTheme.headline(11.5).monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func commitCurve() {
        let curve = FanCurveMath.sanitizedCurve(startC: draft.startC, maxC: draft.maxC)
        draft.startC = curve.startC
        draft.maxC = curve.maxC
        controller.setMode(.sensor(id: draft.sensorID, startC: curve.startC, maxC: curve.maxC), for: fan.index)
    }
}

/// The linear curve with the sensor's current reading marked.
struct FanCurvePreview: View {
    let startC: Double
    let maxC: Double
    let limits: ClosedRange<Double>
    let current: Double?
    let fahrenheit: Bool

    private let tRange = 20.0...110.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height - 12
            let x: (Double) -> CGFloat = { CGFloat(($0 - tRange.lowerBound) / (tRange.upperBound - tRange.lowerBound)) * w }
            let y: (Double) -> CGFloat = { h - CGFloat(($0 - limits.lowerBound) / (limits.upperBound - limits.lowerBound)) * h }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(SparkVTheme.background.opacity(0.6))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y(limits.lowerBound)))
                    p.addLine(to: CGPoint(x: x(startC), y: y(limits.lowerBound)))
                    p.addLine(to: CGPoint(x: x(maxC), y: y(limits.upperBound)))
                    p.addLine(to: CGPoint(x: w, y: y(limits.upperBound)))
                }
                .stroke(SparkVTheme.red, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let current, tRange.contains(current) {
                    let rpm = FanCurveMath.target(temperature: current, startC: startC, maxC: maxC, limits: limits)
                    Circle().fill(Color.white)
                        .frame(width: 7, height: 7)
                        .position(x: x(current), y: y(rpm))
                }
                HStack {
                    Text(FanFormat.temperature(tRange.lowerBound, fahrenheit: fahrenheit))
                    Spacer()
                    Text(FanFormat.temperature(tRange.upperBound, fahrenheit: fahrenheit))
                }
                .font(SparkVTheme.caption(8.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .offset(y: h + 1)
            }
        }
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
