import Foundation
import Testing
@testable import RelayCore

@Suite("Git Completion Review evidence")
struct GitCompletionEvidenceAdapterTests {
    @Test
    func statusParserCountsChangesWithoutRetainingPaths() throws {
        let status = Data(" M Sources/Secret.swift\0?? .env\0UU Conflict.txt\0".utf8)

        let counts = try GitCompletionEvidenceAdapter.parseStatus(status)

        #expect(counts.tracked == 2)
        #expect(counts.untracked == 1)
        #expect(counts.conflicts == 1)
    }

    @Test
    func snapshotProducesOnlyBoundedGitMetadataForTheReview() throws {
        let commit = "0123456789abcdef0123456789abcdef01234567"
        let observation = GitEvidenceSnapshot(
            headCommit: commit,
            trackedChangeCount: 2,
            untrackedEntryCount: 1,
            conflictCount: 1,
            observedAt: SupervisorTestSupport.now
        ).observation
        let event = RelayEvent(
            source: .codex,
            sourceEvent: "TurnComplete",
            sessionID: "git-evidence-session",
            status: .readyToReview,
            summary: "Result ready for review.",
            occurredAt: SupervisorTestSupport.now,
            receivedAt: SupervisorTestSupport.now
        )
        let session = RelaySessionState(event: event)

        #expect(observation.kind == .gitState)
        #expect(observation.source == EvidenceSource(kind: .tool, sourceID: "git-local-readonly-v1"))
        #expect(observation.integrity == .partial)
        #expect(observation.dataLevel == .l1StructuredEvidence)
        #expect(observation.summary.contains("2 个已跟踪改动"))
        #expect(observation.summary.contains("1 个未跟踪条目"))
        #expect(observation.summary.contains("1 个冲突"))
        #expect(!observation.summary.contains("Secret.swift"))
        #expect(!observation.summary.contains(".env"))
        #expect(!observation.summary.contains("Conflict.txt"))

        let provider = SupervisorModelDescriptor(
            providerID: "openai",
            modelID: "test-model",
            modelVersion: "api",
            executionLocation: .remote
        )
        let input = try CompletionReviewInputBuilder.build(
            session: session,
            draft: CompletionReviewDraft(
                goal: "Complete the task safely.",
                acceptanceCriteria: ["The result is delivered"],
                updatedAt: SupervisorTestSupport.now
            ),
            provider: provider,
            consentConfirmedAt: SupervisorTestSupport.now,
            additionalEvidence: [observation],
            now: SupervisorTestSupport.now
        )
        let request = try OpenAICompletionReviewProvider.makeRequestBody(
            input: input,
            modelID: provider.modelID,
            systemPrompt: SupervisorTestSupport.syntheticSystemPrompt
        )
        let requestText = String(decoding: request, as: UTF8.self)

        #expect(input.evidence.first?.reference == "git:\(commit)")
        #expect(requestText.contains("Git 独立观察到提交"))
        #expect(!requestText.contains("git:\(commit)"))
    }
}
