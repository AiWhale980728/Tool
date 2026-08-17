import Foundation

public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case cursor
    case generic
}

public enum RelayStatus: String, Codable, CaseIterable, Sendable {
    case running
    case needsInput = "needs_input"
    case needsPermission = "needs_permission"
    case readyToReview = "ready_to_review"
    case failed
    case completed
    case cancelled
    case ended

    public var requiresAttention: Bool {
        switch self {
        case .needsInput, .needsPermission, .failed:
            true
        case .running, .readyToReview, .completed, .cancelled, .ended:
            false
        }
    }

    public var isRetainedTerminal: Bool {
        switch self {
        case .failed, .completed, .cancelled, .ended:
            true
        case .running, .needsInput, .needsPermission, .readyToReview:
            false
        }
    }

    public var isFinishedWorkbenchRecord: Bool {
        switch self {
        case .failed, .completed, .cancelled:
            true
        case .running, .needsInput, .needsPermission, .readyToReview, .ended:
            false
        }
    }
}

public enum AttentionLevel: String, Codable, CaseIterable, Sendable {
    case silent
    case passive
    case interrupt
    case critical
}

public struct ProjectContext: Codable, Equatable, Sendable {
    public var cwd: String?
    public var name: String?
    public var repository: String?
    public var branch: String?

    public init(
        cwd: String? = nil,
        name: String? = nil,
        repository: String? = nil,
        branch: String? = nil
    ) {
        self.cwd = cwd
        self.name = name
        self.repository = repository
        self.branch = branch
    }
}

public struct RelayProgress: Codable, Equatable, Sendable {
    public var completed: Double
    public var total: Double
    public var unit: String?

    public init?(completed: Double, total: Double, unit: String? = nil) {
        guard completed.isFinite,
              total.isFinite,
              total > 0,
              completed >= 0,
              completed <= total else { return nil }
        self.completed = completed
        self.total = total
        self.unit = unit.map { String($0.prefix(40)) }
    }

    public var fraction: Double { completed / total }

    public var percentage: Int {
        Int((fraction * 100).rounded())
    }

    private enum CodingKeys: String, CodingKey {
        case completed
        case total
        case unit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let completed = try container.decode(Double.self, forKey: .completed)
        let total = try container.decode(Double.self, forKey: .total)
        let unit = try container.decodeIfPresent(String.self, forKey: .unit)
        guard let progress = RelayProgress(completed: completed, total: total, unit: unit) else {
            throw DecodingError.dataCorruptedError(
                forKey: .total,
                in: container,
                debugDescription: "progress requires 0 <= completed <= total and total > 0"
            )
        }
        self = progress
    }
}

public enum CompletionEvidenceKind: String, Codable, CaseIterable, Sendable {
    case testPassed = "test_passed"
    case buildSucceeded = "build_succeeded"
    case artifactProduced = "artifact_produced"
    case deploymentAvailable = "deployment_available"
    case reviewAvailable = "review_available"
    case providerSignal = "provider_signal"
    case userConfirmed = "user_confirmed"
}

public struct CompletionEvidence: Codable, Equatable, Sendable {
    public var kind: CompletionEvidenceKind
    public var summary: String
    public var sourceID: String?

    public init(kind: CompletionEvidenceKind, summary: String, sourceID: String? = nil) {
        self.kind = kind
        self.summary = Self.normalized(summary, limit: 240)
        self.sourceID = sourceID.map { Self.normalized($0, limit: 256) }
    }

    public var verifiesCompletion: Bool {
        switch kind {
        case .userConfirmed:
            guard let sourceID else { return false }
            return UUID(uuidString: sourceID) != nil
        case .testPassed, .buildSucceeded, .artifactProduced, .deploymentAvailable,
             .reviewAvailable, .providerSignal:
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case summary
        case sourceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(CompletionEvidenceKind.self, forKey: .kind)
        let summary = try container.decode(String.self, forKey: .summary)
        let sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
        guard Self.isCanonical(summary, limit: 240),
              sourceID.map({ Self.isCanonical($0, limit: 256) }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .summary,
                in: container,
                debugDescription: "completion evidence contains an invalid or oversized label"
            )
        }
        self.init(kind: kind, summary: summary, sourceID: sourceID)
    }

    private static func normalized(_ value: String, limit: Int) -> String {
        let printable = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        let collapsed = printable
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    private static func isCanonical(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.count <= limit && normalized(value, limit: limit) == value
    }
}

public struct CompletionEvidenceBundle: Codable, Equatable, Sendable {
    public var items: [CompletionEvidence]

    public init?(_ items: [CompletionEvidence]) {
        guard !items.isEmpty,
              items.count <= 8,
              items.allSatisfy({ !$0.summary.isEmpty }) else { return nil }
        self.items = items
    }

    public var verifiesCompletion: Bool {
        !items.isEmpty
            && items.count <= 8
            && items.allSatisfy { !$0.summary.isEmpty && $0.verifiesCompletion }
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode([CompletionEvidence].self, forKey: .items)
        guard let bundle = CompletionEvidenceBundle(items) else {
            throw DecodingError.dataCorruptedError(
                forKey: .items,
                in: container,
                debugDescription: "completion evidence requires between one and eight items"
            )
        }
        self = bundle
    }
}

public struct RelayEvent: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2
    public static let supportedSchemaVersions = 1...currentSchemaVersion

    public var schemaVersion: Int
    public var id: UUID
    public var source: AgentSource
    public var sourceEvent: String
    public var sessionID: String
    public var turnID: String?
    public var status: RelayStatus
    public var attention: AttentionLevel
    public var project: ProjectContext
    public var model: String?
    public var summary: String
    public var progress: RelayProgress?
    public var completionEvidence: CompletionEvidenceBundle?
    public var occurredAt: Date
    public var receivedAt: Date
    public var fingerprint: String

    public init(
        schemaVersion: Int = RelayEvent.currentSchemaVersion,
        id: UUID = UUID(),
        source: AgentSource,
        sourceEvent: String,
        sessionID: String,
        turnID: String? = nil,
        status: RelayStatus,
        attention: AttentionLevel? = nil,
        project: ProjectContext = ProjectContext(),
        model: String? = nil,
        summary: String,
        progress: RelayProgress? = nil,
        completionEvidence: CompletionEvidenceBundle? = nil,
        occurredAt: Date = Date(),
        receivedAt: Date = Date(),
        fingerprint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.source = source
        self.sourceEvent = sourceEvent
        self.sessionID = sessionID
        self.turnID = turnID
        self.status = status
        self.attention = attention ?? AttentionPolicy.level(for: status)
        self.project = project
        self.model = model
        self.summary = summary
        self.progress = progress
        self.completionEvidence = completionEvidence
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
        self.fingerprint = fingerprint ?? RelayFingerprint.make(
            source: source,
            sourceEvent: sourceEvent,
            sessionID: sessionID,
            turnID: turnID,
            status: status,
            summary: summary,
            progress: progress,
            completionEvidence: completionEvidence
        )
    }

    public var sessionKey: String {
        "\(source.rawValue):\(sessionID)"
    }

    public var effectiveStatus: RelayStatus {
        guard status == .completed else { return status }
        return completionEvidence?.verifiesCompletion == true ? .completed : .readyToReview
    }

    public var claimsUserConfirmation: Bool {
        status == .completed
            && completionEvidence?.items.contains(where: { $0.kind == .userConfirmed }) == true
    }

    public var userConfirmationTargetEventID: UUID? {
        guard claimsUserConfirmation,
              let sourceID = completionEvidence?.items.first(where: { $0.kind == .userConfirmed })?.sourceID
        else { return nil }
        return UUID(uuidString: sourceID)
    }
}

public enum RelayFingerprint {
    public static func make(
        source: AgentSource,
        sourceEvent: String,
        sessionID: String,
        turnID: String?,
        status: RelayStatus,
        summary: String,
        progress: RelayProgress? = nil,
        completionEvidence: CompletionEvidenceBundle? = nil
    ) -> String {
        let progressComponents = progress.map {
            [String($0.completed), String($0.total), $0.unit ?? ""]
        } ?? ["", "", ""]
        let evidenceComponents = completionEvidence?.items.flatMap {
            [$0.kind.rawValue, $0.summary, $0.sourceID ?? ""]
        } ?? []
        let normalized = [
            source.rawValue,
            sourceEvent.lowercased(),
            sessionID,
            turnID ?? "",
            status.rawValue,
            summary.trimmingCharacters(in: .whitespacesAndNewlines)
        ] + progressComponents + evidenceComponents
        let fingerprintInput = normalized.joined(separator: "|")

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in fingerprintInput.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
