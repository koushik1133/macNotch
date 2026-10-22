import SwiftUI

// The dotted grid and the connections, both drawn in canvas (screen)
// coordinates with SwiftUI Canvas so neither needs a giant frame.

struct FCGridBackground: View {
    let zoom: CGFloat
    let offset: CGSize
    let palette: FCPalette

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.canvas))
            var spacing = FCLayout.gridSpacing * zoom
            // Keep dots at least 12 pt apart when zoomed out.
            while spacing < 12 { spacing *= 2 }
            let radius = max(0.8, min(1.6, 1.2 * zoom))
            let startX = offset.width.truncatingRemainder(dividingBy: spacing) - spacing
            let startY = offset.height.truncatingRemainder(dividingBy: spacing) - spacing
            var dots = Path()
            var y = startY
            while y < size.height + spacing {
                var x = startX
                while x < size.width + spacing {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(palette.dot))
        }
    }
}

struct FCEdgesLayer: View {
    @ObservedObject var editor: FCEditor
    let palette: FCPalette

    var body: some View {
        Canvas { context, _ in
            let width = max(1.5, 2.2 * editor.zoom)
            for edge in editor.document.edges {
                guard let path = editor.edgePath(edge) else { continue }
                let selected = editor.selectedEdge == edge.id
                let running = editor.runningIDs.contains(edge.to)
                let color = selected ? palette.accent : palette.wire
                if selected {
                    context.stroke(path, with: .color(palette.accent.opacity(0.25)), style: StrokeStyle(lineWidth: width + 6, lineCap: .round))
                }
                context.stroke(path, with: .color(running ? palette.accent : color),
                               style: StrokeStyle(lineWidth: selected ? width + 1 : width, lineCap: .round, dash: running ? [6, 5] : []))
                if let to = editor.document.node(edge.to) {
                    let end = editor.toScreen(editor.inputPort(to))
                    let r = max(3, 4 * editor.zoom)
                    context.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)), with: .color(color))
                }
            }
            // Suggested (ghost) connections.
            if let ghost = editor.ghost {
                let all = editor.document.nodes + ghost.nodes
                for edge in ghost.edges {
                    guard let from = all.first(where: { $0.id == edge.from }), let to = all.first(where: { $0.id == edge.to }) else { continue }
                    let path = FCEditor.curve(from: editor.toScreen(editor.outputPort(from)), to: editor.toScreen(editor.inputPort(to)))
                    context.stroke(path, with: .color(palette.accent.opacity(0.7)), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [7, 6]))
                }
            }
            // Connection being dragged.
            if let pending = editor.pendingEdge, let from = editor.document.node(pending.from) {
                let start = editor.toScreen(editor.outputPort(from))
                var end = pending.point
                if let target = pending.target.flatMap(editor.document.node) { end = editor.toScreen(editor.inputPort(target)) }
                let path = FCEditor.curve(from: start, to: end)
                context.stroke(path, with: .color(pending.target == nil ? palette.secondary : palette.accent),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: pending.target == nil ? [6, 5] : []))
            }
        }
        .allowsHitTesting(false)
    }
}
