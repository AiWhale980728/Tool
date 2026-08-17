import Foundation

public enum TransientMessageKind: String, Codable, Sendable {
    case notice
    case success
    case error
}

/// One source of truth for every temporary interaction in the desktop app.
/// Values are deliberately bounded so a temporary surface can never become
/// permanent because a call site forgot to provide a timeout.
public struct InteractionTimingPolicy: Equatable, Sendable {
    public var noticeMessage: TimeInterval
    public var successMessage: TimeInterval
    public var errorMessage: TimeInterval
    public var launcherHint: TimeInterval
    public var launcherGreetingDelay: TimeInterval
    public var launcherGreetingDuration: TimeInterval
    public var workbenchIdle: TimeInterval
    public var settingsMaximum: TimeInterval
    public var completionSoundMaximum: TimeInterval
    public var acceptanceApplicationMaximum: TimeInterval
    public var standardAnimation: TimeInterval
    public var hoverAnimation: TimeInterval

    public init(
        noticeMessage: TimeInterval = 4,
        successMessage: TimeInterval = 3,
        errorMessage: TimeInterval = 7,
        launcherHint: TimeInterval = 2,
        launcherGreetingDelay: TimeInterval = 0.7,
        launcherGreetingDuration: TimeInterval = 1.6,
        workbenchIdle: TimeInterval = 60,
        settingsMaximum: TimeInterval = 120,
        completionSoundMaximum: TimeInterval = 1.5,
        acceptanceApplicationMaximum: TimeInterval = 300,
        standardAnimation: TimeInterval = 0.18,
        hoverAnimation: TimeInterval = 0.14
    ) {
        self.noticeMessage = noticeMessage
        self.successMessage = successMessage
        self.errorMessage = errorMessage
        self.launcherHint = launcherHint
        self.launcherGreetingDelay = launcherGreetingDelay
        self.launcherGreetingDuration = launcherGreetingDuration
        self.workbenchIdle = workbenchIdle
        self.settingsMaximum = settingsMaximum
        self.completionSoundMaximum = completionSoundMaximum
        self.acceptanceApplicationMaximum = acceptanceApplicationMaximum
        self.standardAnimation = standardAnimation
        self.hoverAnimation = hoverAnimation
    }

    public static let production = InteractionTimingPolicy()

    public func messageDuration(for kind: TransientMessageKind) -> TimeInterval {
        switch kind {
        case .notice: noticeMessage
        case .success: successMessage
        case .error: errorMessage
        }
    }
}
