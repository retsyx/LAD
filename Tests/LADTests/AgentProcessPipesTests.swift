import Foundation
import XCTest
@testable import LAD

/// Agent and catalog loops wait on events, so the shared pipe helper must
/// return for each wake source and otherwise sleep until the deadline.
final class AgentProcessPipesTests: XCTestCase {
    private func idleProcess(_ script: String) throws -> (Process, AgentProcessPipes) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipes = AgentProcessPipes(process)
        try process.run()
        pipes.configure()
        addTeardownBlock { pipes.shutdown { if process.isRunning { process.terminate() } } }
        return (process, pipes)
    }

    func testIdleWaitSleepsUntilItsDeadline() throws {
        let (_, pipes) = try idleProcess("exec sleep 30")
        let started = Date()
        var steps = 0
        while Date().timeIntervalSince(started) < 0.3 {
            _ = pipes.step(until: started.addingTimeInterval(0.3)) { _ in }
            steps += 1
        }
        XCTAssertLessThanOrEqual(steps, 3, "An idle wait must not return repeatedly before its deadline.")
    }

    func testWakeEndsAnIndefiniteWait() throws {
        let (_, pipes) = try idleProcess("exec sleep 30")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { pipes.wake() }
        let started = Date()
        _ = pipes.step(until: nil) { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testExitEndsAnIndefiniteWaitWhileAnotherProcessHoldsTheStreams() throws {
        // The background sleep keeps stdout and stderr open after the shell exits.
        let (_, pipes) = try idleProcess("sleep 5 & exit 0")
        let started = Date()
        while !pipes.hasExited, Date().timeIntervalSince(started) < 10 {
            _ = pipes.step(until: nil) { _ in }
        }
        XCTAssertTrue(pipes.hasExited)
        XCTAssertFalse(pipes.outputClosed)
    }

    func testClosedStreamsDoNotEndLaterWaits() throws {
        let (_, pipes) = try idleProcess("exec 1>&- 2>&-; exec sleep 30")
        let started = Date()
        while !pipes.outputClosed, Date().timeIntervalSince(started) < 10 {
            _ = pipes.step(until: started.addingTimeInterval(10)) { _ in }
        }
        XCTAssertTrue(pipes.outputClosed)
        _ = pipes.step(until: Date().addingTimeInterval(0.05)) { _ in }
        let waited = Date()
        _ = pipes.step(until: waited.addingTimeInterval(0.2)) { _ in }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(waited), 0.15, "A closed stream must leave the wait set.")
    }
}
