import Darwin
import Foundation
import Testing
@testable import RelayCore

@Suite("Codex quota probe", .serialized)
struct AgentQuotaTests {
    @Test
    func testNormalFixtureMapsOnlyPrimaryCodexQuotaAndCredits() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try CodexQuotaProbe.decodeRateLimitsResult(
            fixture("codex-quota-normal"),
            now: now
        )

        #expect(snapshot.source == .codex)
        #expect(snapshot.availability == .available)
        #expect(snapshot.plan == "plus")
        #expect(snapshot.creditsRemaining == 12.5)
        #expect(snapshot.windows.map(\.displayName) == ["Codex 5h", "Codex weekly"])
        #expect(snapshot.windows.map(\.remainingPercent) == [72, 37])
        #expect(snapshot.providerBalances.count == 3)
        #expect(!snapshot.windows.contains { $0.displayName == "Codex Spark" })
    }

    @Test
    func testCreditsOnlyFixtureStillReturnsUsefulSnapshot() throws {
        let snapshot = try CodexQuotaProbe.decodeRateLimitsResult(fixture("codex-quota-credits-only"))

        #expect(snapshot.plan == "team")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.creditsRemaining == 4)
        #expect(snapshot.providerBalances.first?.kind == .apiCredit)
    }

    @Test
    func testPlanOnlyFixtureDoesNotInventQuota() throws {
        let snapshot = try CodexQuotaProbe.decodeRateLimitsResult(fixture("codex-quota-plan-only"))

        #expect(snapshot.plan == "pro")
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.providerBalances.isEmpty)
    }

    @Test
    func testNoCreditsFlagDoesNotInventZeroCreditBalance() throws {
        let data = Data(
            #"{"rateLimits":{"primary":{"usedPercent":82,"windowDurationMins":10080},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"pro"}}"#.utf8
        )

        let snapshot = try CodexQuotaProbe.decodeRateLimitsResult(data)

        #expect(snapshot.windows.map(\.displayName) == ["Codex weekly"])
        #expect(snapshot.creditsRemaining == nil)
        #expect(snapshot.providerBalances.count == 1)
    }

    @Test
    func testTokenUsageMapsOnlyBoundedSummaryAndLatestDay() throws {
        let data = Data(
            #"{"summary":{"lifetimeTokens":9791933610},"dailyUsageBuckets":[{"startDate":"2026-08-15","tokens":500628401},{"startDate":"2026-08-16","tokens":365596543}]}"#.utf8
        )

        let usage = try CodexQuotaProbe.decodeTokenUsageResult(data)

        #expect(usage.lifetimeTokens == 9_791_933_610)
        #expect(usage.latestDailyTokens == 365_596_543)
        #expect(usage.latestDailyStartDate == "2026-08-16")
    }

    @Test
    func testMalformedFixtureIsRejected() {
        #expect(throws: CodexQuotaProbeError.malformedResponse) {
            try CodexQuotaProbe.decodeRateLimitsResult(fixture("codex-quota-malformed"))
        }
    }

    @Test
    func testMissingQuotaIsReportedWithoutGuessing() {
        let data = Data(#"{"rateLimits":{}}"#.utf8)
        #expect(throws: CodexQuotaProbeError.quotaUnavailable) {
            try CodexQuotaProbe.decodeRateLimitsResult(data)
        }
    }

    @Test
    func testProbeTimesOutAndTerminatesChild() async throws {
        let script = try executableScript("""
        #!/bin/sh
        sleep 5
        """)
        let probe = CodexQuotaProbe(configuration: .init(
            executableURL: script,
            totalTimeout: 0.15,
            arguments: []
        ))

        await #expect(throws: CodexQuotaProbeError.timedOut) {
            try await probe.fetch()
        }
    }

    @Test
    func testProbeRejectsOversizedOutput() async throws {
        let oversized = String(repeating: "x", count: 2_048)
        let script = try executableScript("""
        #!/bin/sh
        read request
        printf '%s\\n' '\(oversized)'
        sleep 10
        """)
        let probe = CodexQuotaProbe(configuration: .init(
            executableURL: script,
            totalTimeout: 8,
            maximumOutputBytes: 1_024,
            arguments: []
        ))

        await #expect(throws: CodexQuotaProbeError.outputLimitExceeded) {
            try await probe.fetch()
        }
    }

    @Test
    func testAbnormalChildExitIsReported() async throws {
        let script = try executableScript("""
        #!/bin/sh
        exit 2
        """)
        let probe = CodexQuotaProbe(configuration: .init(
            executableURL: script,
            totalTimeout: 3,
            arguments: []
        ))

        await #expect(throws: CodexQuotaProbeError.processFailed) {
            try await probe.fetch()
        }
    }

    @Test
    func testChatGPTAuthenticationErrorIsReportedAsSignInRequired() async throws {
        let script = try executableScript("""
        #!/bin/sh
        read initialize
        printf '%s\\n' '{"id":1,"result":{"userAgent":"fixture"}}'
        read initialized
        read request
        printf '%s\\n' '{"id":2,"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"}}'
        sleep 1
        """)
        let probe = CodexQuotaProbe(configuration: .init(
            executableURL: script,
            totalTimeout: 3,
            arguments: []
        ))

        await #expect(throws: CodexQuotaProbeError.signInRequired) {
            try await probe.fetch()
        }
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    private func executableScript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-quota-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-codex")
        try Data(contents.utf8).write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            throw CodexQuotaProbeError.processFailed
        }
        return url
    }
}
