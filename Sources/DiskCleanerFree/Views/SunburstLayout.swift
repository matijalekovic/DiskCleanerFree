import SwiftUI

/// The rings of the map for one focused folder. Angles are in radians, clockwise from 12 o'clock.
struct SunburstLayout {
    struct Segment {
        /// `nil` for the free-space wedge.
        let node: FileNode?
        let depth: Int
        let start: Double
        let end: Double
        let color: Color
    }

    struct Key: Equatable {
        let focus: ObjectIdentifier?
        let revision: Int
        let depth: Int
        let showFree: Bool
        let colorfulFiles: Bool
    }

    var segments: [Segment] = []
    var depth = 6
    /// Colors of the focused folder's direct children, shared with the item list.
    var colors: [ObjectIdentifier: Color] = [:]
    var freeSpace: Int64 = 0

    static let minAngle = 0.0035
    static let freeColor = Color.secondary.opacity(0.18)

    init() {}

    init(focus: FileNode, depth: Int, freeSpace: Int64, colorfulFiles: Bool) {
        self.depth = depth
        self.freeSpace = freeSpace
        let total = Double(focus.size + freeSpace)
        guard total > 0 else { return }
        let span = 2 * Double.pi * Double(focus.size) / total
        build(focus, depth: 1, start: 0, span: span, colorfulFiles: colorfulFiles)
        if freeSpace > 0 {
            segments.append(Segment(node: nil, depth: 1, start: span, end: 2 * .pi, color: Self.freeColor))
        }
    }

    private mutating func build(_ node: FileNode, depth: Int, start: Double, span: Double, colorfulFiles: Bool) {
        guard depth <= self.depth, node.size > 0 else { return }
        var angle = start
        let scale = span / Double(node.size)
        for child in node.children {
            let childSpan = Double(child.size) * scale
            if childSpan < Self.minAngle { break }
            let color = Palette.color(for: child, midAngle: angle + childSpan / 2, depth: depth, colorfulFiles: colorfulFiles)
            segments.append(Segment(node: child, depth: depth, start: angle, end: angle + childSpan, color: color))
            if depth == 1 { colors[child.id] = color }
            if child.isDirectory, !child.children.isEmpty {
                build(child, depth: depth + 1, start: angle, span: childSpan, colorfulFiles: colorfulFiles)
            }
            angle += childSpan
        }
    }

    func segment(depth: Int, angle: Double) -> Segment? {
        segments.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }
}

enum Palette {
    static func color(for node: FileNode, midAngle: Double, depth: Int, colorfulFiles: Bool) -> Color {
        let hue = (midAngle / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        let d = Double(depth - 1)
        switch node.kind {
        case .hidden:
            return Color(white: 0.46)
        case .purgeable:
            return Color(white: 0.66)
        case .restricted:
            return Color(hue: hue, saturation: 0.12, brightness: 0.55)
        case .file, .symlink:
            return colorfulFiles
                ? Color(hue: hue, saturation: max(0.18, 0.42 - 0.04 * d), brightness: 0.86)
                : Color(hue: hue, saturation: 0.08, brightness: min(0.9, 0.72 + 0.03 * d))
        case .folder, .package, .systemVolume:
            return Color(hue: hue, saturation: max(0.32, 0.86 - 0.09 * d), brightness: min(0.98, 0.80 + 0.035 * d))
        }
    }
}

/// Radii of the rings. Rings get slightly thinner toward the edge, which keeps the outer detail readable.
struct RingGeometry {
    let center: CGPoint
    let inner: CGFloat
    let outer: CGFloat
    /// radii[d - 1] ... radii[d] bounds ring `d`.
    let radii: [CGFloat]

    init(size: CGSize, depth: Int) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        outer = max(40, min(size.width, size.height) / 2 - 18)
        inner = outer * 0.24
        let falloff: CGFloat = 0.88
        let weights = (0..<depth).map { pow(falloff, CGFloat($0)) }
        let unit = (outer - inner) / weights.reduce(0, +)
        var r = [inner]
        for w in weights { r.append(r.last! + w * unit) }
        radii = r
    }

    /// Ring index (1-based), 0 for the center disc, nil outside.
    func ring(at point: CGPoint) -> (depth: Int, angle: Double)? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r = sqrt(dx * dx + dy * dy)
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        if r < inner { return (0, Double(angle)) }
        guard r <= outer else { return nil }
        let depth = radii.firstIndex { $0 >= r } ?? radii.count - 1
        return (max(1, depth), Double(angle))
    }

    func path(depth: Int, start: Double, end: Double) -> Path {
        let r0 = radii[depth - 1] + 0.5
        let r1 = radii[depth] - 0.5
        let a0 = Angle.radians(start - .pi / 2)
        let a1 = Angle.radians(end - .pi / 2)
        var path = Path()
        if end - start >= 2 * .pi - 0.0001 {
            path.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: r1 * 2, height: r1 * 2))
            path.addEllipse(in: CGRect(x: center.x - r0, y: center.y - r0, width: r0 * 2, height: r0 * 2))
            return path
        }
        path.addArc(center: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return path
    }
}
