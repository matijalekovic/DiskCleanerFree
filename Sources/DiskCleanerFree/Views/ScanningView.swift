import SwiftUI

struct ScanningView: View {
    let session: ScanSession

    var body: some View {
        // Shrinks the rings step by step when the window gets short, instead of clipping.
        ViewThatFits(in: .vertical) {
            content(ringSize: 290)
            content(ringSize: 220)
            content(ringSize: 160)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(session.source.name)
        .navigationSubtitle("Scanning")
    }

    private func content(ringSize: CGFloat) -> some View {
        VStack(spacing: ringSize > 200 ? 28 : 16) {
            ScanningHero(session: session, size: ringSize)

            VStack(spacing: 6) {
                Text(session.isAdminScanInFlight ? "Scanning “\(session.source.name)” as Administrator…" : "Scanning “\(session.source.name)”…")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.currentPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
                Text(Format.duration(session.elapsed))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)

            Button("Cancel Scanning", systemImage: "stop.fill") { session.cancel() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// Spinning rings with the live total in a glass disc. Everything is proportional to `size`.
private struct ScanningHero: View {
    let session: ScanSession
    let size: CGFloat

    var body: some View {
        let disc = size * 0.54
        let side = disc * 0.68
        let scanned = Format.steadyBytes(session.bytesScanned)
        ZStack {
            ScanningRings()
                .frame(width: size, height: size)
            // Fixed-size lines inside the disc's inscribed square: the digits change, the layout doesn't.
            VStack(spacing: 2) {
                Text(scanned.number)
                    .font(.system(size: side * 0.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: side, height: side * 0.36)
                Text(scanned.unit)
                    .font(.system(size: side * 0.14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(height: side * 0.18)
                Text(Format.count(session.filesScanned) + " files")
                    .font(.system(size: max(9, side * 0.11)))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: side, height: side * 0.16)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: disc, height: disc)
            .glassEffect(.regular, in: .circle)
            .transaction { $0.animation = nil }
        }
    }
}

/// Spinning, staggered rainbow arcs.
private struct ScanningRings: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let line = size.width * 0.048
                let gap = size.width * 0.076
                for i in 0..<3 {
                    let radius = size.width / 2 - CGFloat(i) * gap - line * 0.7
                    let speed = 0.6 + Double(i) * 0.35
                    let start = (t * speed + Double(i) * 0.9).truncatingRemainder(dividingBy: 2 * .pi)
                    let sweep = 1.4 + sin(t * 1.3 + Double(i)) * 0.7
                    var track = Path()
                    track.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(track, with: .color(.secondary.opacity(0.1)), lineWidth: line)
                    var path = Path()
                    path.addArc(center: center, radius: radius, startAngle: .radians(start),
                                endAngle: .radians(start + sweep), clockwise: false)
                    let hue = (t * 0.05 + Double(i) * 0.18).truncatingRemainder(dividingBy: 1)
                    context.stroke(path,
                                   with: .color(Color(hue: hue, saturation: 0.75, brightness: 0.95)),
                                   style: StrokeStyle(lineWidth: line, lineCap: .round))
                }
            }
        }
    }
}
