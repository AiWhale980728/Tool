import Foundation
import Testing
@testable import RelayCore

@Suite("Application instance lease", .serialized)
struct ApplicationInstanceLeaseTests {
    @Test
    func onlyOneLeaseMayOwnTheApplicationLock() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockFile = RelayStorePaths(root: root).applicationInstanceLock

        try verifyContention(lockFile: lockFile)

        let replacementLease = try RelayApplicationInstanceLease(lockFile: lockFile)
        #expect(replacementLease != nil)
    }

    private func verifyContention(lockFile: URL) throws {
        guard let firstLease = try RelayApplicationInstanceLease(lockFile: lockFile) else {
            Issue.record("The first application instance could not acquire a fresh lock")
            return
        }
        let competingLease = try withExtendedLifetime(firstLease) {
            try RelayApplicationInstanceLease(lockFile: lockFile)
        }
        #expect(competingLease == nil)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-application-lease-\(UUID().uuidString)", isDirectory: true)
    }
}
