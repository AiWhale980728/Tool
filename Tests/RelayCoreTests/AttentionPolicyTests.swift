import Testing
@testable import RelayCore

@Suite("Attention policy")
struct AttentionPolicyTests {
    @Test
    func testOnlyBlockingStatesInterrupt() {
        #expect(AttentionPolicy.level(for: .running) == .silent)
        #expect(AttentionPolicy.level(for: .readyToReview) == .passive)
        #expect(AttentionPolicy.level(for: .completed) == .passive)
        #expect(AttentionPolicy.level(for: .needsInput) == .interrupt)
        #expect(AttentionPolicy.level(for: .needsPermission) == .interrupt)
        #expect(AttentionPolicy.level(for: .failed) == .critical)
        #expect(AttentionPolicy.level(for: .cancelled) == .silent)
        #expect(AttentionPolicy.level(for: .ended) == .silent)
    }

    @Test
    func testOnlyEvidenceBackedCompletionMayPlaySound() {
        let input = AttentionPolicy.decision(for: .needsInput, focusModeEnabled: true)
        #expect(input.shouldNotify)
        #expect(!input.shouldPlaySound)

        let permission = AttentionPolicy.decision(for: .needsPermission, focusModeEnabled: false)
        #expect(permission.shouldNotify)
        #expect(!permission.shouldPlaySound)

        let failure = AttentionPolicy.decision(for: .failed, focusModeEnabled: true)
        #expect(failure.shouldNotify)
        #expect(!failure.shouldPlaySound)

        let review = AttentionPolicy.decision(for: .readyToReview, focusModeEnabled: false)
        #expect(review.shouldNotify)
        #expect(!review.shouldPlaySound)

        let completed = AttentionPolicy.decision(for: .completed, focusModeEnabled: false)
        #expect(completed.shouldNotify)
        #expect(completed.shouldPlaySound)

        let focusedCompletion = AttentionPolicy.decision(for: .completed, focusModeEnabled: true)
        #expect(!focusedCompletion.shouldNotify)
        #expect(!focusedCompletion.shouldPlaySound)
    }
}
