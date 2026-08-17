import AppKit
import RelayCore
import SwiftUI

@main
struct NotchRelayDesktopApp: App {
    @NSApplicationDelegateAdaptor(NotchRelayApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Notch Relay") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}

@MainActor
final class NotchRelayApplicationDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: WorkbenchWindowCoordinator?
    private var instanceLease: RelayApplicationInstanceLease?
    private var acceptanceLifetimeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let root = try RelayStorePaths.defaultRoot()
            guard let lease = try RelayApplicationInstanceLease(
                lockFile: RelayStorePaths(root: root).applicationInstanceLock
            ) else {
                WorkbenchWindowCoordinator.requestExistingInstanceActivation()
                NSApp.terminate(nil)
                return
            }
            instanceLease = lease
        } catch {
            NSLog("Notch Relay could not acquire its application instance lock: %@", error.localizedDescription)
            NSApp.terminate(nil)
            return
        }

        #if DEBUG
        let acceptanceRoot = ProcessInfo.processInfo.environment["NOTCH_RELAY_ACCEPTANCE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        let acceptanceRoot: URL? = nil
        #endif
        coordinator = WorkbenchWindowCoordinator(root: acceptanceRoot)
        coordinator?.start()

        if acceptanceRoot != nil {
            acceptanceLifetimeTask = Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(
                        InteractionTimingPolicy.production.acceptanceApplicationMaximum
                            * 1_000_000_000
                    )
                )
                guard !Task.isCancelled else { return }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator?.applicationDidBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        acceptanceLifetimeTask?.cancel()
        coordinator?.stop()
        instanceLease = nil
    }
}
