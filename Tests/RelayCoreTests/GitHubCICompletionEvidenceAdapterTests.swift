import Foundation
import Testing
@testable import RelayCore

@Suite("GitHub CI Completion Review evidence")
struct GitHubCICompletionEvidenceAdapterTests {
    @Test
    func decoderReducesCheckDetailsToBoundedCounts() throws {
        let commit = "abcdef0123456789abcdef0123456789abcdef01"
        let data = try JSONSerialization.data(withJSONObject: [
            "headRefOid": commit,
            "statusCheckRollup": [
                ["name": "private test name", "status": "COMPLETED", "conclusion": "SUCCESS"],
                ["name": "private build name", "status": "COMPLETED", "conclusion": "FAILURE"],
                ["name": "private pending name", "status": "IN_PROGRESS"]
            ]
        ])

        let snapshot = try GitHubCICompletionEvidenceAdapter.decodeSnapshot(
            data,
            now: SupervisorTestSupport.now
        )

        #expect(snapshot.headCommit == commit)
        #expect(snapshot.successfulCheckCount == 1)
        #expect(snapshot.failedCheckCount == 1)
        #expect(snapshot.pendingCheckCount == 1)
        let observation = snapshot.observation(expectedHeadCommit: commit)
        #expect(observation.kind == .ciChecksFailed)
        #expect(observation.integrity == .complete)
        #expect(!observation.summary.contains("private"))
    }

    @Test
    func checksAreCompleteOnlyForTheExactLocalCommit() {
        let commit = "0123456789abcdef0123456789abcdef01234567"
        let snapshot = GitHubCISnapshot(
            headCommit: commit,
            successfulCheckCount: 2,
            failedCheckCount: 0,
            pendingCheckCount: 0,
            observedAt: SupervisorTestSupport.now
        )
        let matching = snapshot.observation(expectedHeadCommit: commit)
        let conflicting = snapshot.observation(
            expectedHeadCommit: "ffffffffffffffffffffffffffffffffffffffff"
        )

        #expect(matching.kind == .ciChecksPassed)
        #expect(matching.integrity == .complete)
        #expect(matching.summary.contains("2 项成功"))
        #expect(conflicting.integrity == .conflicting)
        #expect(matching.reference == "github-checks:\(commit)")
    }
}
