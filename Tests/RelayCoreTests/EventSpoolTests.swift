import Foundation
import Testing
@testable import RelayCore

@Suite("Durable event spool", .serialized)
struct EventSpoolTests {
    @Test
    func testEndToEndQueueProcessPersistAndArchive() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = EventSpool(root: root)
        let processor = RelayProcessor(root: root)
        let earlier = makeEvent(
            sessionID: "ordered-session",
            status: .running,
            occurredAt: Date(timeIntervalSince1970: 100),
            receivedAt: Date(timeIntervalSince1970: 102)
        )
        let later = makeEvent(
            sessionID: "ordered-session",
            status: .completed,
            occurredAt: Date(timeIntervalSince1970: 101),
            receivedAt: Date(timeIntervalSince1970: 101)
        )

        // Arrival order intentionally differs from occurrence order.
        try spool.enqueue(later)
        try spool.enqueue(earlier)
        let report = try processor.processPending()

        #expect(report.applied == 2)
        #expect(report.total == 2)
        #expect(try spool.pendingFiles().isEmpty)
        #expect(try jsonFileCount(at: spool.paths.archive) == 2)

        let snapshot = try processor.stateStore.load()
        let session = try #require(snapshot.sessions["codex:ordered-session"])
        #expect(session.status == .readyToReview)
        #expect(session.eventCount == 2)
    }

    @Test
    func testReplayAfterSnapshotPersistenceIsIdempotent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = EventSpool(root: root)
        let processor = RelayProcessor(root: root)
        let event = makeEvent(sessionID: "replay-session", status: .needsInput)
        try spool.enqueue(event)

        var snapshot = RelaySnapshot()
        #expect(snapshot.apply(event) == .applied)
        try processor.stateStore.persist(snapshot)
        // Simulate a crash after persisting state but before archiving the inbox file.

        let report = try processor.processPending()
        #expect(report.duplicates == 1)
        #expect(report.applied == 0)
        #expect(try spool.pendingFiles().isEmpty)
        #expect(try processor.stateStore.load().sessions["codex:replay-session"]?.eventCount == 1)
    }

    @Test
    func testMalformedEventIsQuarantinedWithoutBlockingValidEvents() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = EventSpool(root: root)
        try spool.prepare()
        let malformed = spool.paths.inbox.appendingPathComponent("000-malformed.json")
        try Data("{ definitely-not-json".utf8).write(to: malformed)
        try spool.enqueue(makeEvent(sessionID: "valid-session", status: .running))

        let report = try RelayProcessor(root: root).processPending()

        #expect(report.quarantined == 1)
        #expect(report.applied == 1)
        #expect(try jsonFileCount(at: spool.paths.quarantine) == 1)
        #expect(try spool.pendingFiles().isEmpty)
    }

    @Test
    func testSnapshotSurvivesStoreRestart() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProcessor = RelayProcessor(root: root)
        try firstProcessor.spool.enqueue(
            makeEvent(sessionID: "restart-session", status: .needsPermission)
        )
        _ = try firstProcessor.processPending()

        let restartedStore = RelayStateStore(paths: RelayStorePaths(root: root))
        let reloaded = try restartedStore.load()

        #expect(reloaded.sessions["codex:restart-session"]?.status == .needsPermission)
        #expect(reloaded.attentionRequiredCount == 1)
    }

    @Test
    func testUnsupportedEventSchemaIsQuarantined() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = EventSpool(root: root)
        try spool.prepare()
        var event = makeEvent(sessionID: "future-event", status: .running)
        event.schemaVersion = RelayEvent.currentSchemaVersion + 1
        let data = try RelayJSON.makeEncoder().encode(event)
        let file = spool.paths.inbox.appendingPathComponent("future-schema.json")
        try data.write(to: file)

        let report = try RelayProcessor(root: root).processPending()

        #expect(report.quarantined == 1)
        #expect(report.applied == 0)
        #expect(try jsonFileCount(at: spool.paths.quarantine) == 1)
    }

    @Test
    func testConcurrentWritersDoNotLoseEvents() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = EventSpool(root: root)
        let eventCount = 50

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<eventCount {
                group.addTask {
                    let event = self.makeEvent(
                        sessionID: "concurrent-\(index)",
                        status: .running,
                        occurredAt: Date(timeIntervalSince1970: Double(1_000 + index)),
                        receivedAt: Date(timeIntervalSince1970: 2_000)
                    )
                    try spool.enqueue(event)
                }
            }
            try await group.waitForAll()
        }

        #expect(try spool.pendingFiles().count == eventCount)
        let report = try RelayProcessor(root: root).processPending()
        #expect(report.applied == eventCount)
        #expect(try RelayStateStore(paths: spool.paths).load().sessions.count == eventCount)
    }

    @Test
    func testLegacySnapshotMigratesUnverifiedCompletionToReview() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RelayStorePaths(root: root)
        let store = RelayStateStore(paths: paths)
        let date = Date(timeIntervalSince1970: 100)
        let legacyEvent = makeEvent(sessionID: "legacy", status: .completed, occurredAt: date)
        var legacy = RelaySnapshot(schemaVersion: 1)
        legacy.sessions[legacyEvent.sessionKey] = RelaySessionState(event: legacyEvent)
        legacy.sessions[legacyEvent.sessionKey]?.status = .completed
        legacy.sessions[legacyEvent.sessionKey]?.attention = .passive
        legacy.sessions[legacyEvent.sessionKey]?.terminalAt = nil
        try store.persist(legacy)

        let migrated = try store.load()

        #expect(migrated.schemaVersion == RelaySnapshot.currentSchemaVersion)
        #expect(migrated.sessions["codex:legacy"]?.status == .readyToReview)
        #expect(migrated.sessions["codex:legacy"]?.terminalAt == nil)
    }

    @Test
    func testProcessorRemovesExpiredLocalPresentationStateOnNextPass() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = RelayProcessor(root: root)
        let old = Date(timeIntervalSince1970: 100)
        let evidence = try #require(CompletionEvidenceBundle([
            CompletionEvidence(kind: .testPassed, summary: "Verified tests passed")
        ]))
        let completed = RelayEvent(
            source: .codex,
            sourceEvent: "verified",
            sessionID: "expired",
            status: .completed,
            summary: "Verified completion",
            completionEvidence: evidence,
            occurredAt: old,
            receivedAt: old
        )
        try processor.spool.enqueue(completed)
        let report = try processor.processPending()

        #expect(report.cleanedUp == 1)
        #expect(try processor.stateStore.load().sessions["codex:expired"] == nil)
        #expect(try jsonFileCount(at: processor.spool.paths.archive) == 1)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeEvent(
        sessionID: String,
        status: RelayStatus,
        occurredAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        receivedAt: Date = Date(timeIntervalSince1970: 1_700_000_001)
    ) -> RelayEvent {
        RelayEvent(
            source: .codex,
            sourceEvent: status.rawValue,
            sessionID: sessionID,
            status: status,
            summary: "Test \(status.rawValue)",
            occurredAt: occurredAt,
            receivedAt: receivedAt
        )
    }

    private func jsonFileCount(at directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.count
    }
}
