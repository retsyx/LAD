import simd
import XCTest
@testable import LAD

final class CADSectionInterferenceTests: XCTestCase {
    func testSlopingBoundariesSplitTheOverlapAtTheirCrossings() throws {
        let first = span(owner: 0, bottom: SIMD2(0, 2), top: SIMD2(3, 5), height: 3)
        let second = span(owner: 1, bottom: SIMD2(3, 5), top: SIMD2(0, 2), height: 3)
        let cut = try XCTUnwrap(CADSectionInterference.triangulate(
            [first, second], tolerance: 1e-10, maximumVertices: 100
        ))

        // The crossing strips overlap in a diamond of area 2.
        XCTAssertEqual(area(cut.interfering), 2, accuracy: 1e-10)
        XCTAssertEqual(area(cut.normal), 8, accuracy: 1e-10)
    }

    func testOverlapOfThreeOwnersIsCoveredOnce() throws {
        let spans = (0..<3).map { owner in
            let interval = SIMD2(Double(owner), Double(owner + 4))
            return span(owner: owner, bottom: interval, top: interval, height: 2)
        }
        let cut = try XCTUnwrap(CADSectionInterference.triangulate(
            spans, tolerance: 1e-10, maximumVertices: 100
        ))

        XCTAssertEqual(area(cut.interfering), 8, accuracy: 1e-10)
        XCTAssertEqual(area(cut.normal), 4, accuracy: 1e-10)
    }

    private func span(owner: Int, bottom: SIMD2<Double>, top: SIMD2<Double>,
                      height: Double) -> CADSectionInterference.Trapezoid {
        .init(owner: owner, bottomLeft: SIMD2(bottom.x, 0), bottomRight: SIMD2(bottom.y, 0),
              topRight: SIMD2(top.y, height), topLeft: SIMD2(top.x, height))
    }

    private func area(_ points: [SIMD2<Double>]) -> Double {
        stride(from: 0, to: points.count, by: 3).reduce(0) { total, index in
            let a = points[index + 1] - points[index], b = points[index + 2] - points[index]
            return total + abs(a.x * b.y - a.y * b.x) / 2
        }
    }
}
