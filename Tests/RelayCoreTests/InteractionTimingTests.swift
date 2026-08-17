import Foundation
import Testing
@testable import RelayCore

@Suite("Interaction timing policy")
struct InteractionTimingTests {
    @Test
    func everyTemporarySurfaceHasAPositiveFiniteLimit() {
        let policy = InteractionTimingPolicy.production
        let limits = [
            policy.noticeMessage,
            policy.successMessage,
            policy.errorMessage,
            policy.launcherHint,
            policy.launcherGreetingDelay,
            policy.launcherGreetingDuration,
            policy.workbenchIdle,
            policy.settingsMaximum,
            policy.completionSoundMaximum,
            policy.acceptanceApplicationMaximum,
            policy.standardAnimation,
            policy.hoverAnimation
        ]

        #expect(limits.allSatisfy { $0.isFinite && $0 > 0 })
        #expect(policy.messageDuration(for: .notice) == policy.noticeMessage)
        #expect(policy.messageDuration(for: .success) == policy.successMessage)
        #expect(policy.messageDuration(for: .error) == policy.errorMessage)
        #expect(policy.standardAnimation <= 0.2)
        #expect(policy.hoverAnimation <= 0.2)
    }
}
