import AppKit
import Combine
import Foundation
import RelayCore
import UniformTypeIdentifiers

struct CompletionReviewArtifactSelection: Equatable {
    var triggerEventID: UUID
    var urls: [URL]
    var descriptors: [CompletionArtifactDescriptor]
}

@MainActor
final class WorkbenchViewModel: ObservableObject {
    @Published private(set) var snapshot = RelaySnapshot()
    @Published private(set) var projection = WorkbenchProjection(snapshot: RelaySnapshot())
    @Published private(set) var connectedSources: Set<AgentSource> = []
    @Published private(set) var taskMetadata: [String: LocalTaskMetadata] = [:]
    @Published private(set) var taskAttentionLevels: [String: TaskAttentionLevel] = [:]
    @Published private(set) var confirmationPending: Set<String> = []
    @Published private(set) var completionReviewDrafts: [String: CompletionReviewDraft] = [:]
    @Published private(set) var completionReviews: [String: StoredCompletionReview] = [:]
    @Published private(set) var completionReviewConsentInputs: [String: CompletionReviewInput] = [:]
    @Published private(set) var completionReviewPending: Set<String> = []
    @Published private(set) var completionReviewGitHubCIEnabled: Set<String> = []
    @Published private(set) var completionReviewLocalSwiftEnabled: Set<String> = []
    @Published private(set) var completionReviewLocalPythonEnabled: Set<String> = []
    @Published private(set) var completionReviewLocalPytestEnabled: Set<String> = []
    @Published private(set) var completionReviewLocalJestEnabled: Set<String> = []
    @Published private(set) var completionReviewLocalCargoNextestEnabled: Set<String> = []
    @Published private(set) var completionReviewArtifactSelections: [
        String: CompletionReviewArtifactSelection
    ] = [:]
    @Published private(set) var completionReviewResetTokens: [String: UUID] = [:]
    @Published var supervisorEnabled: Bool
    @Published var supervisorModelID: String
    @Published var independentEvaluatorEnabled: Bool
    @Published var independentEvaluatorModelID: String
    @Published private(set) var hasSupervisorAPIKey = false
    @Published var selectedSessionKey: String?
    @Published var selectedSource: AgentSource?
    @Published var message: WorkbenchMessage?
    @Published var isShowingSettings = false
    @Published private(set) var telemetrySummary = RelayTelemetrySummary()
    @Published private(set) var quotaSnapshots: [AgentSource: AgentQuotaSnapshot] = [:]
    @Published private(set) var codexCurrentTaskAvailability: CodexCurrentTaskAvailability = .checking

    private let root: URL
    private let stateStore: RelayStateStore
    private let confirmation: UserCompletionConfirmation
    private let taskAttentionStore: LocalTaskAttentionStore
    private let completionReviewStore: CompletionReviewRuntimeStore
    private let completionEvidenceStore: CompletionEvidenceStore
    private let completionReviewExecutionCoordinator = CompletionReviewExecutionCoordinator()
    private let telemetryStore: LocalTelemetryStore
    private let timing: InteractionTimingPolicy
    private let taskMetadataResolver = LocalTaskMetadataResolver.defaults()
    private let terminalTaskTitleResolver = TerminalTaskTitleResolver()
    private var refreshTimer: Timer?
    private var messageDismissTask: Task<Void, Never>?
    private var messageTelemetryEnabled = true
    private var completionReviewDecisions: [CompletionReviewHumanDecision] = []
    private var completionReviewOutcomes: [CompletionReviewOutcome] = []
    private var quotaProbeTask: Task<Void, Never>?
    private var lastQuotaProbeAt: Date?
    private var codexCurrentTaskProbeTask: Task<Void, Never>?
    private var lastCodexCurrentTaskProbeAt: Date?
    private var codexCurrentTaskObservation = CodexCurrentTaskObservation()
    private var presentationSessions: [String: RelaySessionState] = [:]
    private var processIDsBySessionKey: [String: Int32] = [:]
    private let quotaRefreshInterval: TimeInterval = 5 * 60
    private let codexCurrentTaskRefreshInterval: TimeInterval = 2

    init(
        root: URL? = nil,
        timing: InteractionTimingPolicy = .production
    ) {
        let defaults = UserDefaults.standard
        supervisorEnabled = defaults.object(forKey: SupervisorPreferences.enabledKey) == nil
            ? false
            : defaults.bool(forKey: SupervisorPreferences.enabledKey)
        supervisorModelID = defaults.string(forKey: SupervisorPreferences.modelIDKey)
            ?? SupervisorPreferences.defaultModelID
        independentEvaluatorEnabled = defaults.object(
            forKey: SupervisorPreferences.independentEvaluatorEnabledKey
        ) == nil ? false : defaults.bool(forKey: SupervisorPreferences.independentEvaluatorEnabledKey)
        independentEvaluatorModelID = defaults.string(
            forKey: SupervisorPreferences.independentEvaluatorModelIDKey
        ) ?? SupervisorPreferences.defaultIndependentEvaluatorModelID
        hasSupervisorAPIKey = SupervisorAPIKeyStore.load() != nil
        let resolvedRoot: URL
        do {
            resolvedRoot = try root ?? RelayStorePaths.defaultRoot()
        } catch {
            resolvedRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("NotchRelayUnavailable", isDirectory: true)
        }
        self.root = resolvedRoot
        self.timing = timing
        let paths = RelayStorePaths(root: resolvedRoot)
        stateStore = RelayStateStore(paths: paths)
        confirmation = UserCompletionConfirmation(root: resolvedRoot)
        taskAttentionStore = LocalTaskAttentionStore(root: resolvedRoot)
        completionReviewStore = CompletionReviewRuntimeStore(root: resolvedRoot)
        completionEvidenceStore = CompletionEvidenceStore(root: resolvedRoot)
        telemetryStore = LocalTelemetryStore(root: resolvedRoot)
        if var runtime = try? completionReviewStore.load() {
            runtime.pruneExpired()
            completionReviewDrafts = runtime.drafts
            completionReviews = runtime.reviews
            completionReviewDecisions = runtime.decisions
            completionReviewOutcomes = runtime.outcomes
            try? completionReviewStore.persist(runtime)
        }
        _ = try? completionEvidenceStore.pruneExpired()
        recordTelemetry(.appLaunched, surface: .app, outcome: .started)
        refresh()
    }

    func start() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
        refreshAgentQuotasIfNeeded(force: true)
        refreshCodexCurrentTasksIfNeeded(force: true)
    }

    func refresh(now: Date = Date()) {
        pruneCompletionReviewRuntime(now: now)
        do {
            let loaded = try stateStore.load()
            let codexObservation = codexCurrentTaskObservation.resolve(now: now)
            codexCurrentTaskAvailability = codexObservation.availability
            let codexReconciliation = CodexCurrentTaskPresentation.reconcile(
                snapshot: loaded,
                currentTasks: codexObservation.tasks,
                now: now
            )
            let reconciledSnapshot = codexReconciliation.snapshot
            let detectedSources = Self.detectConnectedSources(snapshot: reconciledSnapshot)
            let metadataResolution = taskMetadataResolver.resolveSnapshot(
                sessions: Array(reconciledSnapshot.sessions.values)
            )
            var resolvedMetadata = metadataResolution.metadata
            resolvedMetadata.merge(codexReconciliation.metadata) { _, current in current }
            var currentSessionKeys = metadataResolution.currentSessionKeys
            currentSessionKeys.formUnion(codexReconciliation.currentSessionKeys)
            var authoritativeCurrentSources = metadataResolution.authoritativeCurrentSources
            if codexReconciliation.isAuthoritative {
                authoritativeCurrentSources.insert(.codex)
            }
            let terminalTitles = terminalTaskTitleResolver.resolve(
                processIDsBySessionKey: metadataResolution.processIDsBySessionKey,
                now: now
            )
            for (sessionKey, title) in terminalTitles {
                let existing = resolvedMetadata[sessionKey]
                resolvedMetadata[sessionKey] = LocalTaskMetadata(
                    projectName: existing?.projectName,
                    taskTitle: title,
                    showsProjectPrefix: false
                )
            }
            var presentationSnapshot = reconciledSnapshot
            presentationSnapshot.sessions = reconciledSnapshot.sessions.filter { key, session in
                LocalTaskPresentation.shouldDisplay(
                    session: session,
                    metadata: resolvedMetadata[key],
                    currentSessionKeys: currentSessionKeys,
                    authoritativeCurrentSources: authoritativeCurrentSources
                )
            }
            snapshot = loaded
            presentationSessions = presentationSnapshot.sessions
            let reconciledOutcomes = CompletionReviewOutcomeRecorder.reconcile(
                decisions: completionReviewDecisions,
                sessions: loaded.sessions,
                existing: completionReviewOutcomes,
                now: now
            )
            if reconciledOutcomes != completionReviewOutcomes {
                completionReviewOutcomes = reconciledOutcomes
                persistCompletionReviewRuntime()
            }
            connectedSources = detectedSources
            taskMetadata = resolvedMetadata
            processIDsBySessionKey = metadataResolution.processIDsBySessionKey
            taskAttentionLevels = taskAttentionStore.load()
            try? taskAttentionStore.prune(keeping: Set(presentationSnapshot.sessions.keys))
            projection = WorkbenchProjection(
                snapshot: presentationSnapshot,
                retainedSnapshot: loaded,
                connectedSources: detectedSources,
                now: now,
                balances: quotaSnapshots.values.flatMap(\.providerBalances),
                systemWorkload: MacSystemWorkloadReader().read(now: now),
                attentionLevels: taskAttentionLevels
            )
            confirmationPending = confirmationPending.filter { key in
                loaded.sessions[key]?.status == .readyToReview
            }
            completionReviewPending = completionReviewPending.filter { key in
                loaded.sessions[key]?.status == .readyToReview
            }
            completionReviewGitHubCIEnabled = completionReviewGitHubCIEnabled.filter { key in
                loaded.sessions[key]?.status == .readyToReview
            }
            completionReviewLocalSwiftEnabled = completionReviewLocalSwiftEnabled.filter { key in
                loaded.sessions[key]?.status == .readyToReview
            }
            completionReviewLocalPythonEnabled = completionReviewLocalPythonEnabled.filter { key in
                loaded.sessions[key]?.status == .readyToReview
            }
            completionReviewLocalPytestEnabled = completionReviewLocalPytestEnabled.filter { key in
                loaded.sessions[key]?.status == .readyToReview
            }
            completionReviewLocalJestEnabled = completionReviewLocalJestEnabled.filter { key in
                loaded.sessions[key]?.status == .readyToReview
            }
            completionReviewLocalCargoNextestEnabled = completionReviewLocalCargoNextestEnabled.filter { key in
                loaded.sessions[key]?.status == .readyToReview
            }
            completionReviewArtifactSelections = completionReviewArtifactSelections.filter {
                key, selection in
                guard let session = loaded.sessions[key] else { return false }
                return session.status == .readyToReview
                    && session.lastEventID == selection.triggerEventID
            }
            completionReviewConsentInputs = completionReviewConsentInputs.filter { key, input in
                guard let session = loaded.sessions[key] else { return false }
                return session.status == .readyToReview
                    && session.lastEventID == input.task.triggerEventID
                    && input.expiresAt > now
            }

            let availableSources = Set(projection.agentGroups.map(\.source))
            let heroKey = Self.heroSessionKey(in: projection)
            let heroSource = heroKey.flatMap { presentationSnapshot.sessions[$0]?.source }
            if selectedSource.map({ availableSources.contains($0) }) != true {
                selectedSource = heroSource ?? projection.agentGroups.first?.source
            }

            let selectedGroup = projection.agentGroups.first { $0.source == selectedSource }
            let selectedSourceSessionKeys = Set(selectedGroup?.tasks.map(\.session.key) ?? [])
            if let selectedSessionKey, !selectedSourceSessionKeys.contains(selectedSessionKey) {
                self.selectedSessionKey = nil
            }
            if self.selectedSessionKey == nil {
                if let heroKey,
                   presentationSnapshot.sessions[heroKey]?.source == selectedSource,
                   selectedSourceSessionKeys.contains(heroKey) {
                    self.selectedSessionKey = heroKey
                } else {
                    self.selectedSessionKey = selectedGroup?.tasks.first?.session.key
                }
            }
            if let selectedSessionKey = self.selectedSessionKey,
               let selectedSession = loaded.sessions[selectedSessionKey],
               selectedSession.status == .readyToReview {
                ensureCompletionReviewDraft(for: selectedSession)
            }
            refreshAgentQuotasIfNeeded(now: now)
            refreshCodexCurrentTasksIfNeeded(now: now)
        } catch {
            showMessage(WorkbenchMessage(
                kind: .error,
                text: "无法读取 Relay 状态；Agent 中的工作未被更改。"
            ))
        }
    }

    func refreshCodexCurrentTasksIfNeeded(now: Date = Date(), force: Bool = false) {
        guard codexCurrentTaskProbeTask == nil else { return }
        if !force, let lastCodexCurrentTaskProbeAt,
           now.timeIntervalSince(lastCodexCurrentTaskProbeAt) < codexCurrentTaskRefreshInterval {
            return
        }
        lastCodexCurrentTaskProbeAt = now
        codexCurrentTaskProbeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tasks = try await CodexCurrentTaskProbe().fetch(now: now)
                guard !Task.isCancelled else { return }
                self.codexCurrentTaskObservation.recordSuccess(tasks, at: Date())
            } catch {
                guard !Task.isCancelled else { return }
                self.codexCurrentTaskObservation.recordFailure(at: Date())
            }
            self.codexCurrentTaskProbeTask = nil
            self.refresh()
        }
    }

    func refreshCurrentAgentTasks() {
        refreshCodexCurrentTasksIfNeeded(force: true)
    }

    func refreshAgentQuotasIfNeeded(now: Date = Date(), force: Bool = false) {
        guard quotaProbeTask == nil else { return }
        if !force, let lastQuotaProbeAt,
           now.timeIntervalSince(lastQuotaProbeAt) < quotaRefreshInterval {
            return
        }
        lastQuotaProbeAt = now
        let startedAt = Date()
        recordTelemetry(.quotaProbeStarted, surface: .quota, outcome: .started)
        quotaProbeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await CodexQuotaProbe().fetch(now: now)
                guard !Task.isCancelled else { return }
                self.quotaSnapshots[.codex] = snapshot
                self.recordTelemetry(
                    .quotaProbeFinished,
                    surface: .quota,
                    outcome: .succeeded,
                    duration: RelayTelemetryDurationBucket(
                        seconds: Date().timeIntervalSince(startedAt)
                    )
                )
            } catch let error as CodexQuotaProbeError {
                guard !Task.isCancelled else { return }
                self.quotaSnapshots[.codex] = AgentQuotaSnapshot(
                    source: .codex,
                    availability: error == .signInRequired ? .signInRequired : .unavailable,
                    refreshedAt: now
                )
                self.recordTelemetry(
                    .quotaProbeFinished,
                    surface: .quota,
                    outcome: .failed,
                    duration: RelayTelemetryDurationBucket(
                        seconds: Date().timeIntervalSince(startedAt)
                    )
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.quotaSnapshots[.codex] = AgentQuotaSnapshot(
                    source: .codex,
                    availability: .unavailable,
                    refreshedAt: now
                )
                self.recordTelemetry(
                    .quotaProbeFinished,
                    surface: .quota,
                    outcome: .failed,
                    duration: RelayTelemetryDurationBucket(
                        seconds: Date().timeIntervalSince(startedAt)
                    )
                )
            }
            self.quotaProbeTask = nil
            self.refresh()
        }
    }

    func select(_ sessionKey: String) {
        dismissTaskScopedMessage(ifItDoesNotBelongTo: sessionKey)
        selectedSessionKey = sessionKey
        selectedSource = presentationSessions[sessionKey]?.source
    }

    func selectAgent(_ source: AgentSource) {
        selectedSource = source
        let nextSessionKey = projection.agentGroups
            .first(where: { $0.source == source })?
            .tasks.first?.session.key
        dismissTaskScopedMessage(ifItDoesNotBelongTo: nextSessionKey)
        selectedSessionKey = nextSessionKey
    }

    func setAttentionLevel(_ level: TaskAttentionLevel, for sessionKey: String) {
        guard presentationSessions[sessionKey] != nil else {
            showMessage(WorkbenchMessage(kind: .notice, text: "此任务已不可用。"))
            return
        }

        do {
            try taskAttentionStore.set(level, for: sessionKey)
            taskAttentionLevels[sessionKey] = level
            refresh()
        } catch {
            showMessage(WorkbenchMessage(
                kind: .error,
                text: "无法保存任务优先级；Agent 中的任务未被更改。"
            ))
        }
    }

    func attentionLevel(for sessionKey: String) -> TaskAttentionLevel {
        taskAttentionLevels[sessionKey] ?? .normal
    }

    func confirmComplete(sessionKey: String) {
        guard !confirmationPending.contains(sessionKey),
              let session = snapshot.sessions[sessionKey],
              session.status == .readyToReview else {
            showMessage(WorkbenchMessage(
                kind: .notice,
                text: "结果已发生变化，请先检查 Agent 的最新活动。"
            ))
            refresh()
            return
        }

        do {
            confirmationPending.insert(sessionKey)
            try confirmation.enqueue(
                sessionKey: sessionKey,
                expectedLastEventID: session.lastEventID
            )
            recordCompletionReviewDecision(
                session: session,
                kind: .confirmedComplete
            )
            _ = try? RelayProcessor(root: root).processPending()
            showMessage(
                WorkbenchMessage(kind: .success, text: "已在这台 Mac 上标记为完成。")
            )
            CompletionSoundPlayer.playIfEnabled(maximumDuration: timing.completionSoundMaximum) {
                [weak self] name, outcome in
                self?.recordTelemetry(name, surface: .sound, outcome: outcome)
            }
            refresh()
        } catch {
            confirmationPending.remove(sessionKey)
            showMessage(WorkbenchMessage(
                kind: .error,
                text: "Agent 出现了新活动，请检查最新结果后重新确认。"
            ))
            refresh()
        }
    }

    func completionReviewDraft(for session: RelaySessionState) -> CompletionReviewDraft {
        ensureCompletionReviewDraft(for: session)
        return completionReviewDrafts[session.key] ?? CompletionReviewDraft(
            goal: displayTitle(for: session),
            acceptanceCriteria: ["交付结果满足当前任务目标。"]
        )
    }

    func updateCompletionReviewGoal(_ value: String, for session: RelaySessionState) {
        guard acceptCompletionReviewText(value) else { return }
        let existing = completionReviewDraft(for: session)
        let updated = CompletionReviewDraft(
            goal: value,
            acceptanceCriteria: existing.acceptanceCriteria,
            resultSummary: existing.resultSummary,
            updatedAt: Date()
        )
        completionReviewDrafts[session.key] = updated
        completionReviews.removeValue(forKey: session.key)
        completionReviewConsentInputs.removeValue(forKey: session.key)
        persistCompletionReviewRuntime()
    }

    func updateCompletionReviewCriteria(_ value: String, for session: RelaySessionState) {
        guard acceptCompletionReviewText(value) else { return }
        let existing = completionReviewDraft(for: session)
        let criteria = value
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let updated = CompletionReviewDraft(
            goal: existing.goal,
            acceptanceCriteria: criteria,
            resultSummary: existing.resultSummary,
            updatedAt: Date()
        )
        completionReviewDrafts[session.key] = updated
        completionReviews.removeValue(forKey: session.key)
        completionReviewConsentInputs.removeValue(forKey: session.key)
        persistCompletionReviewRuntime()
    }

    func updateCompletionReviewResultSummary(_ value: String, for session: RelaySessionState) {
        guard acceptCompletionReviewText(value) else { return }
        let existing = completionReviewDraft(for: session)
        let updated = CompletionReviewDraft(
            goal: existing.goal,
            acceptanceCriteria: existing.acceptanceCriteria,
            resultSummary: value,
            updatedAt: Date()
        )
        completionReviewDrafts[session.key] = updated
        completionReviews.removeValue(forKey: session.key)
        completionReviewConsentInputs.removeValue(forKey: session.key)
        persistCompletionReviewRuntime()
    }

    private func acceptCompletionReviewText(_ value: String) -> Bool {
        guard SupervisorSensitiveTextScanner.scan(value).isEmpty else {
            showMessage(WorkbenchMessage(
                kind: .error,
                text: "AI 检查字段不能保存凭据或源代码。"
            ))
            return false
        }
        return true
    }

    func completionReview(for session: RelaySessionState, now: Date = Date()) -> StoredCompletionReview? {
        guard let review = completionReviews[session.key], review.isCurrent(for: session, now: now) else {
            return nil
        }
        return review
    }

    func completionReviewConsent(
        for session: RelaySessionState,
        now: Date = Date()
    ) -> CompletionReviewInput? {
        guard let input = completionReviewConsentInputs[session.key],
              input.task.triggerEventID == session.lastEventID,
              input.expiresAt > now,
              input.consent?.confirmedAt == nil else { return nil }
        return input
    }

    func includesGitHubCIEvidence(for sessionKey: String) -> Bool {
        completionReviewGitHubCIEnabled.contains(sessionKey)
    }

    func setIncludesGitHubCIEvidence(_ enabled: Bool, for sessionKey: String) {
        if enabled {
            completionReviewGitHubCIEnabled.insert(sessionKey)
        } else {
            completionReviewGitHubCIEnabled.remove(sessionKey)
        }
        completionReviews.removeValue(forKey: sessionKey)
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
    }

    func supportsLocalSwiftVerification(for session: RelaySessionState) -> Bool {
        LocalSwiftVerificationEvidenceAdapter.supports(session)
    }

    func includesLocalSwiftVerification(for sessionKey: String) -> Bool {
        completionReviewLocalSwiftEnabled.contains(sessionKey)
    }

    func setIncludesLocalSwiftVerification(_ enabled: Bool, for sessionKey: String) {
        if enabled {
            completionReviewLocalSwiftEnabled.insert(sessionKey)
        } else {
            completionReviewLocalSwiftEnabled.remove(sessionKey)
        }
        completionReviews.removeValue(forKey: sessionKey)
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
    }

    func supportsLocalPythonVerification(for session: RelaySessionState) -> Bool {
        LocalPythonVerificationEvidenceAdapter.supports(session)
    }

    func includesLocalPythonVerification(for sessionKey: String) -> Bool {
        completionReviewLocalPythonEnabled.contains(sessionKey)
    }

    func setIncludesLocalPythonVerification(_ enabled: Bool, for sessionKey: String) {
        if enabled {
            completionReviewLocalPythonEnabled.insert(sessionKey)
        } else {
            completionReviewLocalPythonEnabled.remove(sessionKey)
        }
        completionReviews.removeValue(forKey: sessionKey)
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
    }

    func supportsLocalPytestVerification(for session: RelaySessionState) -> Bool {
        LocalPytestVerificationEvidenceAdapter.supports(session)
    }

    func includesLocalPytestVerification(for sessionKey: String) -> Bool {
        completionReviewLocalPytestEnabled.contains(sessionKey)
    }

    func setIncludesLocalPytestVerification(_ enabled: Bool, for sessionKey: String) {
        if enabled {
            completionReviewLocalPytestEnabled.insert(sessionKey)
        } else {
            completionReviewLocalPytestEnabled.remove(sessionKey)
        }
        completionReviews.removeValue(forKey: sessionKey)
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
    }

    func supportsLocalJestVerification(for session: RelaySessionState) -> Bool {
        LocalJestVerificationEvidenceAdapter.supports(session)
    }

    func includesLocalJestVerification(for sessionKey: String) -> Bool {
        completionReviewLocalJestEnabled.contains(sessionKey)
    }

    func setIncludesLocalJestVerification(_ enabled: Bool, for sessionKey: String) {
        if enabled {
            completionReviewLocalJestEnabled.insert(sessionKey)
        } else {
            completionReviewLocalJestEnabled.remove(sessionKey)
        }
        completionReviews.removeValue(forKey: sessionKey)
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
    }

    func supportsLocalCargoNextestVerification(for session: RelaySessionState) -> Bool {
        LocalCargoNextestVerificationEvidenceAdapter.supports(session)
    }

    func includesLocalCargoNextestVerification(for sessionKey: String) -> Bool {
        completionReviewLocalCargoNextestEnabled.contains(sessionKey)
    }

    func setIncludesLocalCargoNextestVerification(_ enabled: Bool, for sessionKey: String) {
        if enabled {
            completionReviewLocalCargoNextestEnabled.insert(sessionKey)
        } else {
            completionReviewLocalCargoNextestEnabled.remove(sessionKey)
        }
        completionReviews.removeValue(forKey: sessionKey)
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
    }

    func completionReviewArtifactSummaries(for sessionKey: String) -> [String] {
        completionReviewArtifactSelections[sessionKey]?.descriptors.map(\.disclosureSummary) ?? []
    }

    func selectCompletionReviewArtifacts(for sessionKey: String) {
        guard !completionReviewPending.contains(sessionKey),
              let session = snapshot.sessions[sessionKey],
              session.status == .readyToReview,
              let cwd = session.project.cwd else {
            showMessage(WorkbenchMessage(
                kind: .notice,
                text: "选择交付物需要当前任务的工作区。"
            ))
            return
        }

        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .json, .zip]
        panel.prompt = "选择"
        guard panel.runModal() == .OK else { return }

        let existing = completionReviewArtifactSelections[sessionKey]?.urls ?? []
        var unique: [URL] = []
        var paths: Set<String> = []
        for url in existing + panel.urls {
            let normalized = url.standardizedFileURL
            if paths.insert(normalized.path).inserted { unique.append(normalized) }
        }
        guard unique.count <= ArtifactCompletionEvidenceAdapter.maximumArtifactCount else {
            showMessage(WorkbenchMessage(
                kind: .notice,
                text: "每次复核最多选择 8 个交付物。"
            ))
            return
        }

        completionReviewPending.insert(sessionKey)
        let workspaceRoot = URL(fileURLWithPath: cwd, isDirectory: true)
        let resetToken = completionReviewResetTokens[sessionKey]
        Task { [weak self] in
            guard let self else { return }
            defer { self.completionReviewPending.remove(sessionKey) }
            let descriptors: [CompletionArtifactDescriptor]?
            do {
                descriptors = try await ArtifactCompletionEvidenceAdapter().inspectAsync(
                    selectedURLs: unique,
                    workspaceRoot: workspaceRoot
                )
            } catch {
                descriptors = nil
            }
            guard self.snapshot.sessions[sessionKey]?.lastEventID == session.lastEventID,
                  self.completionReviewResetTokens[sessionKey] == resetToken else {
                return
            }
            guard let descriptors else {
                self.showMessage(WorkbenchMessage(
                    kind: .error,
                    text: "只能使用任务工作区内有效的 PDF、PNG、JPEG、JSON 或 ZIP 文件。"
                ))
                return
            }
            self.completionReviewArtifactSelections[sessionKey] = CompletionReviewArtifactSelection(
                triggerEventID: session.lastEventID,
                urls: unique,
                descriptors: descriptors
            )
            self.completionReviews.removeValue(forKey: sessionKey)
            self.completionReviewConsentInputs.removeValue(forKey: sessionKey)
        }
    }

    func removeCompletionReviewArtifact(at index: Int, for sessionKey: String) {
        guard var selection = completionReviewArtifactSelections[sessionKey],
              selection.urls.indices.contains(index),
              selection.descriptors.indices.contains(index) else { return }
        selection.urls.remove(at: index)
        selection.descriptors.remove(at: index)
        if selection.urls.isEmpty {
            completionReviewArtifactSelections.removeValue(forKey: sessionKey)
        } else {
            completionReviewArtifactSelections[sessionKey] = selection
        }
        completionReviews.removeValue(forKey: sessionKey)
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
    }

    func prepareCompletionReviewConsent(for sessionKey: String) {
        guard !completionReviewPending.contains(sessionKey),
              let session = snapshot.sessions[sessionKey],
              session.status == .readyToReview else {
            showMessage(WorkbenchMessage(kind: .notice, text: "此复核目标已不是最新状态。"))
            return
        }
        #if DEBUG
        let usesAcceptanceProvider = ProcessInfo.processInfo
            .environment["NOTCH_RELAY_ACCEPTANCE_PROVIDER"] == "1"
        #else
        let usesAcceptanceProvider = false
        #endif
        guard supervisorEnabled || usesAcceptanceProvider else {
            openSettings()
            showMessage(WorkbenchMessage(kind: .notice, text: "请在“连接与隐私”中允许 AI 检查交付结果。"))
            return
        }
        let modelID = supervisorModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty || usesAcceptanceProvider else {
            openSettings()
            showMessage(WorkbenchMessage(kind: .notice, text: "开始 AI 检查前请先选择模型。"))
            return
        }

        let providerDescriptor: SupervisorModelDescriptor
        let independentEvaluatorDescriptor: SupervisorModelDescriptor?
        #if DEBUG
        if usesAcceptanceProvider {
            providerDescriptor = AcceptanceCompletionReviewProvider().descriptor
            independentEvaluatorDescriptor = nil
        } else {
            providerDescriptor = OpenAICompletionReviewProvider.modelDescriptor(modelID: modelID)
            independentEvaluatorDescriptor = configuredIndependentEvaluatorDescriptor(
                supervisorModelID: modelID
            )
        }
        #else
        providerDescriptor = OpenAICompletionReviewProvider.modelDescriptor(modelID: modelID)
        independentEvaluatorDescriptor = configuredIndependentEvaluatorDescriptor(
            supervisorModelID: modelID
        )
        #endif
        if independentEvaluatorEnabled && independentEvaluatorDescriptor == nil && !usesAcceptanceProvider {
            openSettings()
            showMessage(WorkbenchMessage(
                kind: .notice,
                text: "请为独立评估器选择另一个模型。"
            ))
            return
        }

        let draft = completionReviewDraft(for: session)
        guard draft.isUsable else {
            showMessage(WorkbenchMessage(
                kind: .notice,
                text: "请填写任务目标和至少一条验收条件。"
            ))
            return
        }
        let includesGitHubCI = includesGitHubCIEvidence(for: sessionKey)
        let includesLocalSwift = includesLocalSwiftVerification(for: sessionKey)
        let includesLocalPython = includesLocalPythonVerification(for: sessionKey)
        let includesLocalPytest = includesLocalPytestVerification(for: sessionKey)
        let includesLocalJest = includesLocalJestVerification(for: sessionKey)
        let includesLocalCargoNextest = includesLocalCargoNextestVerification(for: sessionKey)
        let selectedArtifactURLs = completionReviewArtifactSelections[sessionKey]?.urls ?? []
        let resetToken = completionReviewResetTokens[sessionKey]

        completionReviewPending.insert(sessionKey)
        Task { [weak self] in
            guard let self else { return }
            defer { self.completionReviewPending.remove(sessionKey) }
            var collectedEvidence = await GitCompletionEvidenceAdapter().collect(for: session)
            if includesLocalSwift {
                collectedEvidence.append(contentsOf:
                    await LocalSwiftVerificationEvidenceAdapter().collect(for: session)
                )
            }
            if includesLocalPython {
                collectedEvidence.append(contentsOf:
                    await LocalPythonVerificationEvidenceAdapter().collect(for: session)
                )
            }
            if includesLocalPytest {
                collectedEvidence.append(contentsOf:
                    await LocalPytestVerificationEvidenceAdapter().collect(for: session)
                )
            }
            if includesLocalJest {
                collectedEvidence.append(contentsOf:
                    await LocalJestVerificationEvidenceAdapter().collect(for: session)
                )
            }
            if includesLocalCargoNextest {
                collectedEvidence.append(contentsOf:
                    await LocalCargoNextestVerificationEvidenceAdapter().collect(for: session)
                )
            }
            if includesGitHubCI {
                let expectedHead = collectedEvidence
                    .first(where: { $0.kind == .gitState })?
                    .reference?
                    .replacingOccurrences(of: "git:", with: "")
                let ciEvidence = await GitHubCICompletionEvidenceAdapter().collect(
                    for: session,
                    expectedHeadCommit: expectedHead
                )
                collectedEvidence.append(contentsOf: ciEvidence)
            }
            if !selectedArtifactURLs.isEmpty {
                guard let artifactEvidence = await ArtifactCompletionEvidenceAdapter().collect(
                    selectedURLs: selectedArtifactURLs,
                    for: session
                ), artifactEvidence.count == selectedArtifactURLs.count else {
                    self.showMessage(WorkbenchMessage(
                        kind: .error,
                        text: "已选择的交付物发生变化或已失效，请在复核前重新选择。"
                    ))
                    return
                }
                collectedEvidence.append(contentsOf: artifactEvidence)
            }
            guard self.snapshot.sessions[sessionKey]?.lastEventID == session.lastEventID,
                  self.completionReviewDrafts[sessionKey]?.revision == draft.revision,
                  (self.completionReviewArtifactSelections[sessionKey]?.urls ?? [])
                    == selectedArtifactURLs,
                  self.completionReviewResetTokens[sessionKey] == resetToken else {
                self.showMessage(WorkbenchMessage(
                    kind: .notice,
                    text: "任务或复核上下文已变化，请重新检查最新数据。"
                ))
                return
            }

            let independentEvidence: [CompletionReviewEvidenceObservation]
            do {
                independentEvidence = try self.completionEvidenceStore.record(
                    collectedEvidence,
                    for: session
                )
            } catch {
                independentEvidence = collectedEvidence
            }

            let input: CompletionReviewInput
            do {
                input = try CompletionReviewInputBuilder.build(
                    session: session,
                    draft: draft,
                    provider: providerDescriptor,
                    independentEvaluatorProvider: independentEvaluatorDescriptor,
                    consentConfirmedAt: nil,
                    additionalEvidence: independentEvidence
                )
            } catch {
                self.showMessage(WorkbenchMessage(
                    kind: .error,
                    text: "无法安全构建复核上下文。"
                ))
                return
            }

            self.completionReviews.removeValue(forKey: sessionKey)
            self.completionReviewConsentInputs[sessionKey] = input
            self.recordTelemetry(.reviewContextPrepared, surface: .supervisor, outcome: .succeeded)
        }
    }

    func cancelCompletionReviewConsent(for sessionKey: String) {
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
    }

    func runCompletionReview(for sessionKey: String) {
        guard !completionReviewPending.contains(sessionKey),
              let session = snapshot.sessions[sessionKey],
              session.status == .readyToReview,
              var input = completionReviewConsentInputs[sessionKey],
              input.task.triggerEventID == session.lastEventID,
              input.expiresAt > Date(),
              input.consent?.confirmedAt == nil else {
            prepareCompletionReviewConsent(for: sessionKey)
            return
        }

        #if DEBUG
        let usesAcceptanceProvider = ProcessInfo.processInfo
            .environment["NOTCH_RELAY_ACCEPTANCE_PROVIDER"] == "1"
        #else
        let usesAcceptanceProvider = false
        #endif

        let modelID = supervisorModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveProvider: OpenAICompletionReviewProvider?
        let liveIndependentEvaluator: OpenAIIndependentCompletionReviewEvaluator?
        let providerDescriptor: SupervisorModelDescriptor
        #if DEBUG
        if usesAcceptanceProvider {
            liveProvider = nil
            liveIndependentEvaluator = nil
            providerDescriptor = AcceptanceCompletionReviewProvider().descriptor
        } else {
            guard let promptPack = SupervisorPrivatePromptPack.load() else {
                showMessage(WorkbenchMessage(
                    kind: .notice,
                    text: "私有 Prompt Pack 未安装，未发送 AI 请求。"
                ))
                return
            }
            guard let apiKey = SupervisorAPIKeyStore.load() else {
                openSettings()
                showMessage(WorkbenchMessage(kind: .notice, text: "开始 AI 检查前请先添加 API 密钥。"))
                return
            }
            let provider = OpenAICompletionReviewProvider(
                apiKey: apiKey,
                modelID: modelID,
                systemPrompt: promptPack.completionReviewSystemPrompt
            )
            liveProvider = provider
            providerDescriptor = provider.descriptor
            liveIndependentEvaluator = input.consent?.independentEvaluatorProvider.map {
                OpenAIIndependentCompletionReviewEvaluator(
                    apiKey: apiKey,
                    modelID: $0.modelID,
                    systemPrompt: promptPack.independentEvaluatorSystemPrompt
                )
            }
        }
        #else
        guard let promptPack = SupervisorPrivatePromptPack.load() else {
            showMessage(WorkbenchMessage(
                kind: .notice,
                text: "私有 Prompt Pack 未安装，未发送 AI 请求。"
            ))
            return
        }
        guard let apiKey = SupervisorAPIKeyStore.load() else {
            openSettings()
            showMessage(WorkbenchMessage(kind: .notice, text: "开始 AI 检查前请先添加 API 密钥。"))
            return
        }
        let provider = OpenAICompletionReviewProvider(
            apiKey: apiKey,
            modelID: modelID,
            systemPrompt: promptPack.completionReviewSystemPrompt
        )
        liveProvider = provider
        providerDescriptor = provider.descriptor
        liveIndependentEvaluator = input.consent?.independentEvaluatorProvider.map {
            OpenAIIndependentCompletionReviewEvaluator(
                apiKey: apiKey,
                modelID: $0.modelID,
                systemPrompt: promptPack.independentEvaluatorSystemPrompt
            )
        }
        #endif

        guard input.consent?.provider == providerDescriptor,
              input.consent?.independentEvaluatorProvider == liveIndependentEvaluator?.descriptor else {
            completionReviewConsentInputs.removeValue(forKey: sessionKey)
            showMessage(WorkbenchMessage(
                kind: .notice,
                text: "模型配置已变化，请检查更新后的数据披露。"
            ))
            return
        }
        input.consent?.confirmedAt = Date()
        completionReviewConsentInputs.removeValue(forKey: sessionKey)

        completionReviewPending.insert(sessionKey)
        let resetToken = completionReviewResetTokens[sessionKey]
        let providerStartedAt = Date()
        recordTelemetry(.providerStarted, surface: .supervisor, outcome: .started)
        Task { [weak self] in
            guard let self else { return }
            let executor = CompletionReviewExecutor(
                policy: .liveShadow(approvedProviderIDs: [providerDescriptor.providerID])
            )
            let evaluator = DeterministicCompletionReviewEvaluator()
            let result: CompletionReviewExecutionResult
            #if DEBUG
            if usesAcceptanceProvider {
                result = await executor.execute(
                    input: input,
                    using: AcceptanceCompletionReviewProvider(),
                    evaluator: evaluator,
                    coordinator: completionReviewExecutionCoordinator
                )
            } else if let liveProvider {
                result = await executor.execute(
                    input: input,
                    using: liveProvider,
                    evaluator: evaluator,
                    coordinator: completionReviewExecutionCoordinator
                )
            } else {
                return
            }
            #else
            guard let liveProvider else { return }
            result = await executor.execute(
                input: input,
                using: liveProvider,
                evaluator: evaluator,
                coordinator: completionReviewExecutionCoordinator
            )
            #endif
            guard self.snapshot.sessions[sessionKey]?.lastEventID == input.task.triggerEventID,
                  self.completionReviewResetTokens[sessionKey] == resetToken else {
                self.completionReviewPending.remove(sessionKey)
                if self.completionReviewResetTokens[sessionKey] == resetToken {
                    self.showMessage(WorkbenchMessage(
                        kind: .notice,
                        text: "Agent 出现了新活动，旧的 AI 检查结果已被丢弃。"
                    ))
                }
                self.recordTelemetry(.staleReviewDiscarded, surface: .supervisor, outcome: .stale)
                return
            }

            let duration = RelayTelemetryDurationBucket(
                seconds: Date().timeIntervalSince(providerStartedAt)
            )

            switch result {
            case .shadowAssessment(
                let assessment,
                let evaluatorResult,
                let policyDecision,
                let providerReceipt
            ):
                let independentEvaluation: StoredIndependentCompletionReviewEvaluation?
                if let liveIndependentEvaluator {
                    independentEvaluation = await IndependentCompletionReviewEvaluatorExecutor().execute(
                        input: input,
                        assessment: assessment,
                        using: liveIndependentEvaluator,
                        coordinator: completionReviewExecutionCoordinator
                    )
                } else {
                    independentEvaluation = nil
                }
                guard self.snapshot.sessions[sessionKey]?.lastEventID == input.task.triggerEventID,
                      self.completionReviewResetTokens[sessionKey] == resetToken else {
                    self.completionReviewPending.remove(sessionKey)
                    self.recordTelemetry(.staleReviewDiscarded, surface: .supervisor, outcome: .stale)
                    return
                }
                self.completionReviews[sessionKey] = StoredCompletionReview(
                    input: input,
                    assessment: assessment,
                    evaluatorResult: evaluatorResult,
                    independentEvaluator: independentEvaluation,
                    providerReceipt: providerReceipt,
                    policyDecision: policyDecision
                )
                self.showMessage(
                    WorkbenchMessage(
                        kind: .success,
                        text: independentEvaluation == nil
                            ? "AI 检查已完成；结果只供你参考。"
                            : "两次 AI 检查已完成；结果只供你参考。"
                    )
                )
                self.recordTelemetry(
                    .providerFinished,
                    surface: .supervisor,
                    outcome: .succeeded,
                    duration: duration
                )
                self.recordTelemetry(.policyEvaluated, surface: .supervisor, outcome: .allowed)
                self.recordTelemetry(.decisionCardShown, surface: .supervisor, outcome: .shown)
            case .harnessOnly(let fallback):
                self.completionReviews[sessionKey] = StoredCompletionReview(
                    input: input,
                    evaluatorResult: fallback.evaluatorResult,
                    providerReceipt: fallback.providerReceipt,
                    fallback: fallback
                )
                self.showMessage(WorkbenchMessage(
                    kind: .notice,
                    text: "AI 检查不可用，Relay 的正常工作流程仍然有效。"
                ))
                self.recordTelemetry(
                    .providerFinished,
                    surface: .supervisor,
                    outcome: .fallback,
                    duration: duration
                )
                self.recordTelemetry(.policyEvaluated, surface: .supervisor, outcome: .rejected)
            }
            self.completionReviewPending.remove(sessionKey)
            self.persistCompletionReviewRuntime()
        }
    }

    func continueAfterCompletionReview(for sessionKey: String) {
        guard let session = snapshot.sessions[sessionKey] else { return }
        recordCompletionReviewDecision(session: session, kind: .continueWork)
        openAgent(for: sessionKey)
    }

    func deleteCompletionReviewData(for sessionKey: String) {
        completionReviewDrafts.removeValue(forKey: sessionKey)
        completionReviews.removeValue(forKey: sessionKey)
        completionReviewConsentInputs.removeValue(forKey: sessionKey)
        completionReviewGitHubCIEnabled.remove(sessionKey)
        completionReviewLocalSwiftEnabled.remove(sessionKey)
        completionReviewLocalPythonEnabled.remove(sessionKey)
        completionReviewLocalPytestEnabled.remove(sessionKey)
        completionReviewLocalJestEnabled.remove(sessionKey)
        completionReviewLocalCargoNextestEnabled.remove(sessionKey)
        completionReviewArtifactSelections.removeValue(forKey: sessionKey)
        completionReviewDecisions.removeAll {
            "\($0.task.source.rawValue):\($0.task.sessionID)" == sessionKey
        }
        completionReviewOutcomes.removeAll {
            "\($0.task.source.rawValue):\($0.task.sessionID)" == sessionKey
        }
        completionReviewResetTokens[sessionKey] = UUID()
        persistCompletionReviewRuntime()
        try? completionEvidenceStore.deleteTask(sessionKey)
        showMessage(
            WorkbenchMessage(kind: .success, text: "本地 AI 检查数据已删除。")
        )
        recordTelemetry(.aiDataDeleted, surface: .supervisor, outcome: .deleted)
    }

    func completionReviewViewID(for sessionKey: String) -> String {
        "\(sessionKey):\(completionReviewResetTokens[sessionKey]?.uuidString ?? "current")"
    }

    func saveSupervisorSettings(
        enabled: Bool,
        modelID: String,
        independentEvaluatorEnabled: Bool,
        independentEvaluatorModelID: String,
        apiKey: String?
    ) {
        let normalizedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEvaluatorModel = independentEvaluatorModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        supervisorEnabled = enabled
        supervisorModelID = normalizedModel.isEmpty ? SupervisorPreferences.defaultModelID : normalizedModel
        self.independentEvaluatorEnabled = independentEvaluatorEnabled
        self.independentEvaluatorModelID = normalizedEvaluatorModel.isEmpty
            ? SupervisorPreferences.defaultIndependentEvaluatorModelID
            : normalizedEvaluatorModel
        completionReviewConsentInputs.removeAll()
        UserDefaults.standard.set(supervisorEnabled, forKey: SupervisorPreferences.enabledKey)
        UserDefaults.standard.set(supervisorModelID, forKey: SupervisorPreferences.modelIDKey)
        UserDefaults.standard.set(
            self.independentEvaluatorEnabled,
            forKey: SupervisorPreferences.independentEvaluatorEnabledKey
        )
        UserDefaults.standard.set(
            self.independentEvaluatorModelID,
            forKey: SupervisorPreferences.independentEvaluatorModelIDKey
        )
        do {
            if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try SupervisorAPIKeyStore.save(apiKey)
            }
            hasSupervisorAPIKey = SupervisorAPIKeyStore.load() != nil
            showMessage(
                WorkbenchMessage(kind: .success, text: "AI 检查设置已保存。")
            )
        } catch {
            showMessage(WorkbenchMessage(kind: .error, text: "无法将 API 密钥保存到钥匙串。"))
        }
    }

    func removeSupervisorAPIKey() {
        do {
            try SupervisorAPIKeyStore.delete()
            hasSupervisorAPIKey = false
            showMessage(
                WorkbenchMessage(kind: .success, text: "API 密钥已从钥匙串中移除。")
            )
        } catch {
            showMessage(WorkbenchMessage(kind: .error, text: "无法移除 API 密钥。"))
        }
    }

    private func configuredIndependentEvaluatorDescriptor(
        supervisorModelID: String
    ) -> SupervisorModelDescriptor? {
        guard independentEvaluatorEnabled else { return nil }
        let modelID = independentEvaluatorModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, modelID != supervisorModelID else { return nil }
        return OpenAIIndependentCompletionReviewEvaluator.modelDescriptor(modelID: modelID)
    }

    private func ensureCompletionReviewDraft(for session: RelaySessionState) {
        guard completionReviewDrafts[session.key] == nil else { return }
        completionReviewDrafts[session.key] = CompletionReviewDraft(
            goal: displayTitle(for: session),
            acceptanceCriteria: ["交付结果满足当前任务目标。"]
        )
    }

    private func recordCompletionReviewDecision(
        session: RelaySessionState,
        kind: CompletionReviewHumanDecisionKind
    ) {
        let review = completionReviews[session.key]
        let task = review?.input.task ?? SupervisorTaskIdentity(
            source: session.source,
            taskID: session.key,
            sessionID: session.sessionID,
            triggerEventID: session.lastEventID
        )
        completionReviewDecisions.append(CompletionReviewHumanDecision(
            task: task,
            assessmentID: review?.assessment?.id,
            kind: kind
        ))
        completionReviewDecisions = Array(completionReviewDecisions.suffix(512))
        recordTelemetry(
            .humanDecisionRecorded,
            surface: .supervisor,
            outcome: kind == .confirmedComplete ? .confirmed : .continued
        )
        persistCompletionReviewRuntime()
    }

    private func persistCompletionReviewRuntime() {
        do {
            var runtime = CompletionReviewRuntimeSnapshot(
                drafts: completionReviewDrafts,
                reviews: completionReviews,
                decisions: completionReviewDecisions,
                outcomes: completionReviewOutcomes
            )
            runtime.pruneExpired()
            completionReviewDrafts = runtime.drafts
            completionReviews = runtime.reviews
            completionReviewDecisions = runtime.decisions
            completionReviewOutcomes = runtime.outcomes
            try completionReviewStore.persist(runtime)
        } catch {
            showMessage(WorkbenchMessage(
                kind: .error,
                text: "无法保存 AI 检查数据；Agent 状态未被更改。"
            ))
        }
    }

    private func pruneCompletionReviewRuntime(now: Date) {
        var runtime = CompletionReviewRuntimeSnapshot(
            drafts: completionReviewDrafts,
            reviews: completionReviews,
            decisions: completionReviewDecisions,
            outcomes: completionReviewOutcomes
        )
        guard runtime.pruneExpired(now: now) > 0 else { return }
        completionReviewDrafts = runtime.drafts
        completionReviews = runtime.reviews
            completionReviewDecisions = runtime.decisions
            completionReviewOutcomes = runtime.outcomes
        try? completionReviewStore.persist(runtime)
    }

    func openAgent(for sessionKey: String) {
        guard let session = presentationSessions[sessionKey] else {
            showMessage(WorkbenchMessage(kind: .notice, text: "此任务已不可用。"))
            return
        }

        let result: AgentLauncher.Result
        if session.source == .claude,
           let processID = processIDsBySessionKey[session.key],
           terminalTaskTitleResolver.focusTerminalTab(processID: processID) {
            result = .exactTask
        } else {
            result = AgentLauncher.open(session: session)
        }

        switch result {
        case .exactTask:
            showMessage(
                WorkbenchMessage(
                    kind: .notice,
                    text: "已在 \(session.source.displayName) 中打开此任务。",
                    sessionKey: session.key
                )
            )
        case .sourceApp:
            let text = session.source == .claude
                ? "已打开 Terminal，请选择对应的 Claude Code 任务继续。"
                : "已打开 \(session.source.displayName)，请在其中选择此任务继续。"
            showMessage(
                WorkbenchMessage(
                    kind: .notice,
                    text: text,
                    sessionKey: session.key
                )
            )
        case .unavailable:
            let text = session.source == .claude
                ? "请打开 Terminal 中对应的 Claude Code 任务继续。"
                : "请打开 \(session.source.displayName) 继续此任务。"
            showMessage(
                WorkbenchMessage(
                    kind: .notice,
                    text: text,
                    sessionKey: session.key
                )
            )
        }
    }

    func dismissMessage() {
        guard message != nil else { return }
        let shouldRecord = messageTelemetryEnabled
        messageDismissTask?.cancel()
        messageDismissTask = nil
        message = nil
        messageTelemetryEnabled = true
        if shouldRecord {
            recordTelemetry(.messageDismissed, surface: .banner, outcome: .manual)
        }
    }

    private func showMessage(
        _ newMessage: WorkbenchMessage,
        autoDismissAfter explicitDelay: TimeInterval? = nil,
        recordsTelemetry: Bool = true
    ) {
        messageDismissTask?.cancel()
        messageDismissTask = nil
        message = newMessage
        messageTelemetryEnabled = recordsTelemetry
        if recordsTelemetry {
            recordTelemetry(
                .messageShown,
                surface: .banner,
                outcome: newMessage.kind.telemetryOutcome
            )
        }
        let delay = explicitDelay ?? timing.messageDuration(for: newMessage.kind.transientKind)

        messageDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  self?.message?.id == newMessage.id else { return }
            self?.message = nil
            self?.messageDismissTask = nil
            self?.messageTelemetryEnabled = true
            if recordsTelemetry {
                self?.recordTelemetry(.messageDismissed, surface: .banner, outcome: .expired)
            }
        }
    }

    func openSettings() {
        guard !isShowingSettings else { return }
        isShowingSettings = true
        recordTelemetry(.settingsOpened, surface: .settings, outcome: .shown)
    }

    func settingsDidClose(outcome: RelayTelemetryOutcome = .manual) {
        isShowingSettings = false
        recordTelemetry(.settingsClosed, surface: .settings, outcome: outcome)
    }

    func deleteLocalTelemetry() {
        do {
            try telemetryStore.delete()
            telemetrySummary = RelayTelemetrySummary()
            showMessage(
                WorkbenchMessage(kind: .success, text: "本地分析数据已删除。"),
                recordsTelemetry: false
            )
        } catch {
            showMessage(WorkbenchMessage(kind: .error, text: "无法删除本地分析数据。"))
        }
    }

    func recordTelemetry(
        _ name: RelayTelemetryEventName,
        surface: RelayTelemetrySurface,
        outcome: RelayTelemetryOutcome? = nil,
        duration: RelayTelemetryDurationBucket? = nil
    ) {
        try? telemetryStore.record(RelayTelemetryEvent(
            name: name,
            surface: surface,
            outcome: outcome,
            duration: duration
        ))
        telemetrySummary = (try? telemetryStore.summary()) ?? RelayTelemetrySummary()
    }

    private func dismissTaskScopedMessage(ifItDoesNotBelongTo sessionKey: String?) {
        guard let scopedSessionKey = message?.sessionKey,
              scopedSessionKey != sessionKey else { return }
        dismissMessage()
    }

    func displayTitle(for session: RelaySessionState) -> String {
        LocalTaskPresentation.displayTitle(
            session: session,
            metadata: taskMetadata[session.key]
        )
    }

    func userFacingSummary(for session: RelaySessionState) -> String {
        switch session.status {
        case .needsPermission:
            "此任务需要你在 \(session.source.displayName) 中批准后才能继续。"
        case .needsInput:
            "\(session.source.displayName) 有一个问题需要你回答。"
        case .readyToReview:
            "Agent 结果正在等待你验收。"
        case .failed:
            "此轮 Agent 工作在完成前停止。"
        case .completed:
            "你已确认此结果完成。"
        case .running:
            "Agent 正在工作。"
        case .cancelled:
            "此任务已取消。"
        case .ended:
            "此 Agent 会话已结束。"
        }
    }

    var heroSession: RelaySessionState? {
        switch projection.hero {
        case .needsAttention(let key, _), .failed(let key, _),
             .readyToReview(let key, _), .completed(let key, _):
            presentationSessions[key]
        case .allClear, .awaitOrders:
            nil
        }
    }

    var selectedSession: RelaySessionState? {
        guard let selectedSessionKey,
              let session = presentationSessions[selectedSessionKey],
              session.source == selectedSource else { return nil }
        return session
    }

    var selectedAgentGroup: WorkbenchAgentGroup? {
        guard let selectedSource else { return nil }
        return projection.agentGroups.first { $0.source == selectedSource }
    }

    private static func heroSessionKey(in projection: WorkbenchProjection) -> String? {
        switch projection.hero {
        case .needsAttention(let key, _), .failed(let key, _),
             .readyToReview(let key, _), .completed(let key, _):
            key
        case .allClear, .awaitOrders:
            nil
        }
    }

    private static func detectConnectedSources(snapshot: RelaySnapshot) -> Set<AgentSource> {
        var sources = Set(snapshot.sessions.values.map(\.source))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(AgentSource, URL)] = [
            (.codex, home.appendingPathComponent(".codex/hooks.json")),
            (.claude, home.appendingPathComponent(".claude/settings.json"))
        ]
        for (source, url) in candidates {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8),
                  text.contains("NOTCH_RELAY_MANAGED=1") else { continue }
            sources.insert(source)
        }
        return sources
    }
}

@MainActor
enum CompletionSoundPlayer {
    static let preferenceKey = "completionSoundEnabled"
    private static var activeSound: NSSound?
    private static var stopTask: Task<Void, Never>?

    static func playIfEnabled(
        defaults: UserDefaults = .standard,
        maximumDuration: TimeInterval = InteractionTimingPolicy.production.completionSoundMaximum,
        event: ((RelayTelemetryEventName, RelayTelemetryOutcome) -> Void)? = nil
    ) {
        let enabled = defaults.object(forKey: preferenceKey) == nil
            ? true
            : defaults.bool(forKey: preferenceKey)
        guard enabled else { return }
        stopTask?.cancel()
        activeSound?.stop()
        guard let sound = NSSound(named: NSSound.Name("Glass")) else { return }
        activeSound = sound
        sound.play()
        event?(.soundStarted, .started)
        stopTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(maximumDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            sound.stop()
            if activeSound === sound { activeSound = nil }
            stopTask = nil
            event?(.soundStopped, .maximumDuration)
        }
    }
}

struct WorkbenchMessage: Equatable, Identifiable {
    enum Kind {
        case notice
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let sessionKey: String?

    init(kind: Kind, text: String, sessionKey: String? = nil) {
        self.kind = kind
        self.text = text
        self.sessionKey = sessionKey
    }
}

private extension WorkbenchMessage.Kind {
    var transientKind: TransientMessageKind {
        switch self {
        case .notice: .notice
        case .success: .success
        case .error: .error
        }
    }

    var telemetryOutcome: RelayTelemetryOutcome {
        switch self {
        case .notice: .notice
        case .success: .success
        case .error: .error
        }
    }
}

#if DEBUG
/// Deterministic provider used only by the isolated UI acceptance harness.
/// It is activated by an explicit environment variable and is not compiled
/// into release builds or exposed in production settings.
private struct AcceptanceCompletionReviewProvider: SupervisorModelProvider {
    let descriptor = SupervisorModelDescriptor(
        providerID: "acceptance-fixture",
        modelID: "deterministic-missing-evidence",
        modelVersion: "1",
        executionLocation: .remote
    )
    let promptVersion = "acceptance-completion-review-prompt-v1"

    func assessCompletion(_ input: CompletionReviewInput) async throws -> SupervisorAssessment {
        try await Task.sleep(nanoseconds: 350_000_000)
        let evidenceIDs = input.evidence.map(\.id)
        let criterionIDs = input.goal.acceptanceCriteria.map(\.id)
        let facts = evidenceIDs.isEmpty ? [] : [SupervisorObservedFact(
            id: "fixture-fact-1",
            statement: "Agent 报告结果已准备好接受复核。",
            evidenceIDs: evidenceIDs,
            acceptanceCriterionIDs: criterionIDs
        )]
        let now = Date()
        return SupervisorAssessment(
            traceID: input.traceID,
            task: input.task,
            model: descriptor,
            usedEvidenceIDs: evidenceIDs,
            observedFacts: facts,
            inferences: [],
            missingEvidence: [SupervisorEvidenceGap(
                id: "fixture-gap-1",
                statement: "尚未提供独立验证证据。",
                acceptanceCriterionIDs: criterionIDs
            )],
            recommendation: .missingEvidence,
            risk: SupervisorRisk(
                level: .medium,
                factors: ["当前结果只有部分生命周期证据。"],
                impactScopes: ["任务结果"],
                reversibility: .reversible
            ),
            uncertainty: SupervisorUncertainty(
                level: .medium,
                reasons: ["缺少独立证据。"]
            ),
            proposedActions: [.requestEvidence, .continueInSourceAgent],
            generatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
    }
}
#endif

enum AgentLauncher {
    enum Result {
        case exactTask
        case sourceApp
        case unavailable
    }

    @MainActor
    static func open(session: RelaySessionState) -> Result {
        if let destination = AgentTaskNavigation.destinationURL(
            source: session.source,
            sessionID: session.sessionID
        ), NSWorkspace.shared.open(destination) {
            return .exactTask
        }

        let bundleIdentifiers: [String] = switch session.source {
        case .codex:
            ["com.openai.codex"]
        case .claude:
            ["com.apple.Terminal"]
        case .cursor:
            ["com.todesktop.230313mzl4w4u92"]
        case .generic:
            []
        }

        for identifier in bundleIdentifiers {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                continue
            }
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return .sourceApp
        }
        return .unavailable
    }
}

extension AgentSource {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .generic: "其他 Agent"
        }
    }

    var spiritAssetName: String {
        switch self {
        case .codex: "codex-spirit-v2"
        case .claude: "claude-spirit-v2"
        case .cursor: "cursor-spirit-v2"
        case .generic: "generic-spirit-v3"
        }
    }
}
