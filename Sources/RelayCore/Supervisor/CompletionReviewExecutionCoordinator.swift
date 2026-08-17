import Foundation

public enum CompletionReviewExecutionGuardFailure: Error, Equatable, Sendable {
    case duplicateRequest
    case concurrencyLimit
    case rateLimit
    case circuitOpen
}

public struct CompletionReviewExecutionPermit: Equatable, Sendable {
    fileprivate var id: UUID
    fileprivate var providerID: String
    fileprivate var taskKey: String
    fileprivate var traceID: SupervisorTraceID
}

public actor CompletionReviewExecutionCoordinator {
    public let maximumConcurrentPerProvider: Int
    public let maximumStartsPerWindow: Int
    public let window: TimeInterval
    public let failureThreshold: Int
    public let circuitOpenDuration: TimeInterval

    private var active: [UUID: CompletionReviewExecutionPermit] = [:]
    private var starts: [String: [Date]] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var circuitOpenUntil: [String: Date] = [:]

    public init(
        maximumConcurrentPerProvider: Int = 2,
        maximumStartsPerWindow: Int = 10,
        window: TimeInterval = 60,
        failureThreshold: Int = 3,
        circuitOpenDuration: TimeInterval = 60
    ) {
        self.maximumConcurrentPerProvider = max(1, maximumConcurrentPerProvider)
        self.maximumStartsPerWindow = max(1, maximumStartsPerWindow)
        self.window = min(max(1, window), 300)
        self.failureThreshold = max(1, failureThreshold)
        self.circuitOpenDuration = min(max(1, circuitOpenDuration), 300)
    }

    public func begin(
        input: CompletionReviewInput,
        provider: SupervisorModelDescriptor,
        now: Date = Date()
    ) -> Result<CompletionReviewExecutionPermit, CompletionReviewExecutionGuardFailure> {
        prune(now: now)
        let taskKey = "\(input.task.source.rawValue):\(input.task.sessionID):\(input.task.triggerEventID.uuidString)"
        if active.values.contains(where: {
            $0.traceID == input.traceID || $0.taskKey == taskKey
        }) {
            return .failure(.duplicateRequest)
        }
        if circuitOpenUntil[provider.providerID].map({ $0 > now }) == true {
            return .failure(.circuitOpen)
        }
        if active.values.filter({ $0.providerID == provider.providerID }).count
            >= maximumConcurrentPerProvider {
            return .failure(.concurrencyLimit)
        }
        if starts[provider.providerID, default: []].count >= maximumStartsPerWindow {
            return .failure(.rateLimit)
        }

        let permit = CompletionReviewExecutionPermit(
            id: UUID(),
            providerID: provider.providerID,
            taskKey: taskKey,
            traceID: input.traceID
        )
        active[permit.id] = permit
        starts[provider.providerID, default: []].append(now)
        return .success(permit)
    }

    public func finish(
        _ permit: CompletionReviewExecutionPermit,
        providerSucceeded: Bool,
        countFailure: Bool = true,
        now: Date = Date()
    ) {
        guard active.removeValue(forKey: permit.id) != nil else { return }
        if providerSucceeded {
            consecutiveFailures[permit.providerID] = 0
            circuitOpenUntil.removeValue(forKey: permit.providerID)
        } else if countFailure {
            let count = consecutiveFailures[permit.providerID, default: 0] + 1
            consecutiveFailures[permit.providerID] = count
            if count >= failureThreshold {
                circuitOpenUntil[permit.providerID] = now.addingTimeInterval(circuitOpenDuration)
            }
        }
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        starts = starts.reduce(into: [:]) { result, entry in
            let current = entry.value.filter { $0 > cutoff }
            if !current.isEmpty { result[entry.key] = current }
        }
        circuitOpenUntil = circuitOpenUntil.filter { $0.value > now }
    }
}
