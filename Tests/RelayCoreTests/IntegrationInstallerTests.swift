import Foundation
import Testing
@testable import RelayCore

@Suite("Integration installer", .serialized)
struct IntegrationInstallerTests {
    @Test
    func testPreviewDoesNotWriteAnything() throws {
        let fixture = try makeFixture(existingConfigurations: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let codexBefore = try Data(contentsOf: fixture.layout.codexConfiguration)
        let claudeBefore = try Data(contentsOf: fixture.layout.claudeConfiguration)

        let preview = try IntegrationInstaller(layout: fixture.layout).preview(operation: .install)

        #expect(preview.changed)
        #expect(try Data(contentsOf: fixture.layout.codexConfiguration) == codexBefore)
        #expect(try Data(contentsOf: fixture.layout.claudeConfiguration) == claudeBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.installedExecutable.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.launchAgent.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.manifest.path))
    }

    @Test
    func testInstallBacksUpAndPreservesUserHooks() throws {
        let fixture = try makeFixture(existingConfigurations: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let codexBefore = try Data(contentsOf: fixture.layout.codexConfiguration)
        let claudeBefore = try Data(contentsOf: fixture.layout.claudeConfiguration)
        let installer = IntegrationInstaller(layout: fixture.layout)

        let receipt = try installer.install()

        #expect(receipt.operation == .install)
        #expect(FileManager.default.fileExists(atPath: receipt.backupDirectory.path))
        #expect(try Data(contentsOf: receipt.backupDirectory.appendingPathComponent("0-hooks.json")) == codexBefore)
        #expect(try Data(contentsOf: receipt.backupDirectory.appendingPathComponent("1-settings.json")) == claudeBefore)
        #expect(try Data(contentsOf: fixture.layout.installedExecutable) == fixture.executableData)
        #expect(FileManager.default.isExecutableFile(atPath: fixture.layout.installedExecutable.path))
        #expect(FileManager.default.fileExists(atPath: fixture.layout.launchAgent.path))
        #expect(FileManager.default.fileExists(atPath: fixture.layout.manifest.path))

        let codexAfter = try Data(contentsOf: fixture.layout.codexConfiguration)
        let claudeAfter = try Data(contentsOf: fixture.layout.claudeConfiguration)
        #expect(String(decoding: codexAfter, as: UTF8.self).contains("/usr/bin/codex-user-hook"))
        #expect(String(decoding: claudeAfter, as: UTF8.self).contains("/usr/bin/claude-user-hook"))
        #expect(try HookConfigurationEditor.managedHandlerCount(in: codexAfter, file: fixture.layout.codexConfiguration) == 6)
        #expect(try HookConfigurationEditor.managedHandlerCount(in: claudeAfter, file: fixture.layout.claudeConfiguration) == 8)

        let secondPreview = try installer.preview(operation: .install)
        #expect(!secondPreview.changed)
    }

    @Test
    func testUninstallKeepsExistingConfigurationAndRemovesOwnedFiles() throws {
        let fixture = try makeFixture(existingConfigurations: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = IntegrationInstaller(layout: fixture.layout)
        _ = try installer.install()

        let receipt = try installer.uninstall()

        #expect(receipt.operation == .uninstall)
        #expect(FileManager.default.fileExists(atPath: fixture.layout.codexConfiguration.path))
        #expect(FileManager.default.fileExists(atPath: fixture.layout.claudeConfiguration.path))
        let codex = try Data(contentsOf: fixture.layout.codexConfiguration)
        let claude = try Data(contentsOf: fixture.layout.claudeConfiguration)
        #expect(String(decoding: codex, as: UTF8.self).contains("/usr/bin/codex-user-hook"))
        #expect(String(decoding: claude, as: UTF8.self).contains("/usr/bin/claude-user-hook"))
        #expect(try HookConfigurationEditor.managedHandlerCount(in: codex, file: fixture.layout.codexConfiguration) == 0)
        #expect(try HookConfigurationEditor.managedHandlerCount(in: claude, file: fixture.layout.claudeConfiguration) == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.installedExecutable.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.launchAgent.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.manifest.path))
        #expect(FileManager.default.fileExists(atPath: receipt.backupDirectory.path))
    }

    @Test
    func testUninstallReturnsOriginallyMissingConfigurationsToMissing() throws {
        let fixture = try makeFixture(existingConfigurations: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = IntegrationInstaller(layout: fixture.layout)
        _ = try installer.install()
        #expect(FileManager.default.fileExists(atPath: fixture.layout.codexConfiguration.path))
        #expect(FileManager.default.fileExists(atPath: fixture.layout.claudeConfiguration.path))

        let uninstallPreview = try installer.preview(operation: .uninstall)
        #expect(uninstallPreview.configurationEdits.allSatisfy { $0.proposedData == nil })

        _ = try installer.uninstall()

        #expect(!FileManager.default.fileExists(atPath: fixture.layout.codexConfiguration.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeConfiguration.path))
    }

    @Test
    func testRepeatedInstallPreservesOriginalMissingState() throws {
        let fixture = try makeFixture(existingConfigurations: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = IntegrationInstaller(layout: fixture.layout)

        _ = try installer.install()
        _ = try installer.install()
        _ = try installer.uninstall()

        #expect(!FileManager.default.fileExists(atPath: fixture.layout.codexConfiguration.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.claudeConfiguration.path))
    }

    @Test
    func testInstallReceiptCanRestoreOriginalBytes() throws {
        let fixture = try makeFixture(existingConfigurations: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let codexBefore = try Data(contentsOf: fixture.layout.codexConfiguration)
        let claudeBefore = try Data(contentsOf: fixture.layout.claudeConfiguration)
        let installer = IntegrationInstaller(layout: fixture.layout)

        let receipt = try installer.install()
        try installer.rollback(receipt)

        #expect(try Data(contentsOf: fixture.layout.codexConfiguration) == codexBefore)
        #expect(try Data(contentsOf: fixture.layout.claudeConfiguration) == claudeBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.installedExecutable.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.launchAgent.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.layout.manifest.path))
    }

    private func makeFixture(existingConfigurations: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-installer-tests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("build/relayctl")
        let store = root.appendingPathComponent("store", isDirectory: true)
        let codex = root.appendingPathComponent("home/.codex/hooks.json")
        let claude = root.appendingPathComponent("home/.claude/settings.json")
        let launchAgent = root.appendingPathComponent("home/Library/LaunchAgents/local.notchrelay.processor.plist")
        let executableData = Data("fixture relay executable".utf8)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try executableData.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        if existingConfigurations {
            try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(
                "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/usr/bin/codex-user-hook\"}]}]},\"userKey\":1}".utf8
            ).write(to: codex)
            try Data(
                "{\"hooks\":{\"Notification\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/usr/bin/claude-user-hook\"}]}]},\"theme\":\"dark\"}".utf8
            ).write(to: claude)
        }

        let layout = InstallationLayout(
            storeRoot: store,
            sourceExecutable: source,
            installedExecutable: store.appendingPathComponent("bin/relayctl"),
            codexConfiguration: codex,
            claudeConfiguration: claude,
            launchAgent: launchAgent
        )
        return Fixture(root: root, layout: layout, executableData: executableData)
    }
}

private struct Fixture {
    var root: URL
    var layout: InstallationLayout
    var executableData: Data
}
