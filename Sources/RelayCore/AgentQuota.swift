import Darwin
import Foundation

public enum AgentQuotaAvailability: String, Codable, Sendable {
    case available
    case signInRequired = "sign_in_required"
    case unavailable
}

public struct AgentQuotaWindow: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var remainingPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(
        id: String,
        displayName: String,
        remainingPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.remainingPercent = min(max(remainingPercent, 0), 100)
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct AgentTokenUsageSnapshot: Codable, Equatable, Sendable {
    public var lifetimeTokens: Int64?
    public var latestDailyTokens: Int64?
    public var latestDailyStartDate: String?

    public init(
        lifetimeTokens: Int64? = nil,
        latestDailyTokens: Int64? = nil,
        latestDailyStartDate: String? = nil
    ) {
        self.lifetimeTokens = lifetimeTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.latestDailyTokens = latestDailyTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.latestDailyStartDate = Self.safeDate(latestDailyStartDate)
    }

    private static func safeDate(_ value: String?) -> String? {
        guard let value,
              value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }
}

/// A bounded, account-safe quota view. It intentionally excludes account email,
/// access tokens, raw CLI output, and backend identifiers.
public struct AgentQuotaSnapshot: Codable, Equatable, Sendable {
    public var source: AgentSource
    public var availability: AgentQuotaAvailability
    public var plan: String?
    public var windows: [AgentQuotaWindow]
    public var creditsRemaining: Double?
    public var creditsUnlimited: Bool
    public var tokenUsage: AgentTokenUsageSnapshot?
    public var refreshedAt: Date

    public init(
        source: AgentSource,
        availability: AgentQuotaAvailability,
        plan: String? = nil,
        windows: [AgentQuotaWindow] = [],
        creditsRemaining: Double? = nil,
        creditsUnlimited: Bool = false,
        tokenUsage: AgentTokenUsageSnapshot? = nil,
        refreshedAt: Date = Date()
    ) {
        self.source = source
        self.availability = availability
        self.plan = Self.safeLabel(plan, limit: 40)
        self.windows = Array(windows.prefix(10))
        self.creditsRemaining = creditsRemaining.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
        self.creditsUnlimited = creditsUnlimited
        self.tokenUsage = tokenUsage
        self.refreshedAt = refreshedAt
    }

    public var providerBalances: [ProviderBalanceSnapshot] {
        guard availability == .available else {
            return [ProviderBalanceSnapshot(
                providerID: source.rawValue,
                displayName: Self.sourceDisplayName(source),
                kind: .subscriptionQuota,
                state: availability == .signInRequired ? .signInRequired : .unavailable,
                refreshedAt: refreshedAt,
                dataSource: .localAgentInterface
            )].compactMap(\.self)
        }

        var balances = windows.compactMap { window in
            ProviderBalanceSnapshot(
                providerID: "\(source.rawValue):\(window.id)",
                displayName: window.displayName,
                kind: .subscriptionQuota,
                state: Self.state(for: window.remainingPercent),
                remaining: window.remainingPercent,
                limit: 100,
                unit: "%",
                resetsAt: window.resetsAt,
                refreshedAt: refreshedAt,
                dataSource: .localAgentInterface
            )
        }
        if let creditsRemaining {
            balances.append(ProviderBalanceSnapshot(
                providerID: "\(source.rawValue):credits",
                displayName: "\(Self.sourceDisplayName(source)) credits",
                kind: .apiCredit,
                state: creditsRemaining == 0 ? .exhausted : .normal,
                remaining: creditsRemaining,
                unit: "credits",
                refreshedAt: refreshedAt,
                dataSource: .localAgentInterface
            )!)
        }
        return balances
    }

    private static func state(for remainingPercent: Double) -> BalanceState {
        switch remainingPercent {
        case ...0: .exhausted
        case ...10: .low
        case ...25: .gettingLow
        default: .normal
        }
    }

    private static func sourceDisplayName(_ source: AgentSource) -> String {
        switch source {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .generic: "Agent"
        }
    }

    private static func safeLabel(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = value
            .unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F }
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }
}

public enum CodexQuotaProbeError: Error, Equatable, Sendable {
    case codexNotInstalled
    case signInRequired
    case timedOut
    case outputLimitExceeded
    case processFailed
    case malformedResponse
    case quotaUnavailable
}

public struct CodexQuotaProbeConfiguration: Sendable {
    public var executableURL: URL?
    public var totalTimeout: TimeInterval
    public var maximumOutputBytes: Int
    public var arguments: [String]

    public init(
        executableURL: URL? = nil,
        totalTimeout: TimeInterval = 8,
        maximumOutputBytes: Int = 256 * 1024,
        arguments: [String] = ["-s", "read-only", "-a", "untrusted", "app-server"]
    ) {
        self.executableURL = executableURL
        self.totalTimeout = max(0.1, totalTimeout)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
        self.arguments = arguments
    }
}

/// Reads Codex subscription usage through Codex's local app-server JSON-RPC.
/// The child process is fixed to read-only/untrusted mode and is always bounded
/// by a deadline and output cap. No shell, browser cookie, or auth file is used.
public struct CodexQuotaProbe: Sendable {
    public let configuration: CodexQuotaProbeConfiguration

    public init(configuration: CodexQuotaProbeConfiguration = .init()) {
        self.configuration = configuration
    }

    public func fetch(now: Date = Date()) async throws -> AgentQuotaSnapshot {
        let configuration = configuration
        return try await Task.detached(priority: .utility) {
            let executable = try Self.resolveExecutable(configuration.executableURL)
            let session = CodexQuotaRPCSession(
                executableURL: executable,
                arguments: configuration.arguments,
                maximumOutputBytes: configuration.maximumOutputBytes
            )
            return try session.fetch(deadline: Date().addingTimeInterval(configuration.totalTimeout), now: now)
        }.value
    }

    public static func decodeRateLimitsResult(
        _ data: Data,
        now: Date = Date()
    ) throws -> AgentQuotaSnapshot {
        let response: CodexRateLimitsResponse
        do {
            response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        } catch {
            throw CodexQuotaProbeError.malformedResponse
        }
        return try makeSnapshot(from: response, now: now)
    }

    public static func decodeTokenUsageResult(_ data: Data) throws -> AgentTokenUsageSnapshot {
        let response: CodexTokenUsageResponse
        do {
            response = try JSONDecoder().decode(CodexTokenUsageResponse.self, from: data)
        } catch {
            throw CodexQuotaProbeError.malformedResponse
        }
        let latest = response.dailyUsageBuckets?
            .filter { $0.tokens >= 0 }
            .max { $0.startDate < $1.startDate }
        return AgentTokenUsageSnapshot(
            lifetimeTokens: response.summary.lifetimeTokens,
            latestDailyTokens: latest?.tokens,
            latestDailyStartDate: latest?.startDate
        )
    }

    private static func makeSnapshot(
        from response: CodexRateLimitsResponse,
        now: Date
    ) throws -> AgentQuotaSnapshot {
        let primary = response.rateLimits
        var windows: [AgentQuotaWindow] = []
        appendWindows(from: primary, bucketID: "codex", bucketName: nil, to: &windows)

        let credits = primary.credits
        let balance = credits?.hasCredits == false
            ? nil
            : credits?.balance.flatMap(Self.flexibleDouble)
        let spendRemaining = primary.individualLimit?.remaining
        if windows.isEmpty, balance == nil, spendRemaining == nil,
           primary.planType == nil, credits?.unlimited != true {
            throw CodexQuotaProbeError.quotaUnavailable
        }

        if let spendRemaining {
            windows.append(AgentQuotaWindow(
                id: "spend",
                displayName: "Codex spend",
                remainingPercent: spendRemaining,
                resetsAt: date(primary.individualLimit?.resetsAt)
            ))
        }

        return AgentQuotaSnapshot(
            source: .codex,
            availability: .available,
            plan: primary.planType,
            windows: windows,
            creditsRemaining: balance,
            creditsUnlimited: credits?.unlimited == true,
            refreshedAt: now
        )
    }

    private static func appendWindows(
        from snapshot: CodexRateLimitSnapshot,
        bucketID: String,
        bucketName: String?,
        to windows: inout [AgentQuotaWindow]
    ) {
        let values = [("primary", snapshot.primary), ("secondary", snapshot.secondary)]
        for (role, window) in values {
            guard let window, window.usedPercent.isFinite else { continue }
            let windowID = "\(bucketID)-\(role)"
            let name = bucketName ?? defaultWindowName(minutes: window.windowDurationMinutes, role: role)
            windows.append(AgentQuotaWindow(
                id: windowID,
                displayName: name,
                remainingPercent: 100 - window.usedPercent,
                windowMinutes: window.windowDurationMinutes,
                resetsAt: date(window.resetsAt)
            ))
        }
    }

    private static func defaultWindowName(minutes: Int?, role: String) -> String {
        guard let minutes else { return role == "primary" ? "Codex session" : "Codex weekly" }
        if minutes == 300 { return "Codex 5h" }
        if minutes == 10_080 { return "Codex weekly" }
        if minutes % 1_440 == 0 { return "Codex \(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "Codex \(minutes / 60)h" }
        return "Codex \(minutes)m"
    }

    private static func date(_ timestamp: Int?) -> Date? {
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private static func flexibleDouble(_ value: String) -> Double? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = Double(normalized), result.isFinite, result >= 0 else { return nil }
        return result
    }

    private static func resolveExecutable(_ explicit: URL?) throws -> URL {
        if let explicit {
            guard FileManager.default.isExecutableFile(atPath: explicit.path) else {
                throw CodexQuotaProbeError.codexNotInstalled
            }
            return explicit
        }

        let environment = ProcessInfo.processInfo.environment
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixedCandidates = [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        guard let executable = (pathCandidates + fixedCandidates).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CodexQuotaProbeError.codexNotInstalled
        }
        return executable
    }
}

private struct CodexRateLimitsResponse: Decodable {
    var rateLimits: CodexRateLimitSnapshot
    var rateLimitsByLimitID: [String: CodexRateLimitSnapshot]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
        case rateLimitsByLimitIDSnake = "rate_limits_by_limit_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try container.decode(CodexRateLimitSnapshot.self, forKey: .rateLimits)
        rateLimitsByLimitID = (try? container.decodeIfPresent(
            [String: CodexRateLimitSnapshot].self,
            forKey: .rateLimitsByLimitID
        )) ?? (try? container.decodeIfPresent(
            [String: CodexRateLimitSnapshot].self,
            forKey: .rateLimitsByLimitIDSnake
        ))
    }
}

private struct CodexRateLimitSnapshot: Decodable {
    var limitID: String?
    var limitName: String?
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var credits: CodexCreditsSnapshot?
    var individualLimit: CodexSpendLimit?
    var planType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitIDSnake = "limit_id"
        case limitName
        case limitNameSnake = "limit_name"
        case primary
        case secondary
        case credits
        case individualLimit
        case individualLimitSnake = "individual_limit"
        case planType
        case planTypeSnake = "plan_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitID = (try? container.decodeIfPresent(String.self, forKey: .limitID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .limitIDSnake))
        limitName = (try? container.decodeIfPresent(String.self, forKey: .limitName))
            ?? (try? container.decodeIfPresent(String.self, forKey: .limitNameSnake))
        primary = try? container.decodeIfPresent(CodexRateLimitWindow.self, forKey: .primary)
        secondary = try? container.decodeIfPresent(CodexRateLimitWindow.self, forKey: .secondary)
        credits = try? container.decodeIfPresent(CodexCreditsSnapshot.self, forKey: .credits)
        individualLimit = (try? container.decodeIfPresent(CodexSpendLimit.self, forKey: .individualLimit))
            ?? (try? container.decodeIfPresent(CodexSpendLimit.self, forKey: .individualLimitSnake))
        planType = (try? container.decodeIfPresent(String.self, forKey: .planType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .planTypeSnake))
    }
}

private struct CodexRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMinutes: Int?
    var resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case usedPercentSnake = "used_percent"
        case windowDurationMinutes = "windowDurationMins"
        case windowDurationMinutesSnake = "window_duration_mins"
        case resetsAt
        case resetsAtSnake = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let usedPercent = container.decodeFlexibleDouble(
            forKeys: [.usedPercent, .usedPercentSnake]
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .usedPercent,
                in: container,
                debugDescription: "Missing used percent"
            )
        }
        self.usedPercent = usedPercent
        windowDurationMinutes = container.decodeFlexibleInt(
            forKeys: [.windowDurationMinutes, .windowDurationMinutesSnake]
        )
        resetsAt = container.decodeFlexibleInt(forKeys: [.resetsAt, .resetsAtSnake])
    }
}

private struct CodexCreditsSnapshot: Decodable {
    var balance: String?
    var hasCredits: Bool?
    var unlimited: Bool

    enum CodingKeys: String, CodingKey {
        case balance
        case hasCredits
        case unlimited
    }
}

private struct CodexTokenUsageResponse: Decodable {
    var summary: Summary
    var dailyUsageBuckets: [DailyBucket]?

    struct Summary: Decodable {
        var lifetimeTokens: Int64?
    }

    struct DailyBucket: Decodable {
        var startDate: String
        var tokens: Int64
    }
}

private struct CodexSpendLimit: Decodable {
    var limit: Double?
    var used: Double?
    var remainingPercent: Double?
    var resetsAt: Int?

    var remaining: Double? {
        if let remainingPercent, remainingPercent.isFinite {
            return min(max(remainingPercent, 0), 100)
        }
        guard let limit, limit > 0, let used else { return nil }
        return min(max(100 - (used / limit * 100), 0), 100)
    }

    enum CodingKeys: String, CodingKey {
        case limit
        case used
        case remainingPercent
        case remainingPercentSnake = "remaining_percent"
        case resetsAt
        case resetsAtSnake = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = container.decodeFlexibleDouble(forKeys: [.limit])
        used = container.decodeFlexibleDouble(forKeys: [.used])
        remainingPercent = container.decodeFlexibleDouble(
            forKeys: [.remainingPercent, .remainingPercentSnake]
        )
        resetsAt = container.decodeFlexibleInt(forKeys: [.resetsAt, .resetsAtSnake])
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDouble(forKeys keys: [Key]) -> Double? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
            if let text = try? decodeIfPresent(String.self, forKey: key),
               let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }

    func decodeFlexibleInt(forKeys keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
            if let text = try? decodeIfPresent(String.self, forKey: key),
               let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }
}

private final class CodexQuotaRPCSession: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let maximumOutputBytes: Int
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let condition = NSCondition()
    private var lines: [Data] = []
    private var deferredMessages: [[String: Any]] = []
    private var buffer = Data()
    private var outputByteCount = 0
    private var exceededOutputLimit = false
    private var processTerminated = false

    init(executableURL: URL, arguments: [String], maximumOutputBytes: Int) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.maximumOutputBytes = maximumOutputBytes
    }

    func fetch(deadline: Date, now: Date) throws -> AgentQuotaSnapshot {
        try start()
        defer { shutdown() }

        try send(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "notch-relay", "version": "1"]
        ])
        _ = try response(id: 1, deadline: deadline)
        try sendNotification(method: "initialized")
        try send(id: 2, method: "account/rateLimits/read", params: [:])
        try? send(id: 3, method: "account/usage/read", params: [:])
        let message = try response(id: 2, deadline: deadline)

        if message["error"] != nil {
            throw classifyRemoteError(message)
        }
        guard let result = message["result"], JSONSerialization.isValidJSONObject(result) else {
            throw CodexQuotaProbeError.malformedResponse
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        var snapshot = try CodexQuotaProbe.decodeRateLimitsResult(data, now: now)

        do {
            let usageMessage = try response(id: 3, deadline: deadline)
            if usageMessage["error"] == nil,
               let usageResult = usageMessage["result"],
               JSONSerialization.isValidJSONObject(usageResult) {
                let usageData = try JSONSerialization.data(withJSONObject: usageResult)
                snapshot.tokenUsage = try CodexQuotaProbe.decodeTokenUsageResult(usageData)
            }
        } catch {
            // Token usage is useful context but must never make a valid quota snapshot fail.
        }
        return snapshot
    }

    private func start() throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            condition.lock()
            processTerminated = true
            condition.broadcast()
            condition.unlock()
        }

        do {
            try process.run()
        } catch {
            throw CodexQuotaProbeError.processFailed
        }
    }

    private func receive(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !data.isEmpty else {
            processTerminated = true
            condition.broadcast()
            return
        }
        outputByteCount += data.count
        guard outputByteCount <= maximumOutputBytes else {
            exceededOutputLimit = true
            condition.broadcast()
            if process.isRunning { process.terminate() }
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        condition.broadcast()
    }

    private func response(id: Int, deadline: Date) throws -> [String: Any] {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if exceededOutputLimit { throw CodexQuotaProbeError.outputLimitExceeded }
            if let index = deferredMessages.firstIndex(where: {
                Self.messageID($0["id"]) == id
            }) {
                return deferredMessages.remove(at: index)
            }
            while !lines.isEmpty {
                let line = lines.removeFirst()
                guard let object = try? JSONSerialization.jsonObject(with: line),
                      let message = object as? [String: Any] else { continue }
                if Self.messageID(message["id"]) == id { return message }
                deferredMessages.append(message)
            }
            if processTerminated || !process.isRunning {
                throw CodexQuotaProbeError.processFailed
            }
            guard Date() < deadline else {
                if process.isRunning { process.terminate() }
                throw CodexQuotaProbeError.timedOut
            }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
    }

    private func send(id: Int, method: String, params: [String: Any]) throws {
        try write(["id": id, "method": method, "params": params])
    }

    private func sendNotification(method: String) throws {
        try write(["method": method, "params": [:]])
    }

    private func write(_ object: [String: Any]) throws {
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexQuotaProbeError.processFailed
        }
    }

    private func classifyRemoteError(_ message: [String: Any]) -> CodexQuotaProbeError {
        guard let error = message["error"] as? [String: Any] else { return .processFailed }
        let code = error["code"] as? Int
        let description = (error["message"] as? String)?.lowercased() ?? ""
        let requiresAuthentication = description.contains("authentication required")
            || description.contains("sign in required")
        return code == -32_000 || code == 401 || requiresAuthentication
            ? .signInRequired
            : .quotaUnavailable
    }

    private func shutdown() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let until = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < until {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private static func messageID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
