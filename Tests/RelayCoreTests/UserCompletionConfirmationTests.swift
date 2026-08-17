import Foundation
import Testing
@testable import RelayCore

@Suite("User completion confirmation", .serialized)
struct UserCompletionConfirmationTests {
    @Test
    func testReviewedResultCanBeConfirmedWithBoundedLocalEvidence() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reviewedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1_000) / 1_000
        )
        let confirmedAt = reviewedAt.addingTimeInterval(1)
        let review = reviewEvent(at: reviewedAt)
        let processor = RelayProcessor(root: root)
        var snapshot = RelaySnapshot()
        snapshot.apply(review)
        try processor.stateStore.persist(snapshot)

        let confirmation = UserCompletionConfirmation(root: root)
        try confirmation.enqueue(
            sessionKey: review.sessionKey,
            expectedLastEventID: review.id,
            confirmedAt: confirmedAt
        )

        let pending = try confirmation.spool.pendingFiles()
        let file = try #require(pending.first)
        let event = try confirmation.spool.readEvent(at: file)
        let evidence = try #require(event.completionEvidence?.items.first)
        #expect(pending.count == 1)
        #expect(event.sourceEvent == UserCompletionConfirmation.sourceEvent)
        #expect(event.status == .completed)
        #expect(event.summary == UserCompletionConfirmation.summary)
        #expect(evidence.kind == .userConfirmed)
        #expect(evidence.summary == UserCompletionConfirmation.evidenceSummary)
        #expect(evidence.sourceID == review.id.uuidString.lowercased())

        let report = try processor.processPending()
        let completed = try #require(processor.stateStore.load().sessions[review.sessionKey])
        #expect(report.applied == 1)
        #expect(completed.status == .completed)
        #expect(completed.terminalAt == confirmedAt)
        #expect(!WorkbenchTask(session: completed, cleanup: .notScheduled).canConfirmCompletion)
    }

    @Test
    func testOnlyCurrentReviewedResultCanShowAndUseConfirmation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = reviewEvent(at: Date(timeIntervalSince1970: 100))
        let processor = RelayProcessor(root: root)
        var snapshot = RelaySnapshot()
        snapshot.apply(review)
        try processor.stateStore.persist(snapshot)
        let session = try #require(snapshot.sessions[review.sessionKey])

        #expect(WorkbenchTask(session: session, cleanup: .notScheduled).canConfirmCompletion)
        #expect(throws: RelayError.invalidConfirmation("the Agent has newer activity; review the latest result")) {
            try UserCompletionConfirmation(root: root).enqueue(
                sessionKey: review.sessionKey,
                expectedLastEventID: UUID()
            )
        }
        #expect(try processor.spool.pendingFiles().isEmpty)

        let running = RelayEvent(
            source: .codex,
            sourceEvent: "UserPromptSubmit",
            sessionID: review.sessionID,
            status: .running,
            summary: "Codex is running",
            occurredAt: Date(timeIntervalSince1970: 101),
            receivedAt: Date(timeIntervalSince1970: 101)
        )
        try processor.spool.enqueue(running)
        try UserCompletionConfirmation(root: root).enqueue(
            sessionKey: review.sessionKey,
            expectedLastEventID: review.id,
            confirmedAt: Date(timeIntervalSince1970: 102)
        )

        let report = try processor.processPending()
        let current = try #require(processor.stateStore.load().sessions[review.sessionKey])
        #expect(report.applied == 1)
        #expect(report.stale == 1)
        #expect(current.status == .running)
        #expect(current.lastEventID == running.id)
        #expect(!WorkbenchTask(session: current, cleanup: .notScheduled).canConfirmCompletion)
    }

    @Test
    func testRunningOrMissingTaskCannotBeConfirmed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = RelayProcessor(root: root)
        let running = RelayEvent(
            source: .claude,
            sourceEvent: "UserPromptSubmit",
            sessionID: "running",
            status: .running,
            summary: "Claude is running",
            occurredAt: Date(timeIntervalSince1970: 100),
            receivedAt: Date(timeIntervalSince1970: 100)
        )
        var snapshot = RelaySnapshot()
        snapshot.apply(running)
        try processor.stateStore.persist(snapshot)
        let confirmation = UserCompletionConfirmation(root: root)

        #expect(throws: RelayError.invalidConfirmation("only a result ready for review can be confirmed")) {
            try confirmation.enqueue(
                sessionKey: running.sessionKey,
                expectedLastEventID: running.id
            )
        }
        #expect(throws: RelayError.invalidConfirmation("task is no longer available")) {
            try confirmation.enqueue(
                sessionKey: "claude:missing",
                expectedLastEventID: UUID()
            )
        }
        #expect(try processor.spool.pendingFiles().isEmpty)
    }

    @Test
    func testUserConfirmationWithoutExactReviewEventIDCannotComplete() throws {
        let review = reviewEvent(at: Date(timeIntervalSince1970: 100))
        let invalidEvidence = try #require(CompletionEvidenceBundle([
            CompletionEvidence(
                kind: .userConfirmed,
                summary: "User reviewed the result"
            )
        ]))
        let invalid = RelayEvent(
            source: review.source,
            sourceEvent: UserCompletionConfirmation.sourceEvent,
            sessionID: review.sessionID,
            status: .completed,
            summary: UserCompletionConfirmation.summary,
            completionEvidence: invalidEvidence,
            occurredAt: Date(timeIntervalSince1970: 101),
            receivedAt: Date(timeIntervalSince1970: 101)
        )
        var snapshot = RelaySnapshot()
        snapshot.apply(review)

        #expect(invalid.effectiveStatus == .readyToReview)
        #expect(snapshot.apply(invalid) == .stale)
        #expect(snapshot.sessions[review.sessionKey]?.status == .readyToReview)
        #expect(snapshot.sessions[review.sessionKey]?.lastEventID == review.id)
    }

    private func reviewEvent(at date: Date) -> RelayEvent {
        RelayEvent(
            source: .codex,
            sourceEvent: "Stop",
            sessionID: "reviewed-task",
            status: .readyToReview,
            summary: "Codex result is ready to review",
            occurredAt: date,
            receivedAt: date
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-confirmation-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
