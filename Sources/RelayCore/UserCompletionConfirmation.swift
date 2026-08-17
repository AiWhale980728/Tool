import Foundation

public struct UserCompletionConfirmation: Sendable {
    public static let sourceEvent = "UserConfirmedCompletion"
    public static let summary = "Completion confirmed by user"
    public static let evidenceSummary = "User reviewed and confirmed this result"

    public let spool: EventSpool
    public let stateStore: RelayStateStore

    public init(root: URL) {
        let paths = RelayStorePaths(root: root)
        spool = EventSpool(paths: paths)
        stateStore = RelayStateStore(paths: paths)
    }

    public init(spool: EventSpool, stateStore: RelayStateStore) {
        self.spool = spool
        self.stateStore = stateStore
    }

    @discardableResult
    public func enqueue(
        sessionKey: String,
        expectedLastEventID: UUID,
        confirmedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let snapshot = try stateStore.load(fileManager: fileManager)
        guard let session = snapshot.sessions[sessionKey] else {
            throw RelayError.invalidConfirmation("task is no longer available")
        }
        guard session.status == .readyToReview else {
            throw RelayError.invalidConfirmation("only a result ready for review can be confirmed")
        }
        guard session.lastEventID == expectedLastEventID else {
            throw RelayError.invalidConfirmation("the Agent has newer activity; review the latest result")
        }

        return try spool.enqueue(
            Self.makeEvent(for: session, confirmedAt: confirmedAt),
            fileManager: fileManager
        )
    }

    public static func makeEvent(
        for session: RelaySessionState,
        confirmedAt: Date = Date()
    ) -> RelayEvent {
        let evidence = CompletionEvidence(
            kind: .userConfirmed,
            summary: evidenceSummary,
            sourceID: session.lastEventID.uuidString.lowercased()
        )
        return RelayEvent(
            source: session.source,
            sourceEvent: sourceEvent,
            sessionID: session.sessionID,
            status: .completed,
            project: session.project,
            model: session.model,
            summary: summary,
            completionEvidence: CompletionEvidenceBundle([evidence]),
            occurredAt: confirmedAt,
            receivedAt: confirmedAt
        )
    }
}
