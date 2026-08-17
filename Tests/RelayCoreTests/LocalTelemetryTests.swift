import Foundation
import Testing
@testable import RelayCore

@Suite("Privacy-bounded local telemetry")
struct LocalTelemetryTests {
    @Test
    func appendLoadSummarizeAndDeleteRoundTrip() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalTelemetryStore(root: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        try store.record(RelayTelemetryEvent(
            occurredAt: now,
            name: .workbenchOpened,
            surface: .workbench,
            outcome: .shown
        ), now: now)
        try store.record(RelayTelemetryEvent(
            occurredAt: now.addingTimeInterval(2),
            name: .providerFinished,
            surface: .supervisor,
            outcome: .succeeded,
            duration: .oneToThreeSeconds
        ), now: now.addingTimeInterval(2))

        let events = try store.load()
        #expect(events.count == 2)
        let summary = try store.summary(now: now.addingTimeInterval(2))
        #expect(summary.workbenchOpenCount == 1)
        #expect(summary.reviewSucceededCount == 1)
        #expect(summary.reviewFallbackCount == 0)

        try store.delete()
        #expect(try store.load().isEmpty)
    }

    @Test
    func pruningAppliesRetentionAndMaximumCount() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalTelemetryStore(root: root, retention: 100, maximumEventCount: 2)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        for offset in [-200.0, -3, -2, -1] {
            let date = now.addingTimeInterval(offset)
            try store.record(RelayTelemetryEvent(
                occurredAt: date,
                name: .messageShown,
                surface: .banner,
                outcome: .notice
            ), now: date)
        }
        try store.prune(now: now)

        let events = try store.load()
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.occurredAt >= now.addingTimeInterval(-2) })
    }

    @Test
    func encodedSchemaCannotContainFreeFormProductData() throws {
        let event = RelayTelemetryEvent(
            name: .providerFinished,
            surface: .supervisor,
            outcome: .fallback,
            duration: .threeToTenSeconds
        )
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)

        #expect(!text.contains("task"))
        #expect(!text.contains("prompt"))
        #expect(!text.contains("path"))
        #expect(!text.contains("response"))
        #expect(!text.contains("apiKey"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
