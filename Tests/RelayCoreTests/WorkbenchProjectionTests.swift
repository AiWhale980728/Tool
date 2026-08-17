import Foundation
import Testing
@testable import RelayCore

@Suite("Workbench projection")
struct WorkbenchProjectionTests {
    @Test
    func testAttentionWinsAndGroupsConcurrentTasksByAgent() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = RelaySnapshot()
        snapshot.apply(event(source: .codex, session: "one", status: .running, at: now))
        snapshot.apply(event(source: .codex, session: "two", status: .running, at: now.addingTimeInterval(1)))
        snapshot.apply(event(source: .claude, session: "permission", status: .needsPermission, at: now.addingTimeInterval(2)))
        snapshot.apply(event(source: .claude, session: "input", status: .needsInput, at: now.addingTimeInterval(3)))

        let projection = WorkbenchProjection(snapshot: snapshot, now: now.addingTimeInterval(4))

        #expect(
            projection.hero
                == .needsAttention(sessionKey: "claude:input", additionalCount: 1)
        )
        #expect(projection.agentGroups.first { $0.source == .codex }?.tasks.count == 2)
        #expect(projection.agentGroups.first { $0.source == .claude }?.tasks.count == 2)
    }

    @Test
    func testAllClearWhenTasksWorkWithoutAttention() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = RelaySnapshot()
        snapshot.apply(event(source: .codex, session: "one", status: .running, at: now))
        snapshot.apply(event(source: .claude, session: "two", status: .running, at: now))

        let projection = WorkbenchProjection(snapshot: snapshot, now: now)

        #expect(projection.hero == .allClear(activeTaskCount: 2))
    }

    @Test
    func testAwaitOrdersIncludesConnectedAgentsWithoutTasks() {
        let projection = WorkbenchProjection(
            snapshot: RelaySnapshot(),
            connectedSources: [.codex, .claude],
            now: Date(timeIntervalSince1970: 10_000)
        )

        #expect(projection.hero == .awaitOrders)
        #expect(projection.agentGroups.map(\.source) == [.codex, .claude])
        #expect(projection.agentGroups.allSatisfy { $0.tasks.isEmpty })
    }

    @Test
    func testReviewPrecedesCompletedAndWorking() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let evidence = try #require(CompletionEvidenceBundle([
            CompletionEvidence(kind: .buildSucceeded, summary: "Verified build succeeded")
        ]))
        var snapshot = RelaySnapshot()
        snapshot.apply(event(source: .codex, session: "working", status: .running, at: now))
        snapshot.apply(event(source: .claude, session: "review", status: .readyToReview, at: now.addingTimeInterval(1)))
        snapshot.apply(RelayEvent(
            source: .cursor,
            sourceEvent: "verified",
            sessionID: "done",
            status: .completed,
            summary: "Done",
            completionEvidence: evidence,
            occurredAt: now.addingTimeInterval(2),
            receivedAt: now.addingTimeInterval(2)
        ))

        let projection = WorkbenchProjection(snapshot: snapshot, now: now.addingTimeInterval(3))

        #expect(projection.hero == .readyToReview(sessionKey: "claude:review", additionalCount: 0))
    }

    @Test
    func testWorkbenchShowsEveryTaskPerAgentInPriorityOrder() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = RelaySnapshot()
        for index in 0..<7 {
            snapshot.apply(event(
                source: .codex,
                session: "codex-working-\(index)",
                status: .running,
                at: now.addingTimeInterval(Double(index))
            ))
            snapshot.apply(event(
                source: .claude,
                session: "claude-working-\(index)",
                status: .running,
                at: now.addingTimeInterval(Double(index))
            ))
        }
        snapshot.apply(event(
            source: .claude,
            session: "claude-permission",
            status: .needsPermission,
            at: now.addingTimeInterval(-100)
        ))
        snapshot.apply(event(
            source: .codex,
            session: "codex-permission",
            status: .needsPermission,
            at: now.addingTimeInterval(-100)
        ))

        let projection = WorkbenchProjection(snapshot: snapshot, now: now.addingTimeInterval(20))
        let codex = projection.agentGroups.first { $0.source == .codex }
        let claude = projection.agentGroups.first { $0.source == .claude }

        #expect(codex?.tasks.count == 8)
        #expect(claude?.tasks.count == 8)
        #expect(codex?.totalTaskCount == 8)
        #expect(claude?.totalTaskCount == 8)
        #expect(codex?.tasks.contains { $0.session.sessionID == "codex-permission" } == true)
        #expect(claude?.tasks.contains { $0.session.sessionID == "claude-permission" } == true)
    }

    @Test
    func testUserPriorityCreatesGlobalPinnedNormalAndLaterSections() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = RelaySnapshot()
        snapshot.apply(event(source: .codex, session: "older", status: .running, at: now))
        snapshot.apply(event(
            source: .codex,
            session: "newer",
            status: .running,
            at: now.addingTimeInterval(10)
        ))
        snapshot.apply(event(
            source: .codex,
            session: "permission",
            status: .needsPermission,
            at: now.addingTimeInterval(-100)
        ))

        let projection = WorkbenchProjection(
            snapshot: snapshot,
            now: now.addingTimeInterval(20),
            attentionLevels: [
                "codex:older": .pinned,
                "codex:permission": .later
            ]
        )
        let keys = projection.agentGroups.first?.tasks.map(\.session.key)

        #expect(keys == ["codex:older", "codex:newer", "codex:permission"])
        #expect(projection.hero == .needsAttention(sessionKey: "codex:permission", additionalCount: 0))
    }

    @Test
    func testFinishedAndCleanupCellsUseTerminalTimestamps() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: (24 * 60 * 60) + (23.75 * 60 * 60))
        let completedAt = now.addingTimeInterval(-23.5 * 60 * 60)
        let evidence = try #require(CompletionEvidenceBundle([
            CompletionEvidence(kind: .testPassed, summary: "Verified tests passed")
        ]))
        var snapshot = RelaySnapshot()
        snapshot.apply(RelayEvent(
            source: .codex,
            sourceEvent: "verified",
            sessionID: "done",
            status: .completed,
            summary: "Done",
            completionEvidence: evidence,
            occurredAt: completedAt,
            receivedAt: completedAt
        ))

        let projection = WorkbenchProjection(
            snapshot: snapshot,
            now: now,
            calendar: calendar
        )

        #expect(projection.finishedTodayCount == 1)
        #expect(projection.cleanupReminderCount == 1)
        #expect(projection.nextCleanupAt == completedAt.addingTimeInterval(24 * 60 * 60))
    }

    @Test
    func testCompletionHeroSettlesIntoFinishedToday() throws {
        let completedAt = Date(timeIntervalSince1970: 10_000)
        let evidence = try #require(CompletionEvidenceBundle([
            CompletionEvidence(kind: .testPassed, summary: "Verified tests passed")
        ]))
        var snapshot = RelaySnapshot()
        snapshot.apply(RelayEvent(
            source: .codex,
            sourceEvent: "verified",
            sessionID: "done",
            status: .completed,
            summary: "Done",
            completionEvidence: evidence,
            occurredAt: completedAt,
            receivedAt: completedAt
        ))

        let immediate = WorkbenchProjection(
            snapshot: snapshot,
            now: completedAt.addingTimeInterval(2)
        )
        let settled = WorkbenchProjection(
            snapshot: snapshot,
            now: completedAt.addingTimeInterval(10)
        )

        #expect(immediate.hero == .completed(sessionKey: "codex:done", additionalCount: 0))
        #expect(settled.hero == .awaitOrders)
    }

    private func event(
        source: AgentSource,
        session: String,
        status: RelayStatus,
        at date: Date
    ) -> RelayEvent {
        RelayEvent(
            source: source,
            sourceEvent: status.rawValue,
            sessionID: session,
            status: status,
            summary: status.rawValue,
            occurredAt: date,
            receivedAt: date
        )
    }
}
