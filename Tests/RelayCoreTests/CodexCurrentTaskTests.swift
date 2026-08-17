import Foundation
import Testing
@testable import RelayCore

@Suite("Codex current task reconciliation")
struct CodexCurrentTaskTests {
    @Test
    func testCandidateDiscoveryUsesOnlyActivelyHeldLockIDsWithBoundedTitles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locks = root.appendingPathComponent("thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let firstID = "00000000-0000-0000-0000-000000000001"
        let helperID = "00000000-0000-0000-0000-000000000002"
        let historicalID = "00000000-0000-0000-0000-000000000003"
        let firstLock = try holdLock(at: locks.appendingPathComponent("\(firstID).lock"))
        defer { releaseLock(firstLock) }
        let helperLock = try holdLock(at: locks.appendingPathComponent("\(helperID).lock"))
        defer { releaseLock(helperLock) }
        try Data().write(to: locks.appendingPathComponent("\(historicalID).lock"))
        try Data().write(to: locks.appendingPathComponent("not-a-session.lock"))

        let index = root.appendingPathComponent("session_index.jsonl")
        try Data(
            """
            {"id":"\(firstID)","thread_name":"  核查 Notch Relay 当前状态  ","ignored":"private"}
            {"id":"\(historicalID)","thread_name":"遗留任务"}
            """.utf8
        ).write(to: index)

        let tasks = try CodexCurrentTaskProbe.readCandidates(configuration: .init(
            sessionIndex: index,
            writerLocksDirectory: locks,
            ipcSocket: root.appendingPathComponent("ipc.sock")
        ))

        #expect(tasks == [CodexCurrentTask(
            sessionID: firstID,
            title: "核查 Notch Relay 当前状态",
            observedAt: .distantPast
        )])
    }

    @Test
    func testFetchFallsBackToHeldTitleCandidatesWhenDesktopIPCIsUnavailable() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locks = root.appendingPathComponent("thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let sessionID = "00000000-0000-0000-0000-000000000001"
        let lock = try holdLock(at: locks.appendingPathComponent("\(sessionID).lock"))
        defer { releaseLock(lock) }
        let index = root.appendingPathComponent("session_index.jsonl")
        try Data(
            """
            {"id":"\(sessionID)","thread_name":"核查 Notch Relay 当前状态"}
            """.utf8
        ).write(to: index)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let tasks = try await CodexCurrentTaskProbe(configuration: .init(
            sessionIndex: index,
            writerLocksDirectory: locks,
            ipcSocket: root.appendingPathComponent("missing-ipc.sock"),
            timeout: 0.2
        )).fetch(now: now)

        #expect(tasks == [CodexCurrentTask(
            sessionID: sessionID,
            title: "核查 Notch Relay 当前状态",
            observedAt: now
        )])
    }

    @Test
    func testDuplicateCurrentTitlesKeepOnlyMostRecentlyRenamedSession() throws {
        let older = CodexCurrentTask(
            sessionID: "00000000-0000-0000-0000-000000000006",
            title: "合成重复任务",
            titleUpdatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = CodexCurrentTask(
            sessionID: "00000000-0000-0000-0000-000000000007",
            title: "合成重复任务",
            titleUpdatedAt: Date(timeIntervalSince1970: 200)
        )

        let tasks = CodexCurrentTaskProbe.deduplicateTitles([older, newer])

        #expect(tasks == [newer])
    }

    @Test
    func testAccountSwitchAddsCurrentRowsAndExcludesOldRunningRows() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = makeSession(
            id: "00000000-0000-0000-0000-000000000003",
            title: "old",
            status: .running,
            at: now.addingTimeInterval(-100)
        )
        let first = CodexCurrentTask(
            sessionID: "00000000-0000-0000-0000-000000000001",
            title: "核查 Notch Relay 当前状态",
            observedAt: now
        )
        let second = CodexCurrentTask(
            sessionID: "00000000-0000-0000-0000-000000000004",
            title: "检查 QuietLens Phase 3B 状态",
            observedAt: now
        )

        let result = CodexCurrentTaskPresentation.reconcile(
            snapshot: RelaySnapshot(sessions: [old.key: old]),
            currentTasks: [first, second],
            now: now
        )

        #expect(result.isAuthoritative)
        #expect(result.currentSessionKeys == [first.sessionKey, second.sessionKey])
        #expect(result.snapshot.sessions[first.sessionKey]?.status == .running)
        #expect(result.snapshot.sessions[second.sessionKey]?.status == .running)
        #expect(result.snapshot.sessions[old.key] != nil)
        #expect(!LocalTaskPresentation.shouldDisplay(
            session: old,
            metadata: LocalTaskMetadata(taskTitle: "审阅 Notch Relay 当前状态"),
            currentSessionKeys: result.currentSessionKeys,
            authoritativeCurrentSources: [.codex]
        ))
    }

    @Test
    func testCurrentOwnershipDoesNotOverridePermissionOrInputState() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let permission = makeSession(
            id: "00000000-0000-0000-0000-000000000001",
            title: "permission",
            status: .needsPermission,
            at: now
        )
        let input = makeSession(
            id: "00000000-0000-0000-0000-000000000004",
            title: "input",
            status: .needsInput,
            at: now
        )
        let tasks = [
            CodexCurrentTask(sessionID: permission.sessionID, title: "权限任务", observedAt: now),
            CodexCurrentTask(sessionID: input.sessionID, title: "提问任务", observedAt: now)
        ]

        let result = CodexCurrentTaskPresentation.reconcile(
            snapshot: RelaySnapshot(sessions: [permission.key: permission, input.key: input]),
            currentTasks: tasks,
            now: now
        )

        #expect(result.snapshot.sessions[permission.key]?.status == .needsPermission)
        #expect(result.snapshot.sessions[input.key]?.status == .needsInput)
    }

    @Test
    func testUnavailableProbeHidesHistoricalRowsFromCurrentPresentation() {
        let session = makeSession(
            id: "00000000-0000-0000-0000-000000000003",
            title: "old",
            status: .running,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = RelaySnapshot(sessions: [session.key: session])

        let result = CodexCurrentTaskPresentation.reconcile(
            snapshot: snapshot,
            currentTasks: []
        )

        #expect(result.isAuthoritative)
        #expect(result.snapshot == snapshot)
        #expect(result.currentSessionKeys.isEmpty)
        #expect(!LocalTaskPresentation.shouldDisplay(
            session: session,
            metadata: LocalTaskMetadata(taskTitle: "旧任务"),
            currentSessionKeys: result.currentSessionKeys,
            authoritativeCurrentSources: [.codex]
        ))
    }

    @Test
    func testObservationRetainsLastSuccessOnlyInsideGracePeriod() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let task = CodexCurrentTask(
            sessionID: "00000000-0000-0000-0000-000000000001",
            title: "核查 Notch Relay 当前状态",
            observedAt: first
        )
        var observation = CodexCurrentTaskObservation()

        #expect(observation.resolve(now: first).availability == .checking)
        observation.recordSuccess([task], at: first)
        #expect(observation.resolve(now: first).availability == .current)

        observation.recordFailure(at: first.addingTimeInterval(1))
        let reconnecting = observation.resolve(
            now: first.addingTimeInterval(5),
            staleGraceInterval: 6
        )
        #expect(reconnecting.availability == .reconnecting)
        #expect(reconnecting.tasks == [task])

        let unavailable = observation.resolve(
            now: first.addingTimeInterval(7),
            staleGraceInterval: 6
        )
        #expect(unavailable.availability == .unavailable)
        #expect(unavailable.tasks.isEmpty)
    }

    @Test
    func testObservationSwitchesImmediatelyToNewSuccessfulAccountSet() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let accountA = CodexCurrentTask(
            sessionID: "00000000-0000-0000-0000-000000000001",
            title: "账号 A 任务",
            observedAt: first
        )
        let accountB = CodexCurrentTask(
            sessionID: "00000000-0000-0000-0000-000000000005",
            title: "账号 B 任务",
            observedAt: first.addingTimeInterval(2)
        )
        var observation = CodexCurrentTaskObservation()

        observation.recordSuccess([accountA], at: first)
        observation.recordSuccess([accountB], at: first.addingTimeInterval(2))

        let resolved = observation.resolve(now: first.addingTimeInterval(2))
        #expect(resolved.availability == .current)
        #expect(resolved.tasks == [accountB])
    }

    @Test
    func testOwnedEndedSessionIsPresentedAsRunningWithoutChangingCanonicalInput() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ended = makeSession(
            id: "00000000-0000-0000-0000-000000000001",
            title: "ended",
            status: .ended,
            at: now.addingTimeInterval(-60)
        )
        let snapshot = RelaySnapshot(sessions: [ended.key: ended])

        let result = CodexCurrentTaskPresentation.reconcile(
            snapshot: snapshot,
            currentTasks: [CodexCurrentTask(
                sessionID: ended.sessionID,
                title: "核查 Notch Relay 当前状态",
                observedAt: now
            )],
            now: now
        )

        #expect(result.snapshot.sessions[ended.key]?.status == .running)
        #expect(snapshot.sessions[ended.key]?.status == .ended)
    }

    private func makeSession(
        id: String,
        title: String,
        status: RelayStatus,
        at: Date
    ) -> RelaySessionState {
        RelaySessionState(event: RelayEvent(
            source: .codex,
            sourceEvent: title,
            sessionID: id,
            status: status,
            summary: title,
            occurredAt: at,
            receivedAt: at
        ))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-codex-current-tests-\(UUID().uuidString)")
    }

    private func holdLock(at url: URL) throws -> FileHandle {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forUpdating: url)
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try handle.close()
            throw CodexCurrentTaskProbeError.sourceUnavailable
        }
        return handle
    }

    private func releaseLock(_ handle: FileHandle) {
        _ = flock(handle.fileDescriptor, LOCK_UN)
        try? handle.close()
    }
}
