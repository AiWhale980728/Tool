import AppKit
import Carbon.HIToolbox
import RelayCore
import SwiftUI

@MainActor
final class WorkbenchWindowCoordinator: NSObject, NSWindowDelegate {
    private let model: WorkbenchViewModel
    private let workbenchPanel = WorkbenchPanel()
    private let notchPanel = NotchHitPanel()
    private let launcherHintPanel = LauncherHintPanel()
    private var statusItem: NSStatusItem?
    private var screenObserver: NSObjectProtocol?
    private var activationRequestObserver: NSObjectProtocol?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var launcherDragOriginX: CGFloat?
    private var launcherGreetingTask: Task<Void, Never>?
    private var launcherHintDismissTask: Task<Void, Never>?
    private var workbenchIdleTask: Task<Void, Never>?
    private var interactionMonitor: Any?
    private let timing = InteractionTimingPolicy.production

    private static let launcherSidePreferenceKey = "notchLauncherSide"
    private static let launcherSize = NSSize(width: 44, height: 44)
    private static let activationRequestName = Notification.Name(
        "local.notchrelay.application.activate"
    )

    init(root: URL? = nil) {
        model = WorkbenchViewModel(root: root)
        super.init()
    }

    func start() {
        configureWorkbenchPanel()
        configureNotchPanel()
        configureStatusItem()
        configureGlobalHotKey()
        configureInteractionMonitor()
        model.start()
        positionWindows()
        presentLauncherGreeting()

        activationRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.activationRequestName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showWorkbench()
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionWindows()
            }
        }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKey = nil
        hotKeyHandler = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let activationRequestObserver {
            DistributedNotificationCenter.default().removeObserver(activationRequestObserver)
            self.activationRequestObserver = nil
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        launcherHintDismissTask?.cancel()
        launcherGreetingTask?.cancel()
        workbenchIdleTask?.cancel()
        if let interactionMonitor {
            NSEvent.removeMonitor(interactionMonitor)
            self.interactionMonitor = nil
        }
    }

    func toggleWorkbench() {
        workbenchPanel.isVisible ? hideWorkbench() : showWorkbench()
    }

    static func requestExistingInstanceActivation() {
        DistributedNotificationCenter.default().postNotificationName(
            activationRequestName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func showWorkbench() {
        positionWindows()
        model.refreshCurrentAgentTasks()
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        workbenchPanel.makeKeyAndOrderFront(nil)
        model.recordTelemetry(.workbenchOpened, surface: .workbench, outcome: .shown)
        resetWorkbenchIdleTimer()
    }

    func applicationDidBecomeActive() {
        model.refreshCurrentAgentTasks()
    }

    func hideWorkbench(outcome: RelayTelemetryOutcome = .manual) {
        guard workbenchPanel.isVisible else { return }
        workbenchIdleTask?.cancel()
        workbenchIdleTask = nil
        workbenchPanel.orderOut(nil)
        model.recordTelemetry(.workbenchClosed, surface: .workbench, outcome: outcome)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === workbenchPanel,
              !model.isShowingSettings else { return }
        hideWorkbench()
    }

    private func configureWorkbenchPanel() {
        workbenchPanel.delegate = self
        workbenchPanel.level = .popUpMenu
        workbenchPanel.isFloatingPanel = true
        workbenchPanel.hidesOnDeactivate = false
        workbenchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        workbenchPanel.isOpaque = false
        workbenchPanel.backgroundColor = .clear
        workbenchPanel.hasShadow = true
        workbenchPanel.contentView = NSHostingView(
            rootView: WorkbenchView(model: model, closeAction: { [weak self] in
                self?.hideWorkbench()
            })
        )
    }

    private func configureNotchPanel() {
        notchPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        notchPanel.isFloatingPanel = true
        notchPanel.hidesOnDeactivate = false
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.ignoresMouseEvents = false
        updateNotchTarget()
        notchPanel.orderFrontRegardless()

        launcherHintPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        launcherHintPanel.isFloatingPanel = true
        launcherHintPanel.hidesOnDeactivate = false
        launcherHintPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        launcherHintPanel.isOpaque = false
        launcherHintPanel.backgroundColor = .clear
        launcherHintPanel.hasShadow = false
        launcherHintPanel.ignoresMouseEvents = true
        launcherHintPanel.contentView = NSHostingView(rootView: LauncherHintView(model: model))
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "sparkles.rectangle.stack",
                accessibilityDescription: "打开 Notch Relay"
            )
            button.target = self
            button.action = #selector(statusItemClicked)
            button.toolTip = "Notch Relay"
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp,
           let button = statusItem?.button,
           let event = NSApp.currentEvent {
            let menu = NSMenu()
            let openItem = NSMenuItem(
                title: "打开工作台",
                action: #selector(openWorkbenchFromStatusItem),
                keyEquivalent: ""
            )
            openItem.target = self
            menu.addItem(openItem)
            menu.addItem(.separator())
            let quitItem = NSMenuItem(
                title: "退出 Notch Relay",
                action: #selector(quitFromStatusItem),
                keyEquivalent: "q"
            )
            quitItem.target = self
            menu.addItem(quitItem)
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            toggleWorkbench()
        }
    }

    @objc private func openWorkbenchFromStatusItem() {
        showWorkbench()
    }

    @objc private func quitFromStatusItem() {
        NSApp.terminate(nil)
    }

    private func launcherActivated() {
        model.recordTelemetry(.launcherOpened, surface: .launcher, outcome: .manual)
        toggleWorkbench()
    }

    private func configureInteractionMonitor() {
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard self?.workbenchPanel.isVisible == true else { return }
                self?.resetWorkbenchIdleTimer()
            }
            return event
        }
    }

    private func resetWorkbenchIdleTimer() {
        workbenchIdleTask?.cancel()
        guard workbenchPanel.isVisible else { return }
        workbenchIdleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(timing.workbenchIdle * 1_000_000_000))
            guard !Task.isCancelled, workbenchPanel.isVisible else { return }
            if model.isShowingSettings {
                resetWorkbenchIdleTimer()
            } else {
                hideWorkbench(outcome: .idleTimeout)
            }
        }
    }

    private func configureGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let coordinator = Unmanaged<WorkbenchWindowCoordinator>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    coordinator.toggleWorkbench()
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &hotKeyHandler
        )

        let identifier = EventHotKeyID(signature: 0x4E54524C, id: 1) // NTRL
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    private func positionWindows() {
        guard let workbenchScreen = activeScreen() else { return }
        let visible = workbenchScreen.visibleFrame
        let width = min(980, max(760, visible.width - 32))
        let height = min(720, max(600, visible.height - 24))
        let workbenchFrame = NSRect(
            x: visible.midX - width / 2,
            y: visible.maxY - height - 8,
            width: width,
            height: height
        )
        workbenchPanel.setFrame(workbenchFrame, display: true)

        guard let notchScreen = notchedScreen() else {
            launcherHintPanel.orderOut(nil)
            notchPanel.orderOut(nil)
            return
        }

        positionLauncher(on: notchScreen, animated: false)
        notchPanel.orderFrontRegardless()
    }

    private func updateNotchTarget() {
        notchPanel.contentView = NSHostingView(
            rootView: NotchLauncherView(
                model: model,
                action: { [weak self] in self?.launcherActivated() },
                quitAction: { NSApp.terminate(nil) },
                hoverChanged: { [weak self] isHovering in
                    self?.setLauncherHintVisible(isHovering)
                },
                dragChanged: { [weak self] horizontalTranslation in
                    self?.dragLauncher(horizontalTranslation: horizontalTranslation)
                },
                dragEnded: { [weak self] in
                    self?.finishDraggingLauncher()
                }
            )
        )
    }

    private func positionLauncher(on screen: NSScreen, animated: Bool) {
        guard let notchRect = notchRect(on: screen) else { return }
        let side = LauncherSide.load(
            from: UserDefaults.standard,
            key: Self.launcherSidePreferenceKey
        )
        let horizontalGap: CGFloat = 8
        let x = switch side {
        case .left:
            notchRect.minX - horizontalGap - Self.launcherSize.width
        case .right:
            notchRect.maxX + horizontalGap
        }
        let frame = NSRect(
            x: x,
            y: screen.frame.maxY - Self.launcherSize.height + 2,
            width: Self.launcherSize.width,
            height: Self.launcherSize.height
        )

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = timing.standardAnimation
                notchPanel.animator().setFrame(frame, display: true)
            }
        } else {
            notchPanel.setFrame(frame, display: true)
        }
        positionLauncherHint()
    }

    private func dragLauncher(horizontalTranslation: CGFloat) {
        launcherHintDismissTask?.cancel()
        launcherHintDismissTask = nil
        launcherHintPanel.orderOut(nil)
        if launcherDragOriginX == nil {
            launcherDragOriginX = notchPanel.frame.minX
        }
        guard let launcherDragOriginX,
              let screen = notchPanel.screen ?? activeScreen() else { return }

        let horizontalPadding: CGFloat = 8
        let minimumX = screen.frame.minX + horizontalPadding
        let maximumX = screen.frame.maxX - Self.launcherSize.width - horizontalPadding
        let nextX = min(maximumX, max(minimumX, launcherDragOriginX + horizontalTranslation))
        notchPanel.setFrameOrigin(NSPoint(x: nextX, y: notchPanel.frame.minY))
    }

    private func finishDraggingLauncher() {
        defer { launcherDragOriginX = nil }
        guard let screen = notchPanel.screen ?? activeScreen() else { return }
        let side: LauncherSide = notchPanel.frame.midX < screen.frame.midX ? .left : .right
        UserDefaults.standard.set(side.rawValue, forKey: Self.launcherSidePreferenceKey)
        positionLauncher(on: screen, animated: true)
    }

    private func setLauncherHintVisible(_ isVisible: Bool) {
        guard launcherDragOriginX == nil else { return }
        launcherGreetingTask?.cancel()
        launcherGreetingTask = nil
        launcherHintDismissTask?.cancel()
        launcherHintDismissTask = nil
        if isVisible {
            showLauncherHint(for: timing.launcherHint)
        } else {
            let wasVisible = launcherHintPanel.isVisible
            launcherHintPanel.orderOut(nil)
            if wasVisible {
                model.recordTelemetry(.launcherHintDismissed, surface: .launcher, outcome: .manual)
            }
        }
    }

    private func presentLauncherGreeting() {
        guard notchPanel.isVisible else { return }
        launcherGreetingTask?.cancel()
        launcherGreetingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(timing.launcherGreetingDelay * 1_000_000_000)
            )
            guard !Task.isCancelled, notchPanel.isVisible, launcherDragOriginX == nil else { return }
            launcherGreetingTask = nil
            showLauncherHint(for: timing.launcherGreetingDuration)
        }
    }

    private func showLauncherHint(for duration: TimeInterval) {
        launcherHintDismissTask?.cancel()
        positionLauncherHint()
        launcherHintPanel.orderFrontRegardless()
        model.recordTelemetry(.launcherHintShown, surface: .launcher, outcome: .shown)
        launcherHintDismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, launcherHintPanel.isVisible else { return }
            launcherHintPanel.orderOut(nil)
            model.recordTelemetry(.launcherHintDismissed, surface: .launcher, outcome: .expired)
            launcherHintDismissTask = nil
        }
    }

    private func positionLauncherHint() {
        let hintSize = NSSize(width: 118, height: 34)
        launcherHintPanel.setFrame(
            NSRect(
                x: notchPanel.frame.midX - hintSize.width / 2,
                y: notchPanel.frame.minY - hintSize.height - 5,
                width: hintSize.width,
                height: hintSize.height
            ),
            display: true
        )
    }

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    private func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { notchRect(on: $0) != nil }
    }

    private func notchRect(on screen: NSScreen) -> CGRect? {
        NotchDisplayGeometry.notchRect(
            screenFrame: screen.frame,
            leftMenuBarArea: screen.auxiliaryTopLeftArea,
            rightMenuBarArea: screen.auxiliaryTopRightArea
        )
    }
}

private final class WorkbenchPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class NotchHitPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class LauncherHintPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 118, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum LauncherSide: String {
    case left
    case right

    static func load(from defaults: UserDefaults, key: String) -> LauncherSide {
        guard let rawValue = defaults.string(forKey: key),
              let side = LauncherSide(rawValue: rawValue) else { return .right }
        return side
    }
}

private struct NotchLauncherView: View {
    @ObservedObject var model: WorkbenchViewModel
    let action: () -> Void
    let quitAction: () -> Void
    let hoverChanged: (Bool) -> Void
    let dragChanged: (CGFloat) -> Void
    let dragEnded: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: LauncherPresentation {
        LauncherPresentation(hero: model.projection.hero)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(LauncherPalette.paper)
                .overlay {
                    Circle()
                        .stroke(LauncherPalette.ink.opacity(0.12), lineWidth: 0.7)
                }
                .overlay {
                    Circle()
                        .stroke(
                            presentation.tint.opacity(presentation.isActionable ? 0.95 : 0.50),
                            lineWidth: presentation.isActionable ? 2.2 : 1.2
                        )
                        .padding(4)
                }
                .shadow(
                    color: presentation.tint.opacity(isHovering ? 0.30 : 0.16),
                    radius: isHovering ? 7 : 4,
                    y: 2
                )

            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LauncherPalette.ink.opacity(0.88))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if presentation.badgeCount > 0 {
                Text(presentation.badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 15, minHeight: 15)
                    .padding(.horizontal, presentation.badgeCount > 9 ? 2 : 0)
                    .background(presentation.tint, in: Capsule())
                    .overlay {
                        Capsule().stroke(LauncherPalette.paper, lineWidth: 1.5)
                    }
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: 36, height: 36)
        .padding(4)
        .contentShape(Circle())
        .scaleEffect(reduceMotion ? 1 : (isHovering ? 1.06 : 1))
        .animation(
            reduceMotion ? nil : .easeOut(duration: InteractionTimingPolicy.production.hoverAnimation),
            value: isHovering
        )
        .onHover { hovering in
            isHovering = hovering
            hoverChanged(hovering)
        }
        .onTapGesture(perform: action)
        .contextMenu {
            Button(action: action) {
                Label("打开 Notch Relay", systemImage: "rectangle.on.rectangle")
            }
            Divider()
            Button(action: quitAction) {
                Label("退出 Notch Relay", systemImage: "power")
            }
        }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in dragChanged(value.translation.width) }
                .onEnded { _ in dragEnded() }
        )
        .accessibilityLabel("打开 Notch Relay")
        .accessibilityHint("点击打开；水平拖动可移动到刘海另一侧。")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("打开 Notch Relay"), action)
        .accessibilityAction(named: Text("退出 Notch Relay"), quitAction)
    }
}

private struct LauncherHintView: View {
    @ObservedObject var model: WorkbenchViewModel

    private var presentation: LauncherPresentation {
        LauncherPresentation(hero: model.projection.hero)
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(presentation.tint)
                .frame(width: 7, height: 7)
            Text(presentation.label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(LauncherPalette.ink)
        }
        .padding(.horizontal, 13)
        .frame(height: 29)
        .background(LauncherPalette.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LauncherPalette.ink.opacity(0.14), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LauncherPresentation {
    let badgeCount: Int
    let tint: Color
    let label: String
    let isActionable: Bool

    init(hero: WorkbenchHero) {
        switch hero {
        case .needsAttention(_, let additionalCount), .failed(_, let additionalCount):
            badgeCount = additionalCount + 1
            tint = LauncherPalette.coral
            label = "需要你处理"
            isActionable = true
        case .readyToReview(_, let additionalCount):
            badgeCount = additionalCount + 1
            tint = LauncherPalette.ochre
            label = "等待验收"
            isActionable = true
        case .allClear:
            badgeCount = 0
            tint = LauncherPalette.blue
            label = "工作中"
            isActionable = false
        case .completed:
            badgeCount = 0
            tint = LauncherPalette.sage
            label = "已完成"
            isActionable = false
        case .awaitOrders:
            badgeCount = 0
            tint = LauncherPalette.ink.opacity(0.42)
            label = "Notch Relay"
            isActionable = false
        }
    }

    var badgeText: String {
        badgeCount > 9 ? "9+" : String(badgeCount)
    }
}

private enum LauncherPalette {
    static let paper = Color(red: 0.984, green: 0.968, blue: 0.925)
    static let ink = Color(red: 0.12, green: 0.13, blue: 0.14)
    static let coral = Color(red: 0.92, green: 0.34, blue: 0.20)
    static let blue = Color(red: 0.19, green: 0.43, blue: 0.68)
    static let sage = Color(red: 0.25, green: 0.52, blue: 0.45)
    static let ochre = Color(red: 0.72, green: 0.48, blue: 0.16)
}
