import SwiftUI

/// A part turned onto the build plate, drawn with the same heavy strokes as
/// `PrinterIcon` so the two 3D printing toggles read as a pair.
struct PrintLayoutIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2,
                                y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let heavy = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)

            var bed = Path()
            bed.move(to: CGPoint(x: 2, y: 20.5))
            bed.addLine(to: CGPoint(x: 22, y: 20.5))
            context.stroke(bed, with: .foreground, style: heavy)
            context.fill(Path(roundedRect: CGRect(x: 7, y: 13.5, width: 10, height: 6.2), cornerRadius: 0.6),
                         with: .foreground)

            // A clockwise turn over the part, ending in an arrowhead.
            let center = CGPoint(x: 12, y: 13), radius = 8.0, end = Angle.degrees(338)
            var turn = Path()
            turn.addArc(center: center, radius: radius, startAngle: .degrees(200), endAngle: end, clockwise: false)
            context.stroke(turn, with: .foreground, style: heavy)
            let tip = CGPoint(x: center.x + radius * cos(end.radians), y: center.y + radius * sin(end.radians))
            let tangent = CGVector(dx: -sin(end.radians), dy: cos(end.radians))
            let normal = CGVector(dx: cos(end.radians), dy: sin(end.radians))
            var head = Path()
            head.move(to: CGPoint(x: tip.x + tangent.dx * 2.2, y: tip.y + tangent.dy * 2.2))
            head.addLine(to: CGPoint(x: tip.x - tangent.dx * 0.6 + normal.dx * 2.1, y: tip.y - tangent.dy * 0.6 + normal.dy * 2.1))
            head.addLine(to: CGPoint(x: tip.x - tangent.dx * 0.6 - normal.dx * 2.1, y: tip.y - tangent.dy * 0.6 - normal.dy * 2.1))
            head.closeSubpath()
            context.fill(head, with: .foreground)
            context.stroke(head, with: .foreground, style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
