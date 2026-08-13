import Foundation
import Testing
@testable import RelayCore

@Suite("Relay state reducer")
struct RelayStateTests {
    @Test
    func testStateProgressesThroughCoreLifecycle() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = RelaySnapshot()

        #expect(snapshot.apply(event(status: .running, at: base)) == .applied)
        #expect(snapshot.apply(event(status: .needsPermission, at: base.addingTimeInterval(1))) == .applied)
        #expect(snapshot.sessions["codex:session-1"]?.waitingSince == base.addingTimeInterval(1))

        #expect(snapshot.apply(event(status: .needsInput, at: base.addingTimeInterval(2))) == .applied)
        #expect(
            snapshot.sessions["codex:session-1"]?.waitingSince == base.addingTimeInterval(1),
            "Consecutive attention states must preserve the original waiting time"
        )

        #expect(snapshot.apply(event(status: .running, at: base.addingTimeInterval(3))) == .applied)
        #expect(snapshot.sessions["codex:session-1"]?.waitingSince == nil)

        #expect(snapshot.apply(event(status: .completed, at: base.addingTimeInterval(4))) == .applied)
        #expect(snapshot.sessions["codex:session-1"]?.status == .readyToReview)
        #expect(snapshot.sessions["codex:session-1"]?.eventCount == 5)
        #expect(snapshot.attentionRequiredCount == 0)
        #expect(snapshot.readyToReviewCount == 1)
        #expect(snapshot.completedCount == 0)
    }

    @Test
    func testStaleEventDoesNotRegressSession() throws {
        let newer = Date(timeIntervalSince1970: 200)
        let older = Date(timeIntervalSince1970: 100)
        var snapshot = RelaySnapshot()

        #expect(snapshot.apply(event(status: .completed, at: newer)) == .applied)
        #expect(snapshot.apply(event(status: .running, at: older)) == .stale)
        #expect(snapshot.sessions["codex:session-1"]?.status == .readyToReview)
        #expect(snapshot.sessions["codex:session-1"]?.eventCount == 1)
    }

    @Test
    func testDuplicateEventIDIsIgnored() throws {
        let id = UUID()
        let original = event(id: id, status: .running, at: Date(timeIntervalSince1970: 100))
        var snapshot = RelaySnapshot()

        #expect(snapshot.apply(original) == .applied)
        #expect(snapshot.apply(original) == .duplicateID)
        #expect(snapshot.sessions["codex:session-1"]?.eventCount == 1)
    }

    @Test
    func testSameFingerprintWithinWindowIsIgnored() throws {
        let first = event(status: .running, at: Date(timeIntervalSince1970: 100))
        let second = event(status: .running, at: Date(timeIntervalSince1970: 101))
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.id != second.id)

        var snapshot = RelaySnapshot()
        #expect(snapshot.apply(first) == .applied)
        #expect(snapshot.apply(second) == .duplicateFingerprint)
        #expect(snapshot.sessions["codex:session-1"]?.eventCount == 1)
    }

    @Test
    func testSameFingerprintOutsideWindowIsApplied() throws {
        let first = event(status: .running, at: Date(timeIntervalSince1970: 100))
        let second = event(status: .running, at: Date(timeIntervalSince1970: 103))
        var snapshot = RelaySnapshot()

        #expect(snapshot.apply(first) == .applied)
        #expect(snapshot.apply(second) == .applied)
        #expect(snapshot.sessions["codex:session-1"]?.eventCount == 2)
    }

    @Test
    func testProjectMetadataIsMergedInsteadOfErased() throws {
        let first = event(
            status: .running,
            at: Date(timeIntervalSince1970: 100),
            project: ProjectContext(cwd: "/tmp/project", name: "project", branch: "main")
        )
        let second = event(
            status: .completed,
            at: Date(timeIntervalSince1970: 110),
            project: ProjectContext(repository: "owner/repo")
        )
        var snapshot = RelaySnapshot()

        snapshot.apply(first)
        snapshot.apply(second)

        let project = try #require(snapshot.sessions["codex:session-1"]?.project)
        #expect(project.cwd == "/tmp/project")
        #expect(project.name == "project")
        #expect(project.repository == "owner/repo")
        #expect(project.branch == "main")
    }

    @Test
    func testCompletionClaimWithoutEvidenceBecomesReadyToReview() {
        let date = Date(timeIntervalSince1970: 100)
        var snapshot = RelaySnapshot()

        snapshot.apply(event(status: .completed, at: date))

        #expect(snapshot.sessions["codex:session-1"]?.status == .readyToReview)
        #expect(snapshot.sessions["codex:session-1"]?.terminalAt == nil)
        #expect(snapshot.readyToReviewCount == 1)
        #expect(snapshot.completedCount == 0)
    }

    @Test
    func testEvidenceBackedCompletionIsRetainedAndPrunedAfterTwentyFourHours() throws {
        let completedAt = Date(timeIntervalSince1970: 100)
        let evidence = try #require(CompletionEvidenceBundle([
            CompletionEvidence(kind: .testPassed, summary: "Verified tests passed")
        ]))
        let completed = RelayEvent(
            source: .codex,
            sourceEvent: "verified",
            sessionID: "verified-session",
            status: .completed,
            summary: "Verified completion",
            completionEvidence: evidence,
            occurredAt: completedAt,
            receivedAt: completedAt
        )
        var snapshot = RelaySnapshot()
        snapshot.apply(completed)

        #expect(snapshot.sessions["codex:verified-session"]?.status == .completed)
        #expect(snapshot.sessions["codex:verified-session"]?.terminalAt == completedAt)
        #expect(
            snapshot.cleanupState(
                for: "codex:verified-session",
                now: completedAt.addingTimeInterval(22 * 60 * 60)
            ) == .scheduled(removalAt: completedAt.addingTimeInterval(24 * 60 * 60))
        )
        #expect(
            snapshot.cleanupState(
                for: "codex:verified-session",
                now: completedAt.addingTimeInterval(23.5 * 60 * 60)
            ) == .approaching(removalAt: completedAt.addingTimeInterval(24 * 60 * 60))
        )
        #expect(snapshot.pruneExpired(now: completedAt.addingTimeInterval(24 * 60 * 60)).count == 1)
        #expect(snapshot.sessions["codex:verified-session"] == nil)
    }

    @Test
    func testActiveAndReviewSessionsAreNeverAgePruned() {
        let old = Date(timeIntervalSince1970: 100)
        let now = old.addingTimeInterval(10 * 24 * 60 * 60)
        var snapshot = RelaySnapshot()
        snapshot.apply(event(status: .running, at: old))
        snapshot.apply(RelayEvent(
            source: .claude,
            sourceEvent: "stop",
            sessionID: "review",
            status: .readyToReview,
            summary: "Review",
            occurredAt: old,
            receivedAt: old
        ))

        #expect(snapshot.pruneExpired(now: now).isEmpty)
        #expect(snapshot.sessions.count == 2)
    }

    @Test
    func testProgressPersistsAcrossRunningEventsWithoutTrustedProgress() throws {
        let first = RelayEvent(
            source: .codex,
            sourceEvent: "progress",
            sessionID: "progress",
            status: .running,
            summary: "Progress",
            progress: RelayProgress(completed: 31, total: 50, unit: "checks"),
            occurredAt: Date(timeIntervalSince1970: 100),
            receivedAt: Date(timeIntervalSince1970: 100)
        )
        let second = RelayEvent(
            source: .codex,
            sourceEvent: "heartbeat",
            sessionID: "progress",
            status: .running,
            summary: "Still working",
            occurredAt: Date(timeIntervalSince1970: 110),
            receivedAt: Date(timeIntervalSince1970: 110)
        )
        var snapshot = RelaySnapshot()
        snapshot.apply(first)
        snapshot.apply(second)

        #expect(snapshot.sessions["codex:progress"]?.progress?.percentage == 62)
    }

    @Test
    func testSessionEndDoesNotEraseReviewOrVerifiedOutcome() throws {
        let base = Date(timeIntervalSince1970: 100)
        let evidence = try #require(CompletionEvidenceBundle([
            CompletionEvidence(kind: .testPassed, summary: "Verified tests passed")
        ]))
        var snapshot = RelaySnapshot()
        snapshot.apply(RelayEvent(
            source: .codex,
            sourceEvent: "stop",
            sessionID: "review",
            status: .readyToReview,
            summary: "Review",
            occurredAt: base,
            receivedAt: base
        ))
        snapshot.apply(RelayEvent(
            source: .codex,
            sourceEvent: "session_end",
            sessionID: "review",
            status: .ended,
            summary: "Ended",
            occurredAt: base.addingTimeInterval(1),
            receivedAt: base.addingTimeInterval(1)
        ))
        snapshot.apply(RelayEvent(
            source: .claude,
            sourceEvent: "verified",
            sessionID: "completed",
            status: .completed,
            summary: "Completed",
            completionEvidence: evidence,
            occurredAt: base,
            receivedAt: base
        ))
        snapshot.apply(RelayEvent(
            source: .claude,
            sourceEvent: "session_end",
            sessionID: "completed",
            status: .ended,
            summary: "Ended",
            occurredAt: base.addingTimeInterval(1),
            receivedAt: base.addingTimeInterval(1)
        ))

        #expect(snapshot.sessions["codex:review"]?.status == .readyToReview)
        #expect(snapshot.sessions["claude:completed"]?.status == .completed)
        #expect(snapshot.sessions["claude:completed"]?.terminalAt == base)
        #expect(snapshot.sessions["claude:completed"]?.summary == "Completed")
        #expect(snapshot.sessions["claude:completed"]?.completionEvidence == evidence)
    }

    @Test
    func testNewWorkMayResumeACompletedSession() throws {
        let base = Date(timeIntervalSince1970: 100)
        let evidence = try #require(CompletionEvidenceBundle([
            CompletionEvidence(kind: .testPassed, summary: "Verified tests passed")
        ]))
        var snapshot = RelaySnapshot()
        snapshot.apply(RelayEvent(
            source: .codex,
            sourceEvent: "verified",
            sessionID: "resume",
            status: .completed,
            summary: "Completed",
            completionEvidence: evidence,
            occurredAt: base,
            receivedAt: base
        ))
        snapshot.apply(RelayEvent(
            source: .codex,
            sourceEvent: "new_turn",
            sessionID: "resume",
            status: .running,
            summary: "Working",
            occurredAt: base.addingTimeInterval(1),
            receivedAt: base.addingTimeInterval(1)
        ))

        #expect(snapshot.sessions["codex:resume"]?.status == .running)
        #expect(snapshot.sessions["codex:resume"]?.terminalAt == nil)
        #expect(snapshot.sessions["codex:resume"]?.completionEvidence == nil)
    }

    private func event(
        id: UUID = UUID(),
        status: RelayStatus,
        at date: Date,
        project: ProjectContext = ProjectContext()
    ) -> RelayEvent {
        RelayEvent(
            id: id,
            source: .codex,
            sourceEvent: status.rawValue,
            sessionID: "session-1",
            status: status,
            project: project,
            summary: "Status is \(status.rawValue)",
            occurredAt: date,
            receivedAt: date
        )
    }
}
