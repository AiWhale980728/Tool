import Foundation
import Testing
@testable import RelayCore

@Suite("Relay daemon support", .serialized)
struct RelayDaemonTests {
    @Test
    func testHealthPersistsAndReloads() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RelayStorePaths(root: root)
        let store = RelayDaemonHealthStore(paths: paths)
        let startedAt = Date(timeIntervalSince1970: 100)
        var health = RelayDaemonHealth(processID: 42, startedAt: startedAt, lastPassAt: startedAt)
        health.record(ProcessingReport(applied: 2, duplicates: 1, stale: 3, quarantined: 4), at: Date(timeIntervalSince1970: 101))

        try store.persist(health)
        let loaded = try store.load()
        let reloaded = try #require(loaded)

        #expect(reloaded == health)
        #expect(reloaded.passCount == 1)
        #expect(reloaded.applied == 2)
        #expect(reloaded.duplicates == 1)
        #expect(reloaded.stale == 3)
        #expect(reloaded.quarantined == 4)
    }

    @Test
    func testLeaseCannotBeUsedForDifferentStore() throws {
        let firstRoot = temporaryRoot()
        let secondRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let lease = try RelayProcessingLease(paths: RelayStorePaths(root: firstRoot))
        let processor = RelayProcessor(root: secondRoot)

        #expect(throws: (any Error).self) {
            try processor.processPending(holding: lease)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-daemon-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

private extension ProcessingReport {
    init(applied: Int, duplicates: Int, stale: Int, quarantined: Int) {
        self.init()
        self.applied = applied
        self.duplicates = duplicates
        self.stale = stale
        self.quarantined = quarantined
    }
}
