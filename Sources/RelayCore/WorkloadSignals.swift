import Foundation

public enum BalanceKind: String, Codable, CaseIterable, Sendable {
    case subscriptionQuota = "subscription_quota"
    case requestLimit = "request_limit"
    case tokenLimit = "token_limit"
    case apiCredit = "api_credit"
}

public enum BalanceState: String, Codable, CaseIterable, Sendable {
    case normal
    case gettingLow = "getting_low"
    case low
    case exhausted
    case unavailable
    case signInRequired = "sign_in_required"
    case stale
}

public enum BalanceDataSource: String, Codable, CaseIterable, Sendable {
    case documentedLocalInterface = "documented_local_interface"
    case localAgentInterface = "local_agent_interface"
    case officialAPI = "official_api"
    case localAccounting = "local_accounting"
    case manual
}

public struct ProviderBalanceSnapshot: Codable, Equatable, Sendable {
    public var providerID: String
    public var displayName: String
    public var kind: BalanceKind
    public var state: BalanceState
    public var remaining: Double?
    public var limit: Double?
    public var unit: String?
    public var resetsAt: Date?
    public var refreshedAt: Date
    public var dataSource: BalanceDataSource

    public init?(
        providerID: String,
        displayName: String,
        kind: BalanceKind,
        state: BalanceState,
        remaining: Double? = nil,
        limit: Double? = nil,
        unit: String? = nil,
        resetsAt: Date? = nil,
        refreshedAt: Date = Date(),
        dataSource: BalanceDataSource
    ) {
        guard let providerID = Self.label(providerID, limit: 120),
              let displayName = Self.label(displayName, limit: 120),
              Self.validNumber(remaining, allowZero: true),
              Self.validNumber(limit, allowZero: false) else { return nil }
        self.providerID = providerID
        self.displayName = displayName
        self.kind = kind
        self.state = state
        self.remaining = remaining
        self.limit = limit
        self.unit = unit.flatMap { Self.label($0, limit: 40) }
        self.resetsAt = resetsAt
        self.refreshedAt = refreshedAt
        self.dataSource = dataSource
    }

    public var fractionRemaining: Double? {
        guard let remaining, let limit, limit > 0 else { return nil }
        return min(max(remaining / limit, 0), 1)
    }

    public func effectiveState(
        now: Date = Date(),
        staleAfter: TimeInterval = 15 * 60
    ) -> BalanceState {
        guard state != .unavailable, state != .signInRequired else { return state }
        return now.timeIntervalSince(refreshedAt) > staleAfter ? .stale : state
    }

    private static func validNumber(_ value: Double?, allowZero: Bool) -> Bool {
        guard let value else { return true }
        return value.isFinite && (allowZero ? value >= 0 : value > 0)
    }

    private static func label(_ value: String, limit: Int) -> String? {
        let printable = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        let normalized = printable
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }
}

public enum ThermalPressure: String, Codable, CaseIterable, Sendable {
    case cool
    case warm
    case hot
    case coolingNeeded = "cooling_needed"
    case unavailable
}

public struct SystemWorkloadSnapshot: Codable, Equatable, Sendable {
    public var thermalPressure: ThermalPressure
    public var cpuUtilization: Double?
    public var memoryPressure: Double?
    public var batteryLevel: Double?
    public var isCharging: Bool?
    public var localActiveTaskCount: Int?
    public var sampledAt: Date

    public init(
        thermalPressure: ThermalPressure,
        cpuUtilization: Double? = nil,
        memoryPressure: Double? = nil,
        batteryLevel: Double? = nil,
        isCharging: Bool? = nil,
        localActiveTaskCount: Int? = nil,
        sampledAt: Date = Date()
    ) {
        self.thermalPressure = thermalPressure
        self.cpuUtilization = Self.fraction(cpuUtilization)
        self.memoryPressure = Self.fraction(memoryPressure)
        self.batteryLevel = Self.fraction(batteryLevel)
        self.isCharging = isCharging
        self.localActiveTaskCount = localActiveTaskCount.flatMap { $0 >= 0 ? $0 : nil }
        self.sampledAt = sampledAt
    }

    private static func fraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
}

public struct MacSystemWorkloadReader {
    public init() {}

    public func read(now: Date = Date()) -> SystemWorkloadSnapshot {
        SystemWorkloadSnapshot(
            thermalPressure: Self.thermalPressure(from: ProcessInfo.processInfo.thermalState),
            sampledAt: now
        )
    }

    public static func thermalPressure(
        from state: ProcessInfo.ThermalState
    ) -> ThermalPressure {
        switch state {
        case .nominal: .cool
        case .fair: .warm
        case .serious: .hot
        case .critical: .coolingNeeded
        @unknown default: .unavailable
        }
    }
}
