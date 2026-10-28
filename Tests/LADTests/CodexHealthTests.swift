import Darwin
import Foundation
import XCTest
@testable import LAD

final class CodexHealthTests: XCTestCase {
    @MainActor
    func testHealthyCheckUsesOnlyReadOnlyRPCsAndNeverRefreshesCredentials() async throws {
        let fake = try HealthFixture(account: account("chatgpt"), limits: limits(primary: 12, secondary: 24))
        defer { fake.remove() }
        let health = CodexHealth()
        await health.refresh(executable: fake.executable.path)
        XCTAssertNil(health.issue)
        XCTAssertFalse(health.isChecking)
        let requests = try fake.requests()
        XCTAssertEqual(requests.compactMap { $0["method"] as? String },
                       ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        let params = try XCTUnwrap(requests[2]["params"] as? [String: Any])
        XCTAssertEqual(params["refreshToken"] as? Bool, false)
        XCTAssertEqual(fake.invocations, 1)
        XCTAssertFalse(try fake.requestText.contains("thread/"))
        XCTAssertFalse(try fake.requestText.contains("turn/"))
        XCTAssertFalse(try fake.requestText.contains("exec"))
    }

    @MainActor
    func testMissingExecutableAndMissingRequiredAuthenticationAreDistinct() async throws {
        let health = CodexHealth()
        await health.refresh(executable: "/nonexistent/lad-health-codex")
        XCTAssertEqual(health.issue?.kind, .missingExecutable)
        let fake = try HealthFixture(account: account(nil))
        defer { fake.remove() }
        await health.refresh(executable: fake.executable.path)
        XCTAssertEqual(health.issue?.kind, .signInRequired)
        XCTAssertEqual(try fake.methods(), ["initialize", "initialized", "account/read"])
    }

    @MainActor
    func testAuthDisabledAPIKeyAndUnknownProviderDoNotRequireChatGPTQuota() async throws {
        for response in [account(nil, required: false), account("chatgpt", required: false),
                         account("apiKey"), account("bedrock"), account("futureProvider")] {
            let fake = try HealthFixture(account: response, limitError: -32601)
            defer { fake.remove() }
            let health = CodexHealth()
            await health.refresh(executable: fake.executable.path)
            XCTAssertNil(health.issue)
            XCTAssertEqual(try fake.methods(), ["initialize", "initialized", "account/read"])
        }
    }

    @MainActor
    func testOnlyApplicableExhaustedUsageWithNoAvailableCreditsRaisesIssue() async throws {
        let cases: [([String: Any], CodexHealthIssue.Kind?)] = [
            (limits(primary: 0, secondary: 0), nil),
            (limits(primary: 99, secondary: 90), nil),
            (limits(primary: 100, secondary: 0), .usageLimited),
            (limits(primary: 0, secondary: 100), .usageLimited),
            (limits(primary: 100, secondary: 100, hasCredits: true), nil),
            (limits(primary: 100, unlimited: true), nil),
            (limits(primary: 100, includeCredits: false), nil),
            (limits(primary: 0, reached: "rateLimit"), .usageLimited),
            (limits(primary: 0, spendingReached: true), .spendingLimited)
        ]
        for (response, expected) in cases {
            let fake = try HealthFixture(account: account("chatgpt"), limits: response)
            defer { fake.remove() }
            let health = CodexHealth()
            await health.refresh(executable: fake.executable.path)
            XCTAssertEqual(health.issue?.kind, expected)
        }
        var response = limits(primary: 0)
        response["rateLimitsByLimitId"] = ["unrelated-model": ["primary": ["usedPercent": 100],
            "credits": ["hasCredits": false, "unlimited": false], "rateLimitReachedType": "rateLimit"]]
        let fake = try HealthFixture(account: account("chatgpt"), limits: response)
        defer { fake.remove() }
        let health = CodexHealth()
        await health.refresh(executable: fake.executable.path)
        XCTAssertNil(health.issue, "An unrelated model's quota must not block the configured connection")
        let expired = try HealthFixture(account: account("chatgpt"), limits: ["rateLimits": [
            "primary": ["usedPercent": 100, "resetsAt": Date().timeIntervalSince1970 - 60],
            "credits": ["hasCredits": false, "unlimited": false]]])
        defer { expired.remove() }
        await health.refresh(executable: expired.executable.path)
        XCTAssertNil(health.issue, "An expired percentage observation is not an authoritative current limit")
    }

    @MainActor
    func testProtocolAndNetworkFailuresDoNotBecomeSignInInstructionsOrLeakServerText() async throws {
        let fixtures = [
            try HealthFixture(account: account("chatgpt"), limitError: -32601),
            try HealthFixture(account: account("chatgpt"), accountError: -32000),
            try HealthFixture(account: ["unexpected": "response"]),
            try HealthFixture(account: account("chatgpt"), limits: ["rateLimits": NSNull()]),
            try HealthFixture(account: account("chatgpt"), behavior: .malformed),
            try HealthFixture(account: account("chatgpt"), behavior: .exitEarly)
        ]
        defer { fixtures.forEach { $0.remove() } }
        for fake in fixtures {
            let health = CodexHealth()
            await health.refresh(executable: fake.executable.path)
            XCTAssertEqual(health.issue?.kind, .connectionUnavailable)
            XCTAssertFalse(health.isChecking)
            let rendered = [health.issue?.title, health.issue?.message, health.issue?.diagnostic].compactMap { $0 }.joined()
            XCTAssertFalse(rendered.contains("private@example.test"))
            XCTAssertFalse(rendered.contains("SECRET_TOKEN"))
            XCTAssertFalse(rendered.contains("Sign in"))
        }
    }

    @MainActor
    func testSuccessFailureCachingForceAndExecutableChangesAreScoped() async throws {
        let clock = HealthClock()
        let good = try HealthFixture(account: account("chatgpt"), limits: limits(primary: 0))
        let missingAuth = try HealthFixture(account: account(nil))
        defer { good.remove(); missingAuth.remove() }
        let health = CodexHealth(now: { clock.date })
        await health.refresh(executable: " \(good.executable.path)\n")
        await health.refresh(executable: good.executable.path)
        XCTAssertEqual(good.invocations, 1)
        clock.date.addTimeInterval(29)
        await health.refresh(executable: good.executable.path)
        XCTAssertEqual(good.invocations, 1)
        clock.date.addTimeInterval(2)
        await health.refresh(executable: good.executable.path)
        XCTAssertEqual(good.invocations, 2)
        await health.refresh(executable: good.executable.path, force: true)
        XCTAssertEqual(good.invocations, 3)
        await health.refresh(executable: missingAuth.executable.path)
        XCTAssertEqual(health.issue?.kind, .signInRequired)
        await health.refresh(executable: missingAuth.executable.path)
        XCTAssertEqual(missingAuth.invocations, 1)
        clock.date.addTimeInterval(6)
        await health.refresh(executable: missingAuth.executable.path)
        XCTAssertEqual(missingAuth.invocations, 2)
        await health.refresh(executable: good.executable.path)
        XCTAssertNil(health.issue)
        XCTAssertEqual(good.invocations, 4)
    }

    @MainActor
    func testConcurrentRefreshesShareTheProbeEvenWhenOneCallerCancels() async throws {
        let fake = try HealthFixture(account: account("chatgpt"), limits: limits(primary: 0), behavior: .delayed)
        defer { fake.remove() }
        let health = CodexHealth()
        let first = Task { await health.refresh(executable: fake.executable.path) }
        try await waitUntil { fake.invocations == 1 }
        let second = Task { await health.refresh(executable: fake.executable.path, force: true) }
        await Task.yield()
        first.cancel()
        await second.value
        await first.value
        XCTAssertNil(health.issue)
        XCTAssertFalse(health.isChecking)
        XCTAssertEqual(fake.invocations, 1)
        XCTAssertEqual(try fake.methods(), ["initialize", "initialized", "account/read", "account/rateLimits/read"])
    }

    @MainActor
    func testCancellationKillsAnUncooperativeProcessAndAllowsAnotherCheck() async throws {
        let fake = try HealthFixture(account: account(nil), behavior: .ignoreTermination)
        defer { fake.remove() }
        let health = CodexHealth()
        let task = Task { await health.refresh(executable: fake.executable.path) }
        try await waitUntil { (try? fake.methods().count) == 1 }
        let pid = try XCTUnwrap(fake.pid)
        let start = Date()
        task.cancel()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(health.isChecking)
        XCTAssertNil(health.issue, "Cancellation must not be cached as an authentication failure")
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        let good = try HealthFixture(account: account("chatgpt"), limits: limits(primary: 0))
        defer { good.remove() }
        await health.refresh(executable: good.executable.path)
        XCTAssertNil(health.issue)
        XCTAssertEqual(good.invocations, 1)
    }

    @MainActor
    func testTimeoutIsBoundedAndNeverRequestsSignIn() async throws {
        let fake = try HealthFixture(account: account(nil), behavior: .ignoreTermination)
        defer { fake.remove() }
        let health = CodexHealth(timeout: 0.15)
        let start = Date()
        await health.refresh(executable: fake.executable.path)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(health.issue?.kind, .connectionUnavailable)
        XCTAssertEqual(health.issue?.diagnostic, "The Codex status check timed out.")
        XCTAssertFalse(health.isChecking)
        if let pid = fake.pid { XCTAssertEqual(Darwin.kill(pid, 0), -1) }
    }

    @MainActor
    func testSupersededExecutableCannotPublishAStaleResult() async throws {
        let old = try HealthFixture(account: account(nil), behavior: .delayed)
        let current = try HealthFixture(account: account("apiKey"))
        defer { old.remove(); current.remove() }
        let health = CodexHealth()
        let first = Task { await health.refresh(executable: old.executable.path) }
        try await waitUntil { old.invocations == 1 }
        await health.refresh(executable: current.executable.path)
        await first.value
        XCTAssertNil(health.issue)
        XCTAssertFalse(health.isChecking)
        await health.refresh(executable: current.executable.path)
        XCTAssertEqual(current.invocations, 1)
    }

    @MainActor
    func testInstalledCodexHealthWithoutStartingAnAgent() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LAD_TEST_CODEX_HEALTH"] == "1" else {
            throw XCTSkip("Set LAD_TEST_CODEX_HEALTH=1 for the installed Codex read-only connection check.")
        }
        let executable = environment["LAD_TEST_CODEX_PATH"] ?? CodexService.configuredExecutable
        guard !executable.isEmpty else { throw XCTSkip("Install Codex before running its connection check.") }
        let capture = HealthRequestCapture()
        let health = CodexHealth(onRequest: { capture.append($0) })
        await health.refresh(executable: executable)
        XCTAssertFalse(health.isChecking)
        XCTAssertNil(health.issue, health.issue?.title ?? "")
        XCTAssertTrue(capture.methods == ["initialize", "initialized", "account/read"] ||
                      capture.methods == ["initialize", "initialized", "account/read", "account/rateLimits/read"])
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() {
            if Date() >= deadline { throw HealthTestError.waitTimedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func account(_ type: String?, required: Bool = true) -> [String: Any] {
        var result: [String: Any] = ["account": NSNull(), "requiresOpenaiAuth": required]
        if let type { result["account"] = ["type": type, "email": "private@example.test"] }
        return result
    }

    private func limits(primary: Double, secondary: Double? = nil, hasCredits: Bool = false,
                        unlimited: Bool = false, includeCredits: Bool = true,
                        reached: String? = nil, spendingReached: Bool = false) -> [String: Any] {
        var limit: [String: Any] = ["primary": ["usedPercent": primary], "secondary": NSNull(),
                                  "credits": NSNull(), "rateLimitReachedType": NSNull(),
                                  "spendControlReached": spendingReached]
        if let secondary { limit["secondary"] = ["usedPercent": secondary] }
        if includeCredits { limit["credits"] = ["hasCredits": hasCredits, "unlimited": unlimited, "balance": "SECRET_TOKEN"] }
        if let reached { limit["rateLimitReachedType"] = reached }
        return ["rateLimits": limit]
    }
}

private enum HealthTestError: Error { case waitTimedOut }

private final class HealthRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func append(_ method: String) { lock.lock(); recorded.append(method); lock.unlock() }
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}

@MainActor
private final class HealthClock {
    var date = Date(timeIntervalSince1970: 1_000)
}

private struct HealthFixture {
    enum Behavior: Equatable { case normal, delayed, ignoreTermination, malformed, exitEarly }
    let directory: URL
    let executable: URL
    private let requestFile: URL
    private let invocationFile: URL
    private let pidFile: URL

    init(account: [String: Any], limits: [String: Any] = [:], accountError: Int? = nil,
         limitError: Int? = nil, behavior: Behavior = .normal) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LAD-health-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("codex")
        requestFile = directory.appendingPathComponent("requests.jsonl")
        invocationFile = directory.appendingPathComponent("invocations.txt")
        pidFile = directory.appendingPathComponent("pid.txt")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func response(_ id: Int, result: [String: Any], error: Int? = nil) throws -> String {
            let body: [String: Any]
            if let error {
                body = ["id": id, "error": ["code": error, "message": "private@example.test SECRET_TOKEN"]]
            } else { body = ["id": id, "result": result] }
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            return "printf '%s\\n' " + quote(String(decoding: data, as: UTF8.self)) + "\n"
        }
        let read = "IFS= read -r request || exit 0\nprintf '%s\\n' \"$request\" >> \(quote(requestFile.path))\n"
        var script = "#!/bin/sh\nprintf '1\\n' >> \(quote(invocationFile.path))\nprintf '%s\\n' \"$$\" > \(quote(pidFile.path))\n"
        switch behavior {
        case .exitEarly:
            script += "exit 1\n"
        case .ignoreTermination:
            script += "trap '' TERM\n" + read + "while :; do :; done\n"
        case .malformed:
            script += read + "printf '%s\\n' 'this is not json'\nwhile IFS= read -r request; do :; done\n"
        case .normal, .delayed:
            script += read
            if behavior == .delayed { script += "/bin/sleep 0.25\n" }
            script += try response(1, result: [:])
            script += read + read // initialized, account/read
            script += try response(2, result: account, error: accountError)
            script += read
            script += try response(3, result: limits, error: limitError)
            script += "while IFS= read -r request; do :; done\n"
        }
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var invocations: Int { ((try? String(contentsOf: invocationFile, encoding: .utf8)) ?? "").split(separator: "\n").count }
    var pid: pid_t? { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    var requestText: String { get throws { try String(contentsOf: requestFile, encoding: .utf8) } }
    func requests() throws -> [[String: Any]] {
        try requestText.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    func methods() throws -> [String] { try requests().compactMap { $0["method"] as? String } }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
