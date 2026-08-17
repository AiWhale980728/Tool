import Foundation
import Testing
@testable import RelayCore

@Suite("Completion Review outcome audit")
struct CompletionReviewOutcomeTests {
    @Test
    func newerTaskEventCreatesBoundedOutcome() throws {
        let decision = makeDecision()
        let session = makeSession(
            status: .running,
            eventID: UUID(uuidString: "90000000-0000-0000-0000-000000000002")!,
            occurredAt: SupervisorTestSupport.now.addingTimeInterval(10)
        )

        let outcomes = CompletionReviewOutcomeRecorder.reconcile(
            decisions: [decision],
            sessions: [session.key: session],
            existing: [],
            now: SupervisorTestSupport.now.addingTimeInterval(20)
        )
        let outcome = try #require(outcomes.first)

        #expect(outcome.kind == .workResumed)
        #expect(outcome.observedStatus == .running)
        #expect(outcome.decisionID == decision.id)
        #expect(outcome.assessmentID == decision.assessmentID)
        #expect(outcome.task == decision.task)
    }

    @Test
    func triggerEventAndOlderEventsDoNotBecomeOutcomes() {
        let decision = makeDecision()
        let same = makeSession(
            status: .readyToReview,
            eventID: decision.task.triggerEventID,
            occurredAt: decision.decidedAt
        )
        let older = makeSession(
            status: .failed,
            eventID: UUID(),
            occurredAt: decision.decidedAt.addingTimeInterval(-1)
        )

        #expect(CompletionReviewOutcomeRecorder.reconcile(
            decisions: [decision], sessions: [same.key: same], existing: []
        ).isEmpty)
        #expect(CompletionReviewOutcomeRecorder.reconcile(
            decisions: [decision], sessions: [older.key: older], existing: []
        ).isEmpty)
    }

    @Test
    func reconciliationIsIdempotentForDecisionAndEvent() {
        let decision = makeDecision()
        let session = makeSession(
            status: .failed,
            eventID: UUID(),
            occurredAt: SupervisorTestSupport.now.addingTimeInterval(10)
        )
        let first = CompletionReviewOutcomeRecorder.reconcile(
            decisions: [decision],
            sessions: [session.key: session],
            existing: [],
            now: SupervisorTestSupport.now.addingTimeInterval(20)
        )
        let second = CompletionReviewOutcomeRecorder.reconcile(
            decisions: [decision],
            sessions: [session.key: session],
            existing: first,
            now: SupervisorTestSupport.now.addingTimeInterval(30)
        )

        #expect(first.count == 1)
        #expect(second == first)
        #expect(second[0].kind == .failureObserved)
    }

    @Test
    func runtimeStoreRoundTripsOutcomesAndDecodesSchemaTwoWithoutThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-outcome-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let decision = makeDecision()
        let session = makeSession(
            status: .readyToReview,
            eventID: UUID(),
            occurredAt: SupervisorTestSupport.now.addingTimeInterval(10)
        )
        let outcomes = CompletionReviewOutcomeRecorder.reconcile(
            decisions: [decision],
            sessions: [session.key: session],
            existing: [],
            now: SupervisorTestSupport.now.addingTimeInterval(20)
        )
        let snapshot = CompletionReviewRuntimeSnapshot(
            decisions: [decision],
            outcomes: outcomes
        )

        try store.persist(snapshot)
        #expect(try store.load() == snapshot)

        let legacyObject: [String: Any] = [
            "schemaVersion": 2,
            "drafts": [:],
            "reviews": [:],
            "decisions": []
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        try legacyData.write(to: store.fileURL, options: [.atomic])
        let migrated = try store.load()
        #expect(migrated.schemaVersion == CompletionReviewRuntimeSnapshot.currentSchemaVersion)
        #expect(migrated.outcomes.isEmpty)
    }

    @Test
    func taskDeletionRemovesItsOutcomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-outcome-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionReviewRuntimeStore(root: root)
        let decision = makeDecision()
        let session = makeSession(
            status: .completed,
            eventID: UUID(),
            occurredAt: SupervisorTestSupport.now.addingTimeInterval(10)
        )
        let outcomes = CompletionReviewOutcomeRecorder.reconcile(
            decisions: [decision],
            sessions: [session.key: session],
            existing: [],
            now: SupervisorTestSupport.now.addingTimeInterval(20)
        )
        try store.persist(CompletionReviewRuntimeSnapshot(
            decisions: [decision],
            outcomes: outcomes
        ))

        try store.deleteTask(session.key)
        let loaded = try store.load()
        #expect(loaded.decisions.isEmpty)
        #expect(loaded.outcomes.isEmpty)
    }

    private func makeDecision() -> CompletionReviewHumanDecision {
        CompletionReviewHumanDecision(
            id: UUID(uuidString: "90000000-0000-0000-0000-000000000001")!,
            task: SupervisorTaskIdentity(
                source: .codex,
                taskID: "codex:outcome-session",
                sessionID: "outcome-session",
                triggerEventID: UUID(uuidString: "90000000-0000-0000-0000-000000000000")!
            ),
            assessmentID: UUID(uuidString: "90000000-0000-0000-0000-000000000003")!,
            kind: .continueWork,
            decidedAt: SupervisorTestSupport.now
        )
    }

    private func makeSession(
        status: RelayStatus,
        eventID: UUID,
        occurredAt: Date
    ) -> RelaySessionState {
        RelaySessionState(event: RelayEvent(
            id: eventID,
            source: .codex,
            sourceEvent: "Outcome",
            sessionID: "outcome-session",
            status: status,
            summary: "Bounded outcome",
            occurredAt: occurredAt,
            receivedAt: occurredAt
        ))
    }
}
