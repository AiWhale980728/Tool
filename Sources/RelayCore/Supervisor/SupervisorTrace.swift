import Foundation

public struct SupervisorTraceContext: Codable, Equatable, Sendable {
    public var traceID: SupervisorTraceID
    public var loopType: SupervisorLoopType
    public var task: SupervisorTaskIdentity
    public var contextVersion: String
    public var policyVersion: String
    public var createdAt: Date

    public init(
        traceID: SupervisorTraceID = SupervisorTraceID(),
        loopType: SupervisorLoopType,
        task: SupervisorTaskIdentity,
        contextVersion: String,
        policyVersion: String,
        createdAt: Date
    ) {
        self.traceID = traceID
        self.loopType = loopType
        self.task = task
        self.contextVersion = contextVersion
        self.policyVersion = policyVersion
        self.createdAt = createdAt
    }
}
