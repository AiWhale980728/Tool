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
                shouldNotify: false,
                shouldPlaySound: !focusModeEnabled,
                reason: "Evidence-backed completion is shown in Notch Relay"
            )
        case .readyToReview:
            AttentionDecision(
                level: .passive,
                shouldNotify: false,
                shouldPlaySound: false,
                reason: "Review-ready result is shown in Notch Relay"
            )
        case .needsInput:
            AttentionDecision(
                level: .interrupt,
                shouldNotify: false,
                shouldPlaySound: false,
                reason: "Input request is shown in Notch Relay"
            )
        case .needsPermission:
            AttentionDecision(
                level: .interrupt,
                shouldNotify: false,
                shouldPlaySound: false,
                reason: "Permission request is shown in Notch Relay"
            )
        case .failed:
            AttentionDecision(
                level: .critical,
                shouldNotify: false,
                shouldPlaySound: false,
                reason: "Failure is shown in Notch Relay"
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
