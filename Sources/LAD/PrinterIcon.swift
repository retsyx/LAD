import SwiftUI

/// A 3D printer: two uprights, a gantry rail carrying the nozzle, and a base.
/// Kept to a few heavy strokes so it stays legible at toolbar size.
struct PrinterIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2,
                                y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            var gantry = Path()
            for (start, end) in [((3.5, 4.0), (3.5, 19.5)), ((20.5, 4.0), (20.5, 19.5)),
                                 ((3.5, 8.5), (20.5, 8.5)), ((1.5, 19.5), (22.5, 19.5))] {
                gantry.move(to: CGPoint(x: start.0, y: start.1))
                gantry.addLine(to: CGPoint(x: end.0, y: end.1))
            }
            context.stroke(gantry, with: .foreground,
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            var nozzle = Path()
            nozzle.move(to: CGPoint(x: 9.25, y: 8.5))
            nozzle.addLine(to: CGPoint(x: 14.75, y: 8.5))
            nozzle.addLine(to: CGPoint(x: 12, y: 13))
            nozzle.closeSubpath()
            context.fill(nozzle, with: .foreground)
            context.stroke(nozzle, with: .foreground, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
