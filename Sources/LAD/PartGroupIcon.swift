import SwiftUI

/// Three outlined cubes: two below and one centered above, matching the
/// single-cube part glyph while distinguishing a group from a physical part.
struct PartGroupIcon: View {
    var showsAddBadge = false

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2,
                                y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            func cube(centerX: CGFloat, top: CGFloat) {
                var cubes = Path()
                cubes.move(to: CGPoint(x: centerX, y: top))
                for point in [
                    CGPoint(x: centerX + 5.5, y: top + 3),
                    CGPoint(x: centerX + 5.5, y: top + 9),
                    CGPoint(x: centerX, y: top + 12),
                    CGPoint(x: centerX - 5.5, y: top + 9),
                    CGPoint(x: centerX - 5.5, y: top + 3)
                ] { cubes.addLine(to: point) }
                cubes.closeSubpath()
                // Draw the lower cubes first; the upper cube's faces hide
                // any shared strokes beneath it, matching the approved icon.
                context.fill(cubes, with: .color(Palette.panel))
                cubes.move(to: CGPoint(x: centerX - 5.5, y: top + 3))
                for point in [
                    CGPoint(x: centerX, y: top + 6),
                    CGPoint(x: centerX + 5.5, y: top + 3)
                ] { cubes.addLine(to: point) }
                cubes.move(to: CGPoint(x: centerX, y: top + 6))
                cubes.addLine(to: CGPoint(x: centerX, y: top + 12))
                context.stroke(cubes, with: .foreground,
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
            cube(centerX: 6.5, top: 10)
            cube(centerX: 17.5, top: 10)
            cube(centerX: 12, top: 1)
            if showsAddBadge {
                context.fill(Path(ellipseIn: CGRect(x: 16.8, y: -0.3, width: 8.4, height: 8.4)),
                             with: .color(Palette.panel))
                var plus = Path()
                plus.move(to: CGPoint(x: 18.5, y: 3.9))
                plus.addLine(to: CGPoint(x: 23.5, y: 3.9))
                plus.move(to: CGPoint(x: 21, y: 1.4))
                plus.addLine(to: CGPoint(x: 21, y: 6.4))
                context.stroke(plus, with: .foreground,
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
