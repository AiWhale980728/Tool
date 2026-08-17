import AppKit
import RelayCore
import SwiftUI

struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchViewModel
    let closeAction: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            PaperRule()

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    AgentRail(model: model)
                        .frame(width: max(184, geometry.size.width * 0.23))

                    PaperDivider()

                    TaskColumn(model: model)
                        .frame(width: max(300, geometry.size.width * 0.37))

                    PaperDivider()

                    TaskDetailPanel(model: model)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            PaperRule()
            UtilityRow(
                projection: model.projection,
                quotaSnapshots: model.quotaSnapshots
            )
                .frame(height: 84)
        }
        .background(NotchRelayPalette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(NotchRelayPalette.ink.opacity(0.34), lineWidth: 1)
        }
        .overlay(alignment: .top) {
            if let message = model.message, message.sessionKey == nil {
                MessageBanner(message: message, dismiss: model.dismissMessage)
                    .padding(.top, 62)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $model.isShowingSettings) {
            ConnectionSettingsView(model: model)
        }
        .preferredColorScheme(.light)
        .onExitCommand(perform: closeAction)
        .animation(
            reduceMotion ? nil : .easeOut(duration: InteractionTimingPolicy.production.standardAnimation),
            value: model.message?.id
        )
    }

    private var header: some View {
        HStack {
            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotchRelayPalette.ink)
            .help("关闭工作台")
            .accessibilityLabel("关闭工作台")

            Spacer()

            Text("Notch Relay")
                .font(.relay(size: 28, weight: .semibold))
                .foregroundStyle(NotchRelayPalette.ink)

            Spacer()

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotchRelayPalette.ink)
            .help("连接与隐私")
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
    }
}

private struct AgentRail: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.projection.agentGroups, id: \.source) { group in
                    Button {
                        model.selectAgent(group.source)
                    } label: {
                        HStack(spacing: 6) {
                            AgentSpirit(source: group.source, size: 82)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.source.displayName)
                                    .font(.relay(size: 20, weight: .semibold))
                                    .foregroundStyle(NotchRelayPalette.ink)
                                    .lineLimit(2)

                                Text(agentState(for: group))
                                    .font(.relayCaption())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 112)
                        .background(selectionBackground(for: group.source))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    PaperRule(opacity: 0.14)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private func selectionBackground(for source: AgentSource) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                model.selectedSource == source
                    ? NotchRelayPalette.sage.opacity(0.10)
                    : Color.clear
            )
            .padding(6)
    }

    private func agentState(for group: WorkbenchAgentGroup) -> String {
        if group.source == .codex {
            switch model.codexCurrentTaskAvailability {
            case .checking: return "正在读取"
            case .reconnecting: return "正在重新连接"
            case .unavailable: return "任务状态不可用"
            case .current: break
            }
        }
        if group.totalTaskCount == 0 { return "等待任务" }
        return "\(group.totalTaskCount) 个任务"
    }
}

private struct TaskColumn: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(sectionTitle)
                    .font(.relay(size: 23, weight: .semibold))
                    .foregroundStyle(sectionColor)

                Spacer()

                Text("\(selectedGroup?.totalTaskCount ?? 0) 个任务")
                    .font(.relayCaption().monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("当前显示 \(selectedGroup?.totalTaskCount ?? 0) 个任务")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 11)

            if model.selectedSource == .codex,
               model.codexCurrentTaskAvailability == .checking {
                CodexTaskStatusView(
                    symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                    title: "正在读取当前任务",
                    detail: "正在核对这个 Codex 账号当前打开的任务。",
                    retry: nil
                )
            } else if model.selectedSource == .codex,
                      model.codexCurrentTaskAvailability == .unavailable {
                CodexTaskStatusView(
                    symbol: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                    title: "当前任务状态暂不可用",
                    detail: "Notch Relay 已隐藏历史任务，避免把旧账号记录误报为当前任务。",
                    retry: model.refreshCurrentAgentTasks
                )
            } else if selectedGroup?.tasks.isEmpty != false {
                EmptyTaskList()
            } else {
                VStack(spacing: 0) {
                    if model.selectedSource == .codex,
                       model.codexCurrentTaskAvailability == .reconnecting {
                        Label("正在重新连接，暂时显示最近一次成功结果", systemImage: "arrow.clockwise")
                            .font(.relayCaption())
                            .foregroundStyle(NotchRelayPalette.ochre)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(selectedGroup?.tasks ?? [], id: \.session.key) { task in
                                TaskRow(
                                    task: task,
                                    isSelected: model.selectedSessionKey == task.session.key,
                                    model: model
                                )
                                PaperRule(opacity: 0.12)
                                    .padding(.horizontal, 18)
                            }
                        }
                    }
                }
            }
        }
    }

    private var selectedGroup: WorkbenchAgentGroup? {
        model.selectedAgentGroup
    }

    private var sectionTitle: String {
        if model.selectedSource == .codex {
            switch model.codexCurrentTaskAvailability {
            case .checking: return "正在读取"
            case .reconnecting: return "正在重新连接"
            case .unavailable: return "状态暂不可用"
            case .current: break
            }
        }
        guard let status = selectedStatus else { return "一切正常" }
        return switch status {
        case .needsInput, .needsPermission, .failed: "需要你处理"
        case .readyToReview: "等待验收"
        case .completed: "已完成"
        case .running: "工作中"
        case .cancelled, .ended: "已结束"
        }
    }

    private var sectionColor: Color {
        if model.selectedSource == .codex,
           model.codexCurrentTaskAvailability != .current {
            return NotchRelayPalette.ochre
        }
        return selectedStatus?.tint ?? NotchRelayPalette.ink
    }

    private var selectedStatus: RelayStatus? {
        model.selectedSession?.status ?? selectedGroup?.tasks.first?.session.status
    }
}

private struct CodexTaskStatusView: View {
    let symbol: String
    let title: String
    let detail: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(NotchRelayPalette.ochre)
            Text(title)
                .font(.relay(size: 17, weight: .semibold))
            Text(detail)
                .font(.relayCallout())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("重新读取", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct EmptyTaskList: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(NotchRelayPalette.sage)
            Text("等待任务")
                .font(.relay(size: 17, weight: .semibold))
            Text("已连接的 Agent 正在等待新任务。")
                .font(.relayCallout())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct TaskRow: View {
    let task: WorkbenchTask
    let isSelected: Bool
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        Button {
            model.select(task.session.key)
        } label: {
            HStack(spacing: 11) {
                Circle()
                    .fill(task.session.status.tint)
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayTitle(for: task.session))
                        .font(.relay(size: 16, weight: .semibold))
                        .foregroundStyle(NotchRelayPalette.ink)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(task.session.source.displayName)
                        Text("·")
                        Text(task.session.status.displayLabel)
                        if task.attentionLevel != .normal {
                            Text("·")
                            Label(
                                task.attentionLevel.displayName,
                                systemImage: task.attentionLevel.systemImage
                            )
                        }
                    }
                    .font(.relayCaption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let progress = task.session.progress {
                    Text("\(progress.percentage)%")
                        .font(.relayCallout(weight: .semibold).monospacedDigit())
                        .foregroundStyle(NotchRelayPalette.blue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            NotchRelayPalette.blue.opacity(0.09),
                            in: Capsule()
                        )
                } else if task.canConfirmCompletion {
                    Text("验收")
                        .font(.relay(size: 11, weight: .semibold))
                        .foregroundStyle(NotchRelayPalette.ochre)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(NotchRelayPalette.ochre.opacity(0.08), in: Capsule())
                        .accessibilityLabel("结果等待验收")
                        .help("选择此任务检查结果，确认确实完成后再标记完成。")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 67)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? NotchRelayPalette.coral.opacity(0.055) : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                isSelected
                                    ? NotchRelayPalette.ink.opacity(0.34)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TaskDetailPanel: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        Group {
            if let session = model.selectedSession {
                detail(for: session)
            } else {
                idleDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func detail(for session: RelaySessionState) -> some View {
        ScrollView {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.status.tint)
                    .frame(width: 9, height: 9)
                Text(session.source.displayName)
                    .font(.relayCallout(weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.displayTitle(for: session))
                    .font(.relayCallout())
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(NotchRelayPalette.ink)

            Spacer(minLength: 0)

            AgentSpirit(source: session.source, size: session.status == .readyToReview ? 92 : 148)

            Text(session.status.detailBadge)
                .font(.relay(size: 16, weight: .semibold))
                .foregroundStyle(session.status.tint)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(session.status.tint.opacity(0.08), in: Capsule())

            Text(detailMessage(for: session))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(NotchRelayPalette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 280)

            if session.status == .readyToReview {
                CompletionReviewPanel(model: model, session: session)
                    .frame(maxWidth: 360)
                    .id(model.completionReviewViewID(for: session.key))
            }

            detailActions(for: session)
                .frame(maxWidth: 280)

            if let message = model.message, message.sessionKey == session.key {
                TaskActionFeedback(message: message)
                    .frame(maxWidth: 280)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            TaskPriorityPicker(model: model, session: session)
                .frame(maxWidth: 280)

            Spacer(minLength: 0)
        }
        }
    }

    @ViewBuilder
    private func detailActions(for session: RelaySessionState) -> some View {
        switch session.status {
        case .readyToReview:
            VStack(spacing: 9) {
                Button(completionButtonTitle(for: session)) {
                    model.confirmComplete(sessionKey: session.key)
                }
                .buttonStyle(PrimaryPaperButtonStyle(color: NotchRelayPalette.coral))
                .disabled(model.confirmationPending.contains(session.key))

                Button("打开 Agent") {
                    model.openAgent(for: session.key)
                }
                .buttonStyle(LinkPaperButtonStyle())
            }

        case .needsInput, .needsPermission, .failed:
            Button("前往 Agent 处理") {
                model.openAgent(for: session.key)
            }
            .buttonStyle(PrimaryPaperButtonStyle(color: NotchRelayPalette.coral))

        case .running, .completed, .cancelled, .ended:
            Button("打开 Agent") {
                model.openAgent(for: session.key)
            }
            .buttonStyle(LinkPaperButtonStyle())
        }
    }

    private func completionButtonTitle(for session: RelaySessionState) -> String {
        guard let assessment = model.completionReview(for: session)?.assessment else {
            return "人工确认完成"
        }
        return assessment.recommendation == .verifiedReady
            ? "确认完成"
            : "人工复核后仍然确认完成"
    }

    private func detailMessage(for session: RelaySessionState) -> String {
        switch session.status {
        case .needsPermission:
            "此任务需要你在 \(session.source.displayName) 中作出决定后才能继续。"
        case .needsInput:
            "\(session.source.displayName) 有一个问题需要你回答。"
        case .readyToReview:
            "请检查结果，确认确实完成后再提交验收。"
        case .failed:
            "此轮 Agent 工作在完成前停止。"
        case .completed:
            "此结果已完成，并会保留在今天的工作台中。"
        case .running:
            "此任务正在工作，暂时不需要你处理。"
        case .cancelled:
            "此任务已取消。"
        case .ended:
            "此 Agent 会话已结束。"
        }
    }

    @ViewBuilder
    private var idleDetail: some View {
        if model.selectedSource == .codex,
           model.codexCurrentTaskAvailability != .current {
            VStack(spacing: 14) {
                Spacer()
                AgentSpirit(source: .codex, size: 152)
                Text(codexIdleTitle)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .foregroundStyle(NotchRelayPalette.ochre)
                Text(codexIdleDetail)
                    .font(.relayBody())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Spacer()
            }
        } else {
        VStack(spacing: 14) {
            Spacer()
            AgentSpirit(source: model.selectedSource ?? .codex, size: 152)
            Text("一切正常")
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(NotchRelayPalette.sage)
            Text("现在没有需要你处理的事项。")
                .font(.relayBody())
                .foregroundStyle(.secondary)
            Spacer()
        }
        }
    }

    private var codexIdleTitle: String {
        switch model.codexCurrentTaskAvailability {
        case .checking: "正在读取当前任务"
        case .reconnecting: "正在重新连接"
        case .unavailable: "当前任务状态暂不可用"
        case .current: "一切正常"
        }
    }

    private var codexIdleDetail: String {
        switch model.codexCurrentTaskAvailability {
        case .checking: "正在核对这个 Codex 账号当前打开的任务。"
        case .reconnecting: "暂时保留最近一次成功结果，重新连接后会自动更新。"
        case .unavailable: "历史任务已隐藏。请在 Codex 中确认当前任务，或在中栏重新读取。"
        case .current: "现在没有需要你处理的事项。"
        }
    }
}

private struct CompletionReviewPanel: View {
    @ObservedObject var model: WorkbenchViewModel
    let session: RelaySessionState
    @State private var goalText: String
    @State private var criteriaText: String
    @State private var resultSummaryText: String

    init(model: WorkbenchViewModel, session: RelaySessionState) {
        self.model = model
        self.session = session
        let draft = model.completionReviewDrafts[session.key] ?? CompletionReviewDraft(
            goal: model.displayTitle(for: session),
            acceptanceCriteria: ["交付结果满足当前任务目标。"]
        )
        _goalText = State(initialValue: draft.goal)
        _criteriaText = State(initialValue: draft.acceptanceCriteria.joined(separator: "\n"))
        _resultSummaryText = State(initialValue: draft.resultSummary ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("用 AI 检查交付结果", systemImage: "sparkles")
                    .font(.relayCallout(weight: .bold))
                    .foregroundStyle(NotchRelayPalette.violet)
                Spacer()
                Text("只给建议")
                    .font(.relay(size: 10, weight: .bold))
                    .foregroundStyle(NotchRelayPalette.violet)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(NotchRelayPalette.violet.opacity(0.1), in: Capsule())
            }

            Text("AI 会对照任务目标、验收条件和你选择的证据，指出遗漏与风险；它不会替你确认完成，也不会修改 Agent 任务。")
                .font(.relay(size: 11))
                .foregroundStyle(.secondary)

            if let review = model.completionReview(for: session),
               let assessment = review.assessment {
                CompletionReviewResult(
                    assessment: assessment,
                    evaluatorResult: review.evaluatorResult,
                    independentEvaluator: review.independentEvaluator,
                    providerReceipt: review.providerReceipt,
                    continueAction: { model.continueAfterCompletionReview(for: session.key) },
                    rerunAction: { model.runCompletionReview(for: session.key) }
                )
            } else if let fallback = model.completionReview(for: session)?.fallback {
                Label(fallbackMessage(fallback), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.relayCaption())
                    .foregroundStyle(.secondary)
                if let receipt = fallback.providerFailureReceipt {
                    Text(providerFailureReceiptSummary(receipt, label: "模型提供方失败回执"))
                        .font(.relay(size: 10))
                        .foregroundStyle(.secondary)
                }
                reviewEditor
            } else if let input = model.completionReviewConsent(for: session) {
                CompletionReviewConsentCard(
                    input: input,
                    confirmAction: { model.runCompletionReview(for: session.key) },
                    cancelAction: { model.cancelCompletionReviewConsent(for: session.key) }
                )
            } else {
                reviewEditor
            }

            Button("删除本地 AI 检查数据") {
                model.deleteCompletionReviewData(for: session.key)
            }
            .buttonStyle(.plain)
            .font(.relayCaption())
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(NotchRelayPalette.violet.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(NotchRelayPalette.violet.opacity(0.24), lineWidth: 1)
        }
    }

    private var reviewEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("任务目标")
                .font(.relayCaption(weight: .semibold))
            TextField("需要达成什么目标？", text: $goalText)
            .textFieldStyle(.roundedBorder)
            .onChange(of: goalText) { model.updateCompletionReviewGoal($0, for: session) }

            Text("验收条件 · 每行一条")
                .font(.relayCaption(weight: .semibold))
            TextEditor(text: $criteriaText)
            .font(.relayCaption())
            .frame(minHeight: 54, maxHeight: 72)
            .padding(5)
            .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(NotchRelayPalette.ink.opacity(0.14), lineWidth: 1)
            }
            .onChange(of: criteriaText) { model.updateCompletionReviewCriteria($0, for: session) }

            Text("结果摘要 · 可选")
                .font(.relayCaption(weight: .semibold))
            TextEditor(text: $resultSummaryText)
                .font(.relayCaption())
                .frame(minHeight: 44, maxHeight: 60)
                .padding(5)
                .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(NotchRelayPalette.ink.opacity(0.14), lineWidth: 1)
                }
                .onChange(of: resultSummaryText) {
                    model.updateCompletionReviewResultSummary($0, for: session)
                }

            HStack(spacing: 8) {
                Label("交付物", systemImage: "doc.badge.checkmark")
                    .font(.relayCaption(weight: .semibold))
                Spacer()
                Text("\(artifactSummaries.count)/\(ArtifactCompletionEvidenceAdapter.maximumArtifactCount)")
                    .font(.relay(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    model.selectCompletionReviewArtifacts(for: session.key)
                } label: {
                    Label("选择", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.relayCaption(weight: .semibold))
                .disabled(model.completionReviewPending.contains(session.key))
                .help("从当前任务工作区选择 PDF、PNG、JPEG、JSON 或 ZIP 交付物。")
            }

            ForEach(Array(artifactSummaries.enumerated()), id: \.offset) { index, summary in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .foregroundStyle(NotchRelayPalette.violet)
                    Text(summary)
                        .font(.relay(size: 11))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        model.removeCompletionReviewArtifact(at: index, for: session.key)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("移除此交付物证据")
                }
            }

            Toggle(
                isOn: Binding(
                    get: { model.includesLocalSwiftVerification(for: session.key) },
                    set: { model.setIncludesLocalSwiftVerification($0, for: session.key) }
                )
            ) {
                Label("运行本地 Swift 测试", systemImage: "hammer")
                    .font(.relayCaption(weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(!model.supportsLocalSwiftVerification(for: session))
            .help(localSwiftVerificationHelp)

            Toggle(
                isOn: Binding(
                    get: { model.includesLocalPythonVerification(for: session.key) },
                    set: { model.setIncludesLocalPythonVerification($0, for: session.key) }
                )
            ) {
                Label("运行本地 Python unittest", systemImage: "checkmark.rectangle.stack")
                    .font(.relayCaption(weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(!model.supportsLocalPythonVerification(for: session))
            .help(localPythonVerificationHelp)

            Toggle(
                isOn: Binding(
                    get: { model.includesLocalPytestVerification(for: session.key) },
                    set: { model.setIncludesLocalPytestVerification($0, for: session.key) }
                )
            ) {
                Label("运行本地 pytest", systemImage: "checkmark.seal")
                    .font(.relayCaption(weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(!model.supportsLocalPytestVerification(for: session))
            .help(localPytestVerificationHelp)

            Toggle(
                isOn: Binding(
                    get: { model.includesLocalJestVerification(for: session.key) },
                    set: { model.setIncludesLocalJestVerification($0, for: session.key) }
                )
            ) {
                Label("运行本地 Jest", systemImage: "checkmark.diamond")
                    .font(.relayCaption(weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(!model.supportsLocalJestVerification(for: session))
            .help(localJestVerificationHelp)

            Toggle(
                isOn: Binding(
                    get: { model.includesLocalCargoNextestVerification(for: session.key) },
                    set: { model.setIncludesLocalCargoNextestVerification($0, for: session.key) }
                )
            ) {
                Label("运行本地 Cargo nextest", systemImage: "shippingbox")
                    .font(.relayCaption(weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(!model.supportsLocalCargoNextestVerification(for: session))
            .help(localCargoNextestVerificationHelp)

            Toggle(
                isOn: Binding(
                    get: { model.includesGitHubCIEvidence(for: session.key) },
                    set: { model.setIncludesGitHubCIEvidence($0, for: session.key) }
                )
            ) {
                Label("包含 GitHub CI 检查", systemImage: "checkmark.circle")
                    .font(.relayCaption(weight: .semibold))
            }
            .toggleStyle(.switch)
            .help("请求数据披露后运行只读 GitHub CLI 查询；仓库名和检查名称不会发送给模型。")

            Text("上下文预览只包含目标、验收条件、上方可选摘要和结构化完成证据。不会包含交付物文件、文件名、路径和引用，也不会发送对话、源代码、原始命令或凭据。粘贴的摘要始终只是部分证据，不能作为独立证明。")
                .font(.relay(size: 11))
                .foregroundStyle(.secondary)

            Button {
                model.prepareCompletionReviewConsent(for: session.key)
            } label: {
                if model.completionReviewPending.contains(session.key) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在检查证据…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label(reviewPreparationLabel, systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryPaperButtonStyle(color: NotchRelayPalette.violet))
            .disabled(model.completionReviewPending.contains(session.key))
        }
    }

    private var reviewPreparationLabel: String {
        model.includesLocalSwiftVerification(for: session.key)
            || model.includesLocalPythonVerification(for: session.key)
            || model.includesLocalPytestVerification(for: session.key)
            || model.includesLocalJestVerification(for: session.key)
            || model.includesLocalCargoNextestVerification(for: session.key)
            ? "运行本地检查并预览数据"
            : "预览数据与模型提供方"
    }

    private var artifactSummaries: [String] {
        model.completionReviewArtifactSummaries(for: session.key)
    }

    private var localSwiftVerificationHelp: String {
        guard model.supportsLocalSwiftVerification(for: session) else {
            return "仅当任务工作区包含普通 Package.swift 文件时可用。"
        }
        return "使用固定 Swift Package 参数运行项目测试，最长 3 分钟；隔离 HOME 和构建目录，禁用自动依赖解析，并丢弃原始输出。"
    }

    private var localPythonVerificationHelp: String {
        guard model.supportsLocalPythonVerification(for: session) else {
            return "仅当普通 tests 目录同时存在 pyproject.toml、setup.cfg 或 setup.py 时可用。"
        }
        return "使用固定参数运行系统 Python unittest discovery，最长 3 分钟；隔离 HOME 和缓存、移除 PYTHONPATH，并丢弃原始输出。"
    }

    private var localPytestVerificationHelp: String {
        guard model.supportsLocalPytestVerification(for: session) else {
            return "仅当普通 tests 目录包含有界 pytest.ini 或已配置 pytest 的 pyproject.toml 时可用。"
        }
        return "使用固定参数运行已安装的系统 Python pytest 模块，最长 3 分钟；关闭插件自动加载，隔离 HOME 和缓存，生成有界 JUnit 报告，移除 PYTHONPATH，并丢弃原始输出。"
    }

    private var localJestVerificationHelp: String {
        guard model.supportsLocalJestVerification(for: session) else {
            return "仅当项目本地安装 Jest 30.4.2，且 Node 位于可信标准安装路径时可用。"
        }
        return "通过项目本地 Jest 运行测试，最长 3 分钟；固定使用 CI、串行、无缓存和无监听参数，隔离 HOME 和缓存，生成有界 JSON 报告，并丢弃原始输出。"
    }

    private var localCargoNextestVerificationHelp: String {
        guard model.supportsLocalCargoNextestVerification(for: session) else {
            return "仅当有界 Cargo 项目包含 Cargo.lock 且已安装 cargo-nextest 0.9.143 时可用。"
        }
        return "通过 cargo-nextest 0.9.143 运行项目测试，最长 3 分钟；固定使用锁定、离线、串行和不重试参数，隔离 HOME、Cargo home 和 target 目录，生成有界 JUnit 报告，并丢弃原始输出。"
    }

    private func fallbackMessage(_ fallback: SupervisorFallback) -> String {
        switch fallback.code {
        case .providerUnavailable: "模型提供方当前不可用，确定性底座仍正常工作。"
        case .providerTimeout: "模型调用超时，确定性底座仍正常工作。"
        case .invalidStructuredOutput: "模型返回了无效决策卡，系统已拒绝该结果。"
        case .providerCancelled: "AI 检查已取消。"
        case .providerFailure: "AI 检查已安全失败，确定性底座仍正常工作。"
        case .policyRejected: "确定性策略拒绝了此次 AI 检查。"
        case .duplicateRequest: "此任务已有一项 AI 检查正在进行。"
        case .providerConcurrencyLimit: "模型提供方正忙，请稍后重试。"
        case .providerRateLimit: "已达到本地复核速率上限，请稍后重试。"
        case .providerCircuitOpen: "模型提供方连续失败，AI 检查已暂时停用。"
        }
    }
}

private struct CompletionReviewConsentCard: View {
    let input: CompletionReviewInput
    let confirmAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("检查数据预览", systemImage: "checkmark.shield")
                .font(.relayCaption(weight: .bold))
                .foregroundStyle(NotchRelayPalette.violet)

            if let consent = input.consent {
                DisclosureRow(label: "用途", value: "检查交付结果")
                DisclosureRow(
                    label: "数据",
                    value: "最高 \(consent.maximumDataLevel.disclosureName) · \(evidenceCountLabel)"
                )
                DisclosureRow(
                    label: "模型提供方",
                    value: "\(consent.provider.disclosureProviderName) · \(consent.provider.modelID) · 远程"
                )
                if let evaluator = consent.independentEvaluatorProvider {
                    DisclosureRow(
                        label: "评估器",
                        value: "\(evaluator.disclosureProviderName) · \(evaluator.modelID) · 远程"
                    )
                    Text("评估器接收同一份有界上下文，以及结构化监督器评估结果。")
                        .font(.relay(size: 10))
                        .foregroundStyle(.secondary)
                }
                DisclosureRow(
                    label: "本地留存",
                    value: "最长 \(consent.localRetentionSeconds / 3_600) 小时 · 可立即删除"
                )
                DisclosureRow(
                    label: "远程留存",
                    value: "由模型提供方账户策略控制"
                )
            }

            DisclosurePreviewSection(label: "目标", values: [input.goal.statement])
            DisclosurePreviewSection(
                label: "验收条件",
                values: input.goal.acceptanceCriteria.map(\.statement)
            )
            DisclosurePreviewSection(
                label: "发送的证据",
                values: input.evidence.map(\.summary)
            )

            Text("不会发送：提示词、对话、源代码、原始命令、工具参数、凭据和证据引用。")
                .font(.relay(size: 11))
                .foregroundStyle(.secondary)

            Button(action: confirmAction) {
                Label("发送上述数据并开始检查", systemImage: "paperplane")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPaperButtonStyle(color: NotchRelayPalette.violet))

            Button(action: cancelAction) {
                Label("取消", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LinkPaperButtonStyle())
        }
    }

    private var evidenceCountLabel: String {
        "\(input.evidence.count) 条证据记录"
    }
}

private struct DisclosurePreviewSection: View {
    let label: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.relay(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.relay(size: 11))
                    .foregroundStyle(NotchRelayPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DisclosureRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.relay(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.relay(size: 11))
                .foregroundStyle(NotchRelayPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CompletionReviewResult: View {
    let assessment: SupervisorAssessment
    let evaluatorResult: CompletionReviewEvaluatorResult?
    let independentEvaluator: StoredIndependentCompletionReviewEvaluation?
    let providerReceipt: SupervisorProviderReceipt?
    let continueAction: () -> Void
    let rerunAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(assessment.recommendation.displayName)
                    .font(.relayCallout(weight: .bold))
                    .foregroundStyle(assessment.recommendation.tint)
                Spacer()
                Text("风险：\(assessment.risk.level.displayName)")
                    .font(.relayCaption(weight: .semibold))
                    .foregroundStyle(assessment.risk.level.tint)
            }

            if !assessment.observedFacts.isEmpty {
                ReviewList(title: "已观察事实", values: assessment.observedFacts.map(\.statement))
            }
            if !assessment.missingEvidence.isEmpty {
                ReviewList(title: "缺失证据", values: assessment.missingEvidence.map(\.statement))
            }
            if !assessment.inferences.isEmpty {
                ReviewList(title: "AI 推断", values: assessment.inferences.map(\.statement))
            }
            if !assessment.uncertainty.reasons.isEmpty {
                ReviewList(
                    title: "不确定性 · \(assessment.uncertainty.level.displayName)",
                    values: assessment.uncertainty.reasons
                )
            }
            if let evaluatorResult {
                ReviewList(
                    title: "确定性评估器 · \(evaluatorResult.verdict.displayName)",
                    values: evaluatorResult.findings.map(\.detail)
                )
            }
            if let result = independentEvaluator?.result {
                ReviewList(
                    title: "第二个 AI 的交叉检查 · \(result.verdict.displayName)",
                    values: result.findings.map(\.detail)
                )
                Text(independentEvaluatorScoreSummary(result))
                    .font(.relay(size: 10))
                    .foregroundStyle(.secondary)
                if let receipt = independentEvaluator?.providerReceipt {
                    Text(providerReceiptSummary(receipt, label: "评估器回执"))
                        .font(.relay(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else if let fallback = independentEvaluator?.fallbackCode {
                Text("第二个 AI 的交叉检查不可用：\(fallback.displayName)。确定性策略不受影响。")
                    .font(.relay(size: 10))
                    .foregroundStyle(.secondary)
                if let receipt = independentEvaluator?.providerFailureReceipt {
                    Text(providerFailureReceiptSummary(receipt, label: "评估器失败回执"))
                        .font(.relay(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text("模型：\(assessment.model.modelID) · 任务变化后失效")
                .font(.relay(size: 10))
                .foregroundStyle(.secondary)

            if let providerReceipt {
                Text(providerReceiptSummary(providerReceipt, label: "模型提供方回执"))
                    .font(.relay(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack {
                if assessment.recommendation != .verifiedReady {
                    Button("返回 Agent 继续", action: continueAction)
                        .buttonStyle(LinkPaperButtonStyle())
                }
                Spacer()
                Button("重新复核", action: rerunAction)
                    .buttonStyle(LinkPaperButtonStyle())
            }
        }
    }

    private func providerReceiptSummary(
        _ receipt: SupervisorProviderReceipt,
        label: String
    ) -> String {
        let returnedModel = receipt.returnedModelID ?? "未报告"
        let tokens = receipt.totalTokenCount.map(String.init) ?? "未报告"
        return "\(label)：\(returnedModel) · \(receipt.promptVersion) · \(tokens) 个 Token · \(receipt.latencyMilliseconds) 毫秒"
    }

    private func independentEvaluatorScoreSummary(
        _ result: IndependentCompletionReviewEvaluatorResult
    ) -> String {
        "评估器评分：依据充分性 \(percent(result.scores.groundedness)) · 条件覆盖 \(percent(result.scores.criterionCoverage)) · 风险校准 \(percent(result.scores.riskCalibration)) · \(result.model.modelID)"
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private func providerFailureReceiptSummary(
    _ receipt: SupervisorProviderFailureReceipt,
    label: String
) -> String {
    "\(label)：\(receipt.providerID)/\(receipt.requestedModelID) · \(receipt.promptVersion) · \(receipt.failureKind.displayName) · \(receipt.latencyMilliseconds) 毫秒"
}

private extension SupervisorProviderFailureKind {
    var displayName: String {
        switch self {
        case .unavailable: "不可用"
        case .timeout: "超时"
        case .invalidStructuredOutput: "结构化输出无效"
        case .cancelled: "已取消"
        case .providerFailure: "模型提供方失败"
        }
    }
}

private extension IndependentCompletionReviewFallbackCode {
    var displayName: String {
        switch self {
        case .notConfigured: "未配置"
        case .consentMismatch: "授权不匹配"
        case .nonIndependentModel: "模型不独立"
        case .providerUnavailable: "模型提供方不可用"
        case .providerTimeout: "模型提供方超时"
        case .invalidStructuredOutput: "结构化输出无效"
        case .providerCancelled: "已取消"
        case .providerFailure: "模型提供方失败"
        case .duplicateRequest: "请求重复"
        case .providerConcurrencyLimit: "达到模型提供方并发上限"
        case .providerRateLimit: "达到模型提供方速率上限"
        case .providerCircuitOpen: "模型提供方熔断已开启"
        }
    }
}

private extension CompletionReviewEvaluatorVerdict {
    var displayName: String {
        switch self {
        case .supportsAssessment: "通过"
        case .rejectsAssessment: "拒绝"
        case .humanReviewRequired: "需要人工复核"
        }
    }
}

private struct ReviewList: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.relayCaption(weight: .semibold))
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text("• \(value)")
                    .font(.relayCaption())
                    .foregroundStyle(NotchRelayPalette.ink.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TaskActionFeedback: View {
    let message: WorkbenchMessage

    var body: some View {
        Label(message.text, systemImage: "arrow.up.forward.app")
            .font(.relayCaption(weight: .semibold))
            .foregroundStyle(NotchRelayPalette.blue)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(NotchRelayPalette.blue.opacity(0.07), in: Capsule())
            .accessibilityLabel(message.text)
    }
}

private struct TaskPriorityPicker: View {
    @ObservedObject var model: WorkbenchViewModel
    let session: RelaySessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("任务优先级")
                .font(.relayCaption(weight: .semibold))
                .foregroundStyle(.secondary)

            Picker(
                "任务优先级",
                selection: Binding(
                    get: { model.attentionLevel(for: session.key) },
                    set: { model.setAttentionLevel($0, for: session.key) }
                )
            ) {
                ForEach(TaskAttentionLevel.allCases, id: \.self) { level in
                    Label(level.displayName, systemImage: level.systemImage)
                        .tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

private struct PrimaryPaperButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                color.opacity(configuration.isPressed ? 0.78 : 0.92),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(NotchRelayPalette.ink.opacity(0.42), lineWidth: 1)
            }
    }
}

private struct LinkPaperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(NotchRelayPalette.blue.opacity(configuration.isPressed ? 0.65 : 1))
            .underline()
            .padding(.vertical, 6)
    }
}

private struct UtilityRow: View {
    let projection: WorkbenchProjection
    let quotaSnapshots: [AgentSource: AgentQuotaSnapshot]

    var body: some View {
        HStack(spacing: 0) {
            UtilityCell(
                title: "今日任务",
                value: "已结束 \(projection.finishedTodayCount) · \(cleanupValue)",
                systemImage: "clock"
            )

            UtilityDivider()

            BalanceUtilityCell(
                balances: projection.balances,
                codexSnapshot: quotaSnapshots[.codex],
                currentCodexModels: currentCodexModels
            )

            UtilityDivider()

            UtilityCell(
                title: "Mac",
                value: thermalValue,
                systemImage: "thermometer.medium"
            )
        }
    }

    private var cleanupValue: String {
        guard let date = projection.nextCleanupAt else { return "近期没有待清理记录" }
        let remaining = max(0, date.timeIntervalSinceNow)
        if remaining < 3_600 { return "\(max(1, Int(remaining / 60))) 分钟后清理" }
        return "\(max(1, Int(remaining / 3_600))) 小时后清理"
    }

    private var thermalValue: String {
        projection.systemWorkload?.thermalPressure.displayName ?? "不可用"
    }

    private var currentCodexModels: [String] {
        Array(Set(
            projection.agentGroups
                .first(where: { $0.source == .codex })?
                .tasks
                .compactMap(\.session.model) ?? []
        )).sorted()
    }
}

private struct BalanceUtilityCell: View {
    let balances: [ProviderBalanceSnapshot]
    let codexSnapshot: AgentQuotaSnapshot?
    let currentCodexModels: [String]
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            VStack(spacing: 8) {
                Label("Agent 额度", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.relayCaption())
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(summary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.relay(size: 9, weight: .semibold))
                }
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(NotchRelayPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Agent 额度")
                    .font(.relayCallout(weight: .bold))
                HStack(spacing: 16) {
                    Text("Codex 当前模型")
                    Spacer()
                    Text(modelValue)
                        .foregroundStyle(.secondary)
                }
                if balances.isEmpty {
                    Text("尚未读取到可用额度")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(balances, id: \.providerID) { balance in
                        HStack(spacing: 16) {
                            Text(localizedName(balance))
                            Spacer()
                            Text(value(balance))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let usage = codexSnapshot?.tokenUsage {
                    if let latest = usage.latestDailyTokens,
                       let date = usage.latestDailyStartDate {
                        HStack(spacing: 16) {
                            Text("Codex Token（\(date)）")
                            Spacer()
                            Text(formatTokenCount(latest))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let lifetime = usage.lifetimeTokens {
                        HStack(spacing: 16) {
                            Text("Codex Token（累计）")
                            Spacer()
                            Text(formatTokenCount(lifetime))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("模型来自当前任务 Hook；额度与 Token 汇总来自本机 Codex 只读接口，不读取浏览器 Cookie 或凭据内容。")
                    .font(.relayCaption())
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private var summary: String {
        guard !balances.isEmpty else { return "未连接" }
        let quota = balances
            .filter { $0.kind == .subscriptionQuota && $0.fractionRemaining != nil }
            .min { ($0.fractionRemaining ?? 1) < ($1.fractionRemaining ?? 1) }
        if let quota { return "\(localizedName(quota)) · \(value(quota))" }
        if let credit = balances.first(where: { $0.kind == .apiCredit }) {
            return "\(localizedName(credit)) · \(value(credit))"
        }
        let warning = balances.first { $0.effectiveState() != .normal }
        return warning?.effectiveState().displayName ?? "可用"
    }

    private var helpText: String {
        guard !balances.isEmpty else {
            return "通过本机 Agent 接口读取额度与 Token 汇总，不读取浏览器 Cookie 或凭据内容。"
        }
        return balances.map { "\(localizedName($0))：\(value($0))" }.joined(separator: " · ")
    }

    private var modelValue: String {
        guard !currentCodexModels.isEmpty else { return "未读取到" }
        if currentCodexModels.count <= 2 { return currentCodexModels.joined(separator: "、") }
        return "\(currentCodexModels[0]) 等 \(currentCodexModels.count) 个"
    }

    private func value(_ balance: ProviderBalanceSnapshot) -> String {
        if let remaining = balance.remaining, balance.unit == "%" {
            return "剩余 \(Int(remaining.rounded()))%"
        }
        if let remaining = balance.remaining {
            let formatted = remaining.formatted(.number.precision(.fractionLength(0...1)))
            return "剩余 \(formatted) \(balance.unit ?? "")"
        }
        return balance.effectiveState().displayName
    }

    private func localizedName(_ balance: ProviderBalanceSnapshot) -> String {
        switch balance.displayName {
        case "Codex 5h": "Codex 5 小时额度"
        case "Codex weekly": "Codex 每周额度"
        default:
            switch balance.providerID {
            case "codex:credits": "Codex 点数"
            case "codex:spend": "Codex 消费额度"
            default: balance.displayName
            }
        }
    }

    private func formatTokenCount(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }
}

private struct UtilityCell: View {
    let title: String
    let value: String
    let systemImage: String
    var help: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.relayCaption())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(NotchRelayPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .help(help ?? "\(title)：\(value)")
    }
}

private struct UtilityDivider: View {
    var body: some View {
        Rectangle()
            .fill(NotchRelayPalette.ink.opacity(0.18))
            .frame(width: 1, height: 54)
    }
}

private struct AgentSpirit: View {
    let displayName: String
    let assetName: String
    let size: CGFloat

    init(source: AgentSource, size: CGFloat) {
        displayName = source.displayName
        assetName = source.spiritAssetName
        self.size = size
    }

    init(role: AgentRoleDefinition, size: CGFloat) {
        displayName = role.displayName
        assetName = role.runtimeAssetName ?? "generic-spirit-v3"
        self.size = size
    }

    var body: some View {
        Group {
            if let image = spiritImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(displayName) 角色图标")
    }

    private var spiritImage: NSImage? {
        guard let url = Bundle.module.url(
            forResource: assetName,
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

private struct MessageBanner: View {
    let message: WorkbenchMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
            Text(message.text)
                .font(.relayCallout())
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NotchRelayPalette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(foreground.opacity(0.25), lineWidth: 1)
        }
        .foregroundStyle(foreground)
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
    }

    private var symbol: String {
        switch message.kind {
        case .notice: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var foreground: Color {
        switch message.kind {
        case .notice: NotchRelayPalette.blue
        case .success: NotchRelayPalette.sage
        case .error: NotchRelayPalette.coral
        }
    }
}

private struct ConnectionSettingsView: View {
    @ObservedObject var model: WorkbenchViewModel
    @AppStorage(CompletionSoundPlayer.preferenceKey) private var completionSoundEnabled = true
    @State private var supervisorEnabled: Bool
    @State private var supervisorModelID: String
    @State private var independentEvaluatorEnabled: Bool
    @State private var independentEvaluatorModelID: String
    @State private var supervisorAPIKey = ""
    @State private var selectedAgentRoleID: String
    @State private var closeRecorded = false

    init(model: WorkbenchViewModel) {
        self.model = model
        _supervisorEnabled = State(initialValue: model.supervisorEnabled)
        _supervisorModelID = State(initialValue: model.supervisorModelID)
        _independentEvaluatorEnabled = State(initialValue: model.independentEvaluatorEnabled)
        _independentEvaluatorModelID = State(initialValue: model.independentEvaluatorModelID)
        let initialRole = AgentRoleCatalog.all.first {
            guard let source = $0.source else { return false }
            return model.connectedSources.contains(source)
        } ?? AgentRoleCatalog.approvedConcepts[0]
        _selectedAgentRoleID = State(initialValue: initialRole.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("连接与隐私")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Spacer()
                Button {
                    closeSettings(outcome: .manual)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("关闭设置")
                .accessibilityLabel("关闭设置")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .frame(height: 62)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

            Text("此设置页将在 2 分钟后自动关闭。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Notch Relay 只读取精简的本地任务状态，不需要提示词、对话、代码、原始命令、凭据或详细输出。")
                .foregroundStyle(.secondary)

            Label("在任意位置按 Command-Shift-Space 打开工作台。", systemImage: "keyboard")
                .foregroundStyle(.secondary)

            Text("读取 Claude Code 任务名称时，macOS 可能会请求 Terminal 访问权限。Notch Relay 只读取匹配的标签页标题和 TTY，不读取终端内容。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("用 AI 检查交付结果", systemImage: "sparkles")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("只给建议")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NotchRelayPalette.violet)
                }

                Text("Agent 表示工作结束后，AI 会对照你填写的目标、验收条件和所选证据，找出遗漏、风险和仍需人工确认的地方。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("允许 AI 检查交付结果", isOn: $supervisorEnabled)
                    .toggleStyle(.switch)

                TextField("模型", text: $supervisorModelID)
                    .textFieldStyle(.roundedBorder)

                SecureField(
                    model.hasSupervisorAPIKey ? "API 密钥已存入钥匙串" : "OpenAI API 密钥",
                    text: $supervisorAPIKey
                )
                .textFieldStyle(.roundedBorder)

                Text("API 密钥保存在 macOS 钥匙串中。每次确认数据披露后，已启用的模型只会收到披露页展示的数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("再用另一个 AI 交叉检查", isOn: $independentEvaluatorEnabled)
                    .toggleStyle(.switch)

                TextField("独立评估器模型", text: $independentEvaluatorModelID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!independentEvaluatorEnabled)

                Text("第二个模型只负责交叉检查第一个 AI 的结论。它不能批准完成，也不能改变任务状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("保存检查设置") {
                        model.saveSupervisorSettings(
                            enabled: supervisorEnabled,
                            modelID: supervisorModelID,
                            independentEvaluatorEnabled: independentEvaluatorEnabled,
                            independentEvaluatorModelID: independentEvaluatorModelID,
                            apiKey: supervisorAPIKey.isEmpty ? nil : supervisorAPIKey
                        )
                        supervisorAPIKey = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NotchRelayPalette.violet)

                    if model.hasSupervisorAPIKey {
                        Button("移除 API 密钥") {
                            model.removeSupervisorAPIKey()
                            supervisorAPIKey = ""
                        }
                    }
                }
            }
            .padding(14)
            .background(NotchRelayPalette.violet.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(NotchRelayPalette.violet.opacity(0.2), lineWidth: 1)
            }

            Toggle("任务完成时播放声音", isOn: $completionSoundEnabled)
                .toggleStyle(.switch)

            Text("问题、审批请求、工作更新、优先级变化和等待验收结果都不会播放声音。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("本地产品分析", systemImage: "chart.bar.xaxis")
                        .font(.callout.weight(.semibold))
                    Text("最近 7 天 · \(model.telemetrySummary.eventCount) 个事件 · 打开工作台 \(model.telemetrySummary.workbenchOpenCount) 次 · 启动 AI 检查 \(model.telemetrySummary.reviewStartedCount) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("仅保存在本机，只记录固定字段，不包含任务名、提示词、代码、路径、原始响应或凭据；最长自动保留 30 天。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("删除") { model.deleteLocalTelemetry() }
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("仅在 Notch Relay 中显示提醒", systemImage: "bell.slash")
                    .font(.callout.weight(.semibold))
                Text("Notch Relay 不发送 macOS 通知横幅。若要避免 Codex 重复通知，请前往 Codex 设置 → 通知，将完成通知设为“从不”。该选项由 Codex 管理，Notch Relay 无法代为修改。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Notch Relay 每 5 分钟通过 Codex 本地 app-server 以只读、不可信模式刷新额度，不读取认证文件、Token、浏览器 Cookie、原始 CLI 输出或账户邮箱。探测分析只记录成功或失败及耗时区间，不记录具体额度。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("Agent 连接", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout.weight(.semibold))

                Picker("选择 Agent", selection: $selectedAgentRoleID) {
                    ForEach(AgentRoleGroup.allCases, id: \.self) { group in
                        Section(group.displayName) {
                            ForEach(AgentRoleCatalog.all.filter { $0.group == group }) { role in
                                Text(role.displayName).tag(role.id)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    AgentSpirit(role: selectedAgentRole, size: 44)
                    Text(selectedAgentRole.displayName)
                    Spacer()
                    Text(selectedAgentConnectionLabel)
                        .foregroundStyle(selectedAgentIsConnected ? NotchRelayPalette.sage : .secondary)
                }

                Text("角色设定：\(selectedAgentRole.identityDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if selectedAgentRole.runtimeAssetName == nil {
                    Text("当前使用通用图标；独立角色图尚未制作。")
                        .font(.caption)
                        .foregroundStyle(NotchRelayPalette.ochre)
                }

                Text("这里列出 24 个已批准角色、Pi 和其他 Agent。选择只用于查看角色与连接状态；尚未适配的 Agent 不会被自动接入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(24)
            }
        }
        .frame(width: 520, height: 660)
        .background(NotchRelayPalette.paper)
        .preferredColorScheme(.light)
        .task {
            try? await Task.sleep(
                nanoseconds: UInt64(InteractionTimingPolicy.production.settingsMaximum * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            closeSettings(outcome: .maximumDuration)
        }
        .onDisappear {
            guard !closeRecorded else { return }
            closeRecorded = true
            model.settingsDidClose(outcome: .manual)
        }
    }

    private func closeSettings(outcome: RelayTelemetryOutcome) {
        guard !closeRecorded else { return }
        closeRecorded = true
        model.settingsDidClose(outcome: outcome)
    }

    private var selectedAgentIsConnected: Bool {
        guard let source = selectedAgentRole.source else { return false }
        return model.connectedSources.contains(source)
    }

    private var selectedAgentConnectionLabel: String {
        guard selectedAgentRole.source != nil else { return "尚未接入" }
        return selectedAgentIsConnected ? "已连接" : "未连接"
    }

    private var selectedAgentRole: AgentRoleDefinition {
        AgentRoleCatalog.role(id: selectedAgentRoleID) ?? AgentRoleCatalog.approvedConcepts[0]
    }
}

private struct PaperRule: View {
    var opacity: Double = 0.2

    var body: some View {
        Rectangle()
            .fill(NotchRelayPalette.ink.opacity(opacity))
            .frame(height: 1)
    }
}

private struct PaperDivider: View {
    var body: some View {
        Rectangle()
            .fill(NotchRelayPalette.ink.opacity(0.24))
            .frame(width: 1)
            .padding(.vertical, 10)
    }
}

private enum NotchRelayPalette {
    static let paper = Color(red: 0.984, green: 0.968, blue: 0.925)
    static let ink = Color(red: 0.12, green: 0.13, blue: 0.14)
    static let coral = Color(red: 0.92, green: 0.34, blue: 0.20)
    static let violet = Color(red: 0.39, green: 0.35, blue: 0.62)
    static let blue = Color(red: 0.19, green: 0.43, blue: 0.68)
    static let sage = Color(red: 0.25, green: 0.52, blue: 0.45)
    static let ochre = Color(red: 0.72, green: 0.48, blue: 0.16)
}

private extension Font {
    static func relay(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func relayCaption(weight: Font.Weight = .regular) -> Font {
        .system(size: 12, weight: weight, design: .rounded)
    }

    static func relayCallout(weight: Font.Weight = .regular) -> Font {
        .system(size: 16, weight: weight, design: .rounded)
    }

    static func relayBody(weight: Font.Weight = .regular) -> Font {
        .system(size: 17, weight: weight, design: .rounded)
    }
}

private extension RelayStatus {
    var displayLabel: String {
        switch self {
        case .running: "工作中"
        case .needsInput: "等待输入"
        case .needsPermission: "等待审批"
        case .readyToReview: "等待验收"
        case .failed: "失败"
        case .completed: "已完成"
        case .cancelled: "已取消"
        case .ended: "已结束"
        }
    }

    var detailBadge: String {
        switch self {
        case .needsInput, .needsPermission: "需要你处理"
        case .readyToReview: "等待验收"
        case .running: "工作中"
        case .failed: "需要检查"
        case .completed: "已完成"
        case .cancelled: "已取消"
        case .ended: "会话已结束"
        }
    }

    var tint: Color {
        switch self {
        case .needsInput, .needsPermission, .failed: NotchRelayPalette.coral
        case .readyToReview: NotchRelayPalette.ochre
        case .running: NotchRelayPalette.blue
        case .completed: NotchRelayPalette.sage
        case .cancelled, .ended: .secondary
        }
    }
}

private extension ThermalPressure {
    var displayName: String {
        switch self {
        case .cool: "温度正常"
        case .warm: "偏热"
        case .hot: "过热"
        case .coolingNeeded: "需要降温"
        case .unavailable: "不可用"
        }
    }
}

private extension BalanceState {
    var displayName: String {
        switch self {
        case .normal: "可用"
        case .gettingLow: "即将不足"
        case .low: "不足"
        case .exhausted: "已用尽"
        case .unavailable: "不可用"
        case .signInRequired: "需要登录"
        case .stale: "需要刷新"
        }
    }
}

private extension TaskAttentionLevel {
    var displayName: String {
        switch self {
        case .pinned: "置顶"
        case .normal: "普通"
        case .later: "稍后"
        }
    }

    var systemImage: String {
        switch self {
        case .pinned: "pin.fill"
        case .normal: "circle"
        case .later: "arrow.down.circle"
        }
    }
}

private extension CompletionReviewRecommendation {
    var displayName: String {
        switch self {
        case .verifiedReady: "证据支持完成"
        case .missingEvidence: "需要更多证据"
        case .continueWork: "继续工作"
        case .humanReviewRequired: "需要人工复核"
        }
    }

    var tint: Color {
        switch self {
        case .verifiedReady: NotchRelayPalette.sage
        case .missingEvidence: NotchRelayPalette.ochre
        case .continueWork: NotchRelayPalette.coral
        case .humanReviewRequired: NotchRelayPalette.violet
        }
    }
}

private extension SupervisorRiskLevel {
    var displayName: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .critical: "严重"
        }
    }

    var tint: Color {
        switch self {
        case .low: NotchRelayPalette.sage
        case .medium: NotchRelayPalette.ochre
        case .high, .critical: NotchRelayPalette.coral
        }
    }
}

private extension SupervisorUncertaintyLevel {
    var displayName: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .unknown: "未知"
        }
    }
}

private extension SupervisorDataLevel {
    var disclosureName: String {
        switch self {
        case .l0RuntimeMetadata: "L0 运行元数据"
        case .l1StructuredEvidence: "L1 结构化证据"
        case .l2SelectedContent: "L2 已选择内容"
        case .l3SensitiveContent: "L3 敏感内容"
        }
    }
}

private extension SupervisorModelDescriptor {
    var disclosureProviderName: String {
        switch providerID {
        case "openai": "OpenAI"
        case "acceptance-fixture": "验收测试夹具"
        default: providerID
        }
    }
}
