import SwiftUI

@MainActor
final class WidgetsTabUI: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case widgets = "Widgets"
        case clocks = "Cities"
        case habits = "Habits"
        case weather = "Weather"
        var id: String { rawValue }
    }

    @Published var page = 0
    @Published var isEditing = false
    @Published var section: Section = .widgets

    init(editing section: Section? = nil) {
        if let section {
            self.section = section
            isEditing = true
        }
    }

    func edit(_ section: Section) {
        self.section = section
        isEditing = true
    }
}

/// The models the widgets read. `live` uses the shared ones; tests and
/// offscreen renders pass their own (named UserDefaults suites, a fake
/// audio backend, samplers that don't start).
@MainActor
struct WidgetModels {
    var clocks: WorldClockStore
    var habits: HabitStore
    var volume: VolumeKnobModel
    var gauges: SystemGaugesSampler
    var network: NetworkSpeedSampler
    var weather: WeatherController = .shared
    var reminders: RemindersController = .shared
    /// False draws the samplers' current values without starting them.
    var samples = true
    /// Fixed clock for renders.
    var fixedDate: Date? = nil

    static var live: WidgetModels {
        WidgetModels(clocks: .shared, habits: .shared, volume: .shared, gauges: .shared, network: .shared)
    }
}

/// The Widgets tab: the chosen widgets packed on a grid that adapts to the
/// drawer (4x2 cells of about 116x54 pt in the tall drawer, 4x1 of 116x69 in
/// the short one), a slim rail on the right with the editor button and page
/// controls, and an edit page to choose widgets, cities and habits.
struct WidgetsTabView: View {
    @ObservedObject var settings: WidgetsSettings
    let models: WidgetModels
    @StateObject private var ui: WidgetsTabUI

    /// Nil arguments use the shared settings and live models.
    @MainActor
    init(settings: WidgetsSettings? = nil, models: WidgetModels? = nil, editing: WidgetsTabUI.Section? = nil) {
        self.settings = settings ?? .shared
        self.models = models ?? .live
        _ui = StateObject(wrappedValue: WidgetsTabUI(editing: editing))
    }

    /// Grid geometry for an area, pure so it is tested.
    struct Grid: Equatable {
        let columns: Int
        let rows: Int
        let cell: CGSize

        init(area: CGSize) {
            let s = WidgetStyle.spacing
            columns = max(1, Int((area.width + s) / (WidgetStyle.minCellWidth + s)))
            rows = max(1, Int((area.height + s) / (WidgetStyle.minCellHeight + s)))
            cell = CGSize(width: max(0, (area.width - CGFloat(columns - 1) * s) / CGFloat(columns)),
                          height: max(0, (area.height - CGFloat(rows - 1) * s) / CGFloat(rows)))
        }

        func frame(_ p: WidgetPlacement) -> CGRect {
            let s = WidgetStyle.spacing
            return CGRect(x: CGFloat(p.column) * (cell.width + s), y: CGFloat(p.row) * (cell.height + s),
                          width: CGFloat(p.size.columns) * cell.width + CGFloat(p.size.columns - 1) * s,
                          height: CGFloat(p.size.rows) * cell.height + CGFloat(p.size.rows - 1) * s)
        }

        func frame(column: Int, row: Int) -> CGRect {
            frame(WidgetPlacement(kind: .volume, size: .small, column: column, row: row))
        }
    }

    var body: some View {
        GeometryReader { geo in
            let area = CGSize(width: max(0, geo.size.width - WidgetStyle.railWidth - WidgetStyle.spacing), height: geo.size.height)
            let grid = Grid(area: area)
            let pages = WidgetGridLayout.pages(for: settings.enabled, columns: grid.columns, rows: grid.rows)
            let page = min(ui.page, max(0, pages.count - 1))
            HStack(spacing: WidgetStyle.spacing) {
                ZStack(alignment: .topLeading) {
                    // Content swaps crossfade with a light blur, so the two
                    // pages never read as a double exposure.
                    if ui.isEditing {
                        WidgetsEditPage(settings: settings, ui: ui, models: models)
                            .transition(.sparkVCrossfade)
                    } else if pages.isEmpty {
                        emptyState.transition(.sparkVCrossfade)
                    } else {
                        gridPage(pages[page], grid: grid)
                            .id(page)
                            .transition(.sparkVCrossfade)
                    }
                }
                .frame(width: area.width, height: area.height, alignment: .topLeading)
                WidgetsRail(ui: ui, pageCount: ui.isEditing ? 0 : pages.count, page: page)
                    .frame(width: WidgetStyle.railWidth, height: area.height)
            }
            // Swaps: strong ease-out (enter/exit). Reflowing widgets move on
            // screen with an interruptible spring (toggles can come fast).
            .animation(SparkVMotion.easeOut(SparkVMotion.Duration.standard), value: ui.isEditing)
            .animation(SparkVMotion.easeOut(SparkVMotion.Duration.standard), value: page)
            .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: settings.enabled)
        }
    }

    private func gridPage(_ placements: [WidgetPlacement], grid: Grid) -> some View {
        let free = WidgetGridLayout.freeCells(placements, columns: grid.columns, rows: grid.rows)
        let hidden = WidgetKind.allCases.filter { !settings.isEnabled($0) }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(placements.enumerated()), id: \.element.kind) { index, placement in
                let frame = grid.frame(placement)
                widget(placement.kind, size: placement.size)
                    .frame(width: frame.width, height: frame.height)
                    // Cards come in one after another (40 ms apart) when the
                    // page appears; renders (fixed date) draw them settled.
                    .modifier(WidgetStaggeredEntrance(index: index, isEnabled: models.fixedDate == nil))
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.sparkVEnter)
            }
            if let cell = free.first, !hidden.isEmpty {
                let frame = grid.frame(column: cell.column, row: cell.row)
                AddWidgetTile(hidden: hidden) { kind in settings.setEnabled(kind, true) } onEdit: { ui.edit(.widgets) }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
    }

    @ViewBuilder
    private func widget(_ kind: WidgetKind, size: WidgetSize) -> some View {
        Group {
            switch kind {
            case .clocks: WorldClockWidget(store: models.clocks, size: size, onEdit: { ui.edit(.clocks) }, fixedDate: models.fixedDate)
            case .volume: VolumeKnobWidget(model: models.volume, size: size)
            case .habits: HabitsWidget(store: models.habits, size: size, onEdit: { ui.edit(.habits) }, fixedDate: models.fixedDate)
            case .gauges: SystemGaugesWidget(sampler: models.gauges, size: size, samples: models.samples)
            case .network: NetworkSpeedWidget(sampler: models.network, size: size, samples: models.samples)
            case .script: ScriptWidgetCell(compact: size == .small)
            case .weather: WeatherWidget(controller: models.weather, size: size, onEdit: { ui.edit(.weather) }, fixedDate: models.fixedDate)
            case .reminders: RemindersWidget(controller: models.reminders, size: size, fixedDate: models.fixedDate)
            case .brightness: HUDBrightnessWidget()
            }
        }
        .contextMenu {
            if kind == .clocks { Button("Choose Cities…") { ui.edit(.clocks) } }
            if kind == .habits { Button("Edit Habits…") { ui.edit(.habits) } }
            if kind == .weather {
                Button("Weather City…") { ui.edit(.weather) }
                Button("Refresh Weather") { models.weather.refresh() }.disabled(!models.weather.isConfigured)
            }
            if kind == .reminders { Button("Open Reminders") { models.reminders.openRemindersApp() } }
            Button("Move Earlier") { settings.move(kind, by: -1) }.disabled(settings.enabled.first == kind)
            Button("Move Later") { settings.move(kind, by: 1) }.disabled(settings.enabled.last == kind)
            Divider()
            Button("Hide \(kind.title)") { settings.setEnabled(kind, false) }
            Button("Choose Widgets…") { ui.edit(.widgets) }
        }
    }

    private var emptyState: some View {
        Button { ui.edit(.widgets) } label: {
            VStack(spacing: 5) {
                Image(systemName: "square.grid.2x2").font(.system(size: 16, weight: .semibold)).foregroundStyle(WidgetStyle.secondaryText)
                Text("Choose widgets").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                Text("World clocks, volume, habits, system, network, weather and reminders")
                    .font(.system(size: 9)).foregroundStyle(WidgetStyle.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous).fill(WidgetStyle.cardFill))
            .overlay(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous).strokeBorder(WidgetStyle.cardStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
    }
}

/// Staggered entrance for one grid card: fades up from 96 % (fade only under
/// Reduce Motion), `SparkVMotion.stagger(index)` after the page appears. It
/// is decorative, so the card takes clicks while it plays.
private struct WidgetStaggeredEntrance: ViewModifier {
    let index: Int
    let isEnabled: Bool
    @StateObject private var shown = ViewFlag()

    func body(content: Content) -> some View {
        let visible = shown.isOn || !isEnabled
        let still = SparkVMotion.reduceMotion
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible || still ? 1 : SparkVMotion.enterScale, anchor: .top)
            .offset(y: visible || still ? 0 : -4)
            .onAppear {
                guard isEnabled, !shown.isOn else { return }
                withAnimation(SparkVMotion.easeOut(SparkVMotion.Duration.standard).delay(SparkVMotion.stagger(index))) {
                    shown.isOn = true
                }
            }
    }
}

// MARK: - Rail

private struct WidgetsRail: View {
    @ObservedObject var ui: WidgetsTabUI
    let pageCount: Int
    let page: Int

    var body: some View {
        VStack(spacing: 3) {
            RailButton(systemImage: ui.isEditing ? "checkmark" : "slider.horizontal.3",
                       isActive: ui.isEditing, help: ui.isEditing ? "Done" : "Choose widgets, cities and habits") {
                ui.isEditing.toggle()
            }
            Spacer(minLength: 0)
            if pageCount > 1 {
                RailButton(systemImage: "chevron.up", help: "Previous page") { ui.page = max(0, page - 1) }
                    .disabled(page == 0)
                    .opacity(page == 0 ? 0.35 : 1)
                VStack(spacing: 3) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle().fill(index == page ? SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red) : Color.white.opacity(0.25)).frame(width: 4, height: 4)
                    }
                }
                RailButton(systemImage: "chevron.down", help: "Next page") { ui.page = min(pageCount - 1, page + 1) }
                    .disabled(page >= pageCount - 1)
                    .opacity(page >= pageCount - 1 ? 0.35 : 1)
            }
        }
    }
}

private struct RailButton: View {
    let systemImage: String
    var isActive = false
    let help: String
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isActive ? Color.white : (hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary))
                .frame(width: WidgetStyle.railWidth, height: WidgetStyle.railWidth)
                .background(Circle().fill(isActive ? SparkVTheme.accent : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
                .overlay(Circle().strokeBorder(isActive ? Color.clear : LabsBStyle.chipStroke, lineWidth: 1))
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Free cell: adds a hidden widget.
private struct AddWidgetTile: View {
    let hidden: [WidgetKind]
    let onAdd: (WidgetKind) -> Void
    let onEdit: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Menu {
            ForEach(hidden) { kind in
                Button { onAdd(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
            }
            Divider()
            Button("Choose Widgets…", action: onEdit)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                Text("Add widget").font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(hover.isOn ? LabsBStyle.hoverGlyph : SparkVTheme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
                    .strokeBorder(hover.isOn ? SparkVTheme.choose(apple: Color.white.opacity(0.4), sparkv: SparkVTheme.red.opacity(0.6)) : Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover.isOn = $0 }
    }
}

// MARK: - Edit page

private struct WidgetsEditPage: View {
    @ObservedObject var settings: WidgetsSettings
    @ObservedObject var ui: WidgetsTabUI
    let models: WidgetModels

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(WidgetsTabUI.Section.allCases) { section in
                    WidgetChip(title: section.rawValue, tint: .white, isOn: ui.section == section) { ui.section = section }
                }
                Spacer(minLength: 4)
                Text(hint)
                    .font(.system(size: 8.5))
                    .foregroundStyle(WidgetStyle.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: 20)
            Group {
                switch ui.section {
                case .widgets: WidgetPicker(settings: settings)
                case .clocks: WorldClockEditor(store: models.clocks)
                case .habits: HabitEditor(store: models.habits)
                case .weather: WeatherCityEditor(controller: models.weather)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var hint: String {
        switch ui.section {
        case .widgets: "Order follows the numbers; right-click a widget to move it"
        case .clocks: "Up to 3 cities"
        case .habits: "Up to \(HabitStore.maxHabits) habits"
        case .weather: OpenMeteo.attribution
        }
    }
}

/// One toggle tile per widget, numbered by position.
private struct WidgetPicker: View {
    @ObservedObject var settings: WidgetsSettings

    var body: some View {
        HStack(spacing: WidgetStyle.spacing) {
            ForEach(WidgetKind.allCases) { kind in
                WidgetToggleTile(kind: kind, position: settings.enabled.firstIndex(of: kind).map { $0 + 1 }) {
                    settings.toggle(kind)
                }
            }
        }
    }
}

private struct WidgetToggleTile: View {
    let kind: WidgetKind
    let position: Int?
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let on = position != nil
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? kind.tint : SparkVTheme.textTertiary)
                Text(kind.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(on ? SparkVTheme.text : SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
                    .fill(on ? SparkVTheme.choose(apple: Color.white.opacity(hover.isOn ? 0.16 : 0.11), sparkv: SparkVTheme.redSoft.opacity(hover.isOn ? 1.5 : 1))
                               : (SparkVTheme.isApple ? Color.white.opacity(hover.isOn ? 0.08 : 0.04) : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
                    .strokeBorder(SparkVTheme.isApple ? Color.clear : (on ? kind.tint.opacity(0.5) : SparkVTheme.stroke), lineWidth: 1)
            )
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(on ? kind.tint : Color.white.opacity(0.12))
                    if let position {
                        Text("\(position)").font(.system(size: 7.5, weight: .heavy, design: .monospaced)).foregroundStyle(Color.white)
                    }
                }
                .frame(width: 12, height: 12)
                .padding(4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(on ? "Hide \(kind.title)" : "Show \(kind.title)")
    }
}

// MARK: - Home accessory

/// Fits beside the media column in the Home view (56x56 pt): the volume
/// knob without its card, which pairs with the playback controls. Once a
/// weather city is set (and unless "Show on Home" is off), the day's
/// weather takes its place.
struct WidgetsHomeAccessory: View {
    @ObservedObject private var weather = WeatherController.shared

    var body: some View {
        if weather.showsHomeGlance {
            WeatherHomeGlance(controller: weather)
                .transition(.sparkVCrossfade)
        } else {
            VolumeKnobWidget(compact: true)
                .contextMenu { SoundOutputMenuItems() }
                .transition(.sparkVCrossfade)
        }
    }
}
