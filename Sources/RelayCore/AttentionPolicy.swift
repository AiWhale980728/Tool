import Foundation

public struct AttentionDecision: Equatable, Sendable {
    public var level: AttentionLevel
    public var shouldNotify: Bool
    public var shouldPlaySound: Bool
    public var reason: String

    public init(
        level: AttentionLevel,
        shouldNotify: Bool,
        shouldPlaySound: Bool,
        reason: String
    ) {
        self.level = level
        self.shouldNotify = shouldNotify
        self.shouldPlaySound = shouldPlaySound
        self.reason = reason
    }
}

public enum AttentionPolicy {
    public static func level(for status: RelayStatus) -> AttentionLevel {
        switch status {
        case .running, .cancelled, .ended:
            .silent
        case .readyToReview, .completed:
            .passive
        case .needsInput, .needsPermission:
            .interrupt
        case .failed:
            .critical
        }
    }

    public static func decision(for status: RelayStatus, focusModeEnabled: Bool) -> AttentionDecision {
        switch status {
        case .running:
            AttentionDecision(
                level: .silent,
                shouldNotify: false,
                shouldPlaySound: false,
                reason: "Agent is still running"
            )
        case .completed:
            AttentionDecision(
                level: .passive,
                shouldNotify: !focusModeEnabled,
                shouldPlaySound: !focusModeEnabled,
                reason: "Evidence-backed completion is ready"
            )
        case .readyToReview:
            AttentionDecision(
                level: .passive,
                shouldNotify: !focusModeEnabled,
                shouldPlaySound: false,
                reason: "Agent stopped and the result is ready to review"
            )
        case .needsInput:
            AttentionDecision(
                level: .interrupt,
                shouldNotify: true,
                shouldPlaySound: false,
                reason: "Agent cannot continue without user input"
            )
        case .needsPermission:
            AttentionDecision(
                level: .interrupt,
                shouldNotify: true,
                shouldPlaySound: false,
                reason: "Agent is waiting for an explicit permission decision"
            )
        case .failed:
            AttentionDecision(
                level: .critical,
                shouldNotify: true,
                shouldPlaySound: false,
                reason: "Agent failed and may require recovery"
            )
        case .cancelled:
            AttentionDecision(
                level: .silent,
                shouldNotify: false,
                shouldPlaySound: false,
                reason: "Task was cancelled"
            )
        case .ended:
            AttentionDecision(
                level: .silent,
                shouldNotify: false,
                shouldPlaySound: false,
                reason: "Session lifecycle ended"
            )
        }
    }
}
