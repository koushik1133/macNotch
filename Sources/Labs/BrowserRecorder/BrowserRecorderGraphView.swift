import SwiftUI

/// Read-only node graph of a flow: a Manual trigger card followed by one
/// card per step, joined by curved connectors. Cards are laid out in a
/// snake (left→right, then right→left) so long flows fit the window width.
/// Inspired by block editors such as Automa (no code from them is used).
struct BrowserRecorderGraphView: View {
    let flow: BRFlow
    let statuses: [String: BRStepStatus]

    private let cardSize = CGSize(width: 190, height: 78)
    private let gap = CGSize(width: 46, height: 40)
    private let inset: CGFloat = 24

    private struct Node: Identifiable {
        let id: String
        let index: Int?
        let step: BRStep?
        let frame: CGRect
        /// Direction the row flows in (connectors leave from this side).
        let leftToRight: Bool
    }

    var body: some View {
        GeometryReader { geo in
            let nodes = layout(width: geo.size.width)
            let height = (nodes.map(\.frame.maxY).max() ?? 0) + inset
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    BRDotGrid()
                        .frame(width: geo.size.width, height: max(height, geo.size.height))
                    BRConnectors(frames: nodes.map(\.frame), directions: nodes.map(\.leftToRight), disabled: nodes.map { $0.step?.isDisabled ?? false })
                        .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: geo.size.width, height: max(height, geo.size.height))
                    ForEach(nodes) { node in
                        Group {
                            if let step = node.step, let index = node.index {
                                BRGraphCard(step: step, index: index, status: statuses[step.id])
                            } else {
                                BRTriggerCard(flow: flow)
                            }
                        }
                        .frame(width: node.frame.width, height: node.frame.height)
                        .offset(x: node.frame.minX, y: node.frame.minY)
                    }
                }
                .frame(width: geo.size.width, height: max(height, geo.size.height), alignment: .topLeading)
            }
        }
        .background(SparkVTheme.background)
    }

    private func layout(width: CGFloat) -> [Node] {
        let columns = max(1, Int((width - 2 * inset + gap.width) / (cardSize.width + gap.width)))
        let used = CGFloat(columns) * cardSize.width + CGFloat(columns - 1) * gap.width
        let leading = max(inset, (width - used) / 2)
        let items: [(BRStep?, Int?)] = [(nil, nil)] + flow.steps.enumerated().map { ($0.element, $0.offset) }
        return items.enumerated().map { position, item in
            let row = position / columns
            let column = position % columns
            let leftToRight = row.isMultiple(of: 2)
            let visualColumn = leftToRight ? column : columns - 1 - column
            let origin = CGPoint(
                x: leading + CGFloat(visualColumn) * (cardSize.width + gap.width),
                y: inset + CGFloat(row) * (cardSize.height + gap.height)
            )
            return Node(id: item.0?.id ?? "trigger", index: item.1, step: item.0,
                        frame: CGRect(origin: origin, size: cardSize), leftToRight: leftToRight)
        }
    }
}

/// Bezier connectors between consecutive cards: sideways within a row,
/// down and around at the end of a row.
private struct BRConnectors: Shape {
    let frames: [CGRect]
    let directions: [Bool]
    let disabled: [Bool]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard frames.count > 1 else { return path }
        for i in 0..<(frames.count - 1) {
            let a = frames[i], b = frames[i + 1]
            if abs(a.midY - b.midY) < 1 {
                let ltr = directions[i]
                let start = CGPoint(x: ltr ? a.maxX : a.minX, y: a.midY)
                let end = CGPoint(x: ltr ? b.minX : b.maxX, y: b.midY)
                let dx = (end.x - start.x) / 2
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                addArrow(&path, at: end, pointingRight: ltr)
                // Port on the side the connector leaves from.
                path.addEllipse(in: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
            } else {
                // Row wrap: leave from the bottom, enter the next card's top.
                let start = CGPoint(x: a.midX, y: a.maxY)
                let end = CGPoint(x: b.midX, y: b.minY)
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + 24), control2: CGPoint(x: end.x, y: end.y - 24))
                path.move(to: CGPoint(x: end.x - 4, y: end.y - 6))
                path.addLine(to: end)
                path.addLine(to: CGPoint(x: end.x + 4, y: end.y - 6))
                path.addEllipse(in: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
            }
        }
        return path
    }

    private func addArrow(_ path: inout Path, at point: CGPoint, pointingRight: Bool) {
        let s: CGFloat = pointingRight ? -1 : 1
        path.move(to: CGPoint(x: point.x + 6 * s, y: point.y - 4))
        path.addLine(to: point)
        path.addLine(to: CGPoint(x: point.x + 6 * s, y: point.y + 4))
    }
}

private struct BRDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 18
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)), with: .color(Color.white.opacity(0.07)))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

extension BRStepGroup {
    var color: Color {
        switch self {
        // Apple: one system tint per kind, as before the sparkv.si restyle.
        // SparkV Red: monochrome; the step's glyph tells the kind apart.
        case .browser: SparkVTheme.choose(apple: Color(red: 0.35, green: 0.55, blue: 1.0), sparkv: SparkVTheme.textSecondary)
        case .interaction: SparkVTheme.choose(apple: Color(red: 0.62, green: 0.45, blue: 1.0), sparkv: SparkVTheme.textSecondary)
        case .forms: SparkVTheme.choose(apple: Color(red: 0.25, green: 0.78, blue: 0.62), sparkv: SparkVTheme.textSecondary)
        case .control: SparkVTheme.choose(apple: Color(red: 1.0, green: 0.62, blue: 0.25), sparkv: SparkVTheme.textSecondary)
        case .note: SparkVTheme.textTertiary
        }
    }
}

extension BRStepStatus {
    var color: Color {
        switch self {
        case .pending: SparkVTheme.stroke
        case .running: SparkVTheme.accent
        case .done: SparkVTheme.success
        case .healed: SparkVTheme.warning
        case .failed: SparkVTheme.destructive
        }
    }

    var symbol: String? {
        switch self {
        case .pending: nil
        case .running: "play.fill"
        case .done: "checkmark"
        case .healed: "bandage.fill"
        case .failed: "xmark"
        }
    }
}

private struct BRTriggerCard: View {
    let flow: BRFlow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.choose(apple: Color(red: 0.95, green: 0.3, blue: 0.45), sparkv: SparkVTheme.brandRed)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trigger")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text("Manual: runs only when you press Replay")
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(BRCardBackground(accent: nil))
    }
}

private struct BRGraphCard: View {
    let step: BRStep
    let index: Int
    let status: BRStepStatus?

    var body: some View {
        let kind = step.kind
        let tint = kind?.group.color ?? .gray
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind?.symbol ?? "questionmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(step.isDisabled ? SparkVTheme.textTertiary : SparkVTheme.text)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(SparkVTheme.surfaceHover))
                .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(index + 1). \(kind?.label ?? step.type)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                    if step.masked == true {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(SparkVTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if let status, let symbol = status.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(status == .failed || status == .running ? Color.white : Color.black)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(status.color))
                    }
                }
                Text(step.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(step.isDisabled ? SparkVTheme.textTertiary : SparkVTheme.text)
                    .lineLimit(1)
                Text(step.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(BRCardBackground(accent: status.flatMap { $0 == .pending ? nil : $0.color }))
        .opacity(step.isDisabled ? 0.6 : 1)
    }
}

private struct BRCardBackground: View {
    let accent: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(white: 0.085))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accent ?? SparkVTheme.stroke, lineWidth: accent == nil ? 1 : 1.6)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 6, y: 3)
    }
}
