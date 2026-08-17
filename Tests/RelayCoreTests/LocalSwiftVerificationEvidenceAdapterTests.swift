import Foundation
import Testing
@testable import RelayCore

@Suite("Local Swift verification evidence")
struct LocalSwiftVerificationEvidenceAdapterTests {
    @Test
    func successfulSwiftTestingSummaryBecomesBoundEvidence() throws {
        let output = Data("Test run with 12 tests in 3 suites passed after 1.2 seconds.".utf8)
        let counts = try #require(
            LocalSwiftVerificationEvidenceAdapter.parseSuccessfulTestRun(output)
        )
        let snapshot = LocalSwiftVerificationSnapshot(
            testCount: counts.tests,
            suiteCount: counts.suites,
            headCommit: String(repeating: "a", count: 40),
            integrity: .complete,
            observedAt: SupervisorTestSupport.now
        )

        #expect(counts.tests == 12)
        #expect(counts.suites == 3)
        #expect(snapshot.observations.count == 2)
        #expect(snapshot.observations.allSatisfy { $0.integrity == .complete })
        #expect(snapshot.observations.map(\.kind) == [.testPassed, .buildSucceeded])
        #expect(snapshot.observations.allSatisfy { $0.source.kind == .tool })
        #expect(snapshot.observations.allSatisfy { $0.summary.contains("aaaaaaaaaaaa") })
    }

    @Test
    func xctestSummaryIsAcceptedWithoutInventingSuiteCount() throws {
        let output = Data("Executed 7 tests, with 0 failures (0 unexpected) in 0.4 seconds".utf8)
        let counts = try #require(
            LocalSwiftVerificationEvidenceAdapter.parseSuccessfulTestRun(output)
        )

        #expect(counts.tests == 7)
        #expect(counts.suites == nil)
    }

    @Test(arguments: [
        "Test run with 0 tests in 0 suites passed after 0.1 seconds.",
        "Test run with 4 tests in 1 suite failed after 0.1 seconds.",
        "Executed 4 tests, with 1 failure in 0.1 seconds",
        "unstructured output"
    ])
    func failedEmptyOrUnknownOutputCannotBecomeEvidence(output: String) {
        let parsed = LocalSwiftVerificationEvidenceAdapter.parseSuccessfulTestRun(Data(output.utf8))
        if output.contains("0 tests") {
            #expect(parsed?.tests == 0)
        } else {
            #expect(parsed == nil)
        }
    }

    @Test
    func unboundWorkspaceEvidenceRemainsPartialAndPathFree() {
        let snapshot = LocalSwiftVerificationSnapshot(
            testCount: 5,
            suiteCount: 1,
            headCommit: nil,
            integrity: .partial,
            observedAt: SupervisorTestSupport.now
        )
        let encoded = snapshot.observations.map(\.summary).joined(separator: " ")

        #expect(snapshot.observations.allSatisfy { $0.integrity == .partial })
        #expect(snapshot.observations.allSatisfy { $0.reference == nil })
        #expect(!encoded.contains("/Users/"))
        #expect(encoded.contains("未干净绑定"))
    }

    @Test
    func adapterBoundsExecutionConfiguration() {
        let adapter = LocalSwiftVerificationEvidenceAdapter(
            timeout: 10_000,
            maximumOutputBytes: 10_000_000
        )

        #expect(adapter.executableURL.path == "/usr/bin/xcrun")
        #expect(adapter.timeout == 180)
        #expect(adapter.maximumOutputBytes == 512 * 1_024)
    }
}
