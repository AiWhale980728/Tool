import Foundation

public enum WorkbenchHero: Equatable, Sendable {
    case needsAttention(sessionKey: String, additionalCount: Int)
    case failed(sessionKey: String, additionalCount: Int)
    case readyToReview(sessionKey: String, additionalCount: Int)
    case completed(sessionKey: String, additionalCount: Int)
    case allClear(activeTaskCount: Int)
    case awaitOrders
}

public struct WorkbenchTask: Equatable, Sendable {
    public var session: RelaySessionState
    public var cleanup: RelayCleanupState
    public var attentionLevel: TaskAttentionLevel

    public init(
        session: RelaySessionState,
        cleanup: RelayCleanupState,
        attentionLevel: TaskAttentionLevel = .normal
    ) {
        self.session = session
        self.cleanup = cleanup
        self.attentionLevel = attentionLevel
    }

    public var canConfirmCompletion: Bool {
        session.status == .readyToReview
    }
}

public struct WorkbenchAgentGroup: Equatable, Sendable {
    public var source: AgentSource
    public var tasks: [WorkbenchTask]
    public var totalTaskCount: Int

    public init(
        source: AgentSource,
        tasks: [WorkbenchTask],
        totalTaskCount: Int
    ) {
        self.source = source
        self.tasks = tasks
        self.totalTaskCount = totalTaskCount
    }
}

public struct WorkbenchProjection: Equatable, Sendable {
    public var hero: WorkbenchHero
    public var agentGroups: [WorkbenchAgentGroup]
    public var finishedTodayCount: Int
    public var nextCleanupAt: Date?
    public var cleanupReminderCount: Int
    public var balances: [ProviderBalanceSnapshot]
    public var systemWorkload: SystemWorkloadSnapshot?

    public init(
        snapshot: RelaySnapshot,
        retainedSnapshot: RelaySnapshot? = nil,
        connectedSources: Set<AgentSource> = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        retentionPolicy: RelayRetentionPolicy = RelayRetentionPolicy(),
        completionHeroDuration: TimeInterval = 8,
        balances: [ProviderBalanceSnapshot] = [],
        systemWorkload: SystemWorkloadSnapshot? = nil,
        attentionLevels: [String: TaskAttentionLevel] = [:]
    ) {
        self.balances = balances.sorted {
            if $0.displayName == $1.displayName { return $0.providerID < $1.providerID }
            return $0.displayName < $1.displayName
        }
        self.systemWorkload = systemWorkload
        let taskBySource = Dictionary(grouping: snapshot.sessions.values, by: \.source)
        let visibleSources = Set(snapshot.sessions.values.map(\.source)).union(connectedSources)
        agentGroups = visibleSources
            .sorted { Self.sourceOrder($0) < Self.sourceOrder($1) }
            .map { source in
                let sourceSessions = (taskBySource[source] ?? []).sorted {
                    Self.taskPrecedes($0, $1, attentionLevels: attentionLevels)
                }
                let tasks = sourceSessions.map {
                        WorkbenchTask(
                            session: $0,
                            cleanup: snapshot.cleanupState(
                                for: $0.key,
                                now: now,
                                policy: retentionPolicy
                            ),
                            attentionLevel: attentionLevels[$0.key] ?? .normal
                        )
                    }
                return WorkbenchAgentGroup(
                    source: source,
                    tasks: tasks,
                    totalTaskCount: sourceSessions.count
                )
            }

        let currentSessions = Array(snapshot.sessions.values)
        let retainedSessions = Array((retainedSnapshot ?? snapshot).sessions.values)
        hero = Self.hero(
            for: currentSessions,
            now: now,
            completionHeroDuration: completionHeroDuration
        )
        finishedTodayCount = retainedSessions.filter {
            guard $0.status.isFinishedWorkbenchRecord,
                  let terminalAt = $0.terminalAt else { return false }
            return calendar.isDate(terminalAt, inSameDayAs: now)
        }.count

        let cleanupSnapshot = retainedSnapshot ?? snapshot
        let cleanupStates = retainedSessions.map {
            cleanupSnapshot.cleanupState(for: $0.key, now: now, policy: retentionPolicy)
        }
        nextCleanupAt = cleanupStates.compactMap { state in
            switch state {
            case .scheduled(let removalAt), .approaching(let removalAt), .expired(let removalAt):
                removalAt
            case .notScheduled:
                nil
            }
        }.min()
        cleanupReminderCount = cleanupStates.filter {
            if case .approaching = $0 { return true }
            return false
        }.count
    }

    private static func hero(
        for sessions: [RelaySessionState],
        now: Date,
        completionHeroDuration: TimeInterval
    ) -> WorkbenchHero {
        let ordered = sessions.sorted(by: taskPrecedes)
        let attention = ordered.filter { $0.status.requiresAttention }
        if let first = attention.first {
            return first.status == .failed
                ? .failed(sessionKey: first.key, additionalCount: attention.count - 1)
                : .needsAttention(sessionKey: first.key, additionalCount: attention.count - 1)
        }

        let review = ordered.filter { $0.status == .readyToReview }
        if let first = review.first {
            return .readyToReview(sessionKey: first.key, additionalCount: review.count - 1)
        }

        let completed = ordered.filter {
            guard $0.status == .completed, let terminalAt = $0.terminalAt else { return false }
            let age = now.timeIntervalSince(terminalAt)
            return age >= 0 && age <= completionHeroDuration
        }
        if let first = completed.first {
            return .completed(sessionKey: first.key, additionalCount: completed.count - 1)
        }

        let activeCount = ordered.filter { $0.status == .running }.count
        return activeCount > 0 ? .allClear(activeTaskCount: activeCount) : .awaitOrders
    }

    private static func taskPrecedes(_ lhs: RelaySessionState, _ rhs: RelaySessionState) -> Bool {
        taskPrecedes(lhs, rhs, attentionLevels: [:])
    }

    private static func taskPrecedes(
        _ lhs: RelaySessionState,
        _ rhs: RelaySessionState,
        attentionLevels: [String: TaskAttentionLevel]
    ) -> Bool {
        let leftAttention = (attentionLevels[lhs.key] ?? .normal).sortOrder
        let rightAttention = (attentionLevels[rhs.key] ?? .normal).sortOrder
        if leftAttention != rightAttention { return leftAttention < rightAttention }
        let leftPriority = taskPriority(lhs.status)
        let rightPriority = taskPriority(rhs.status)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        if lhs.lastEventAt != rhs.lastEventAt { return lhs.lastEventAt > rhs.lastEventAt }
        return lhs.key < rhs.key
    }

    private static func taskPriority(_ status: RelayStatus) -> Int {
        switch status {
        case .needsPermission, .needsInput: 0
        case .failed: 1
        case .readyToReview: 2
        case .running: 3
        case .completed: 4
        case .cancelled: 5
        case .ended: 6
        }
    }

    private static func sourceOrder(_ source: AgentSource) -> Int {
        switch source {
        case .codex: 0
        case .claude: 1
        case .cursor: 2
        case .generic: 3
        }
    }
}
