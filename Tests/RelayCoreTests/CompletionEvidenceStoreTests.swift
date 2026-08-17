import Foundation
import Testing
@testable import RelayCore

@Suite("Completion Evidence store")
struct CompletionEvidenceStoreTests {
    @Test
    func storeKeepsStableEvidenceIdentityAndScopesRecordsToTheTriggerEvent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-evidence-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionEvidenceStore(root: root)
        let originalSession = reviewSession(
            eventID: UUID(uuidString: "61000000-0000-0000-0000-000000000001")!
        )
        let originalID = UUID(uuidString: "62000000-0000-0000-0000-000000000001")!
        let original = observation(
            id: originalID,
            summary: "Git 独立观察到提交 0123456789ab，工作区干净。"
        )

        let first = try store.record(
            [original],
            for: originalSession,
            now: SupervisorTestSupport.now
        )
        let updated = observation(
            id: UUID(),
            summary: "Git 独立观察到提交 0123456789ab；工作区有 1 个已跟踪改动。"
        )
        let second = try store.record(
            [updated],
            for: originalSession,
            now: SupervisorTestSupport.now.addingTimeInterval(1)
        )

        #expect(first.map(\.id) == [originalID])
        #expect(second.map(\.id) == [originalID])
        #expect(second.first?.summary.contains("1 个已跟踪改动") == true)

        let newerSession = reviewSession(
            eventID: UUID(uuidString: "61000000-0000-0000-0000-000000000002")!
        )
        let newer = try store.record(
            [original],
            for: newerSession,
            now: SupervisorTestSupport.now.addingTimeInterval(2)
        )

        #expect(newer.count == 1)
        #expect(newer.first?.id == originalID)
        #expect(try store.load().records.count == 2)

        try store.deleteTask(originalSession.key)
        #expect(try store.load().records.isEmpty)
    }

    @Test
    func expiredEvidenceIsRemovedBeforeItCanBeReused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-evidence-expiry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompletionEvidenceStore(root: root)
        let session = reviewSession(eventID: UUID())
        _ = try store.record(
            [observation(id: UUID(), summary: "A bounded local observation.")],
            for: session,
            now: SupervisorTestSupport.now,
            lifetime: 10
        )

        let current = try store.record(
            [],
            for: session,
            now: SupervisorTestSupport.now.addingTimeInterval(11)
        )

        #expect(current.isEmpty)
        #expect(try store.load().records.isEmpty)
    }

    private func reviewSession(eventID: UUID) -> RelaySessionState {
        RelaySessionState(event: RelayEvent(
            id: eventID,
            source: .codex,
            sourceEvent: "TurnComplete",
            sessionID: "evidence-store-session",
            status: .readyToReview,
            summary: "Result ready for review.",
            occurredAt: SupervisorTestSupport.now,
            receivedAt: SupervisorTestSupport.now
        ))
    }

    private func observation(id: UUID, summary: String) -> CompletionReviewEvidenceObservation {
        CompletionReviewEvidenceObservation(
            id: id,
            kind: .gitState,
            source: EvidenceSource(kind: .tool, sourceID: "git-local-readonly-v1"),
            summary: summary,
            reference: "git:0123456789abcdef0123456789abcdef01234567",
            observedAt: SupervisorTestSupport.now,
            dataLevel: .l1StructuredEvidence,
            integrity: .partial
        )
    }
}
