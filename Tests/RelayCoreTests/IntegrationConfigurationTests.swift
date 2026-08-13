import Foundation
import Testing
@testable import RelayCore

@Suite("Integration configuration editor", .serialized)
struct IntegrationConfigurationTests {
    @Test
    func testCodexInstallPreservesExistingConfiguration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hooks.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data(
            """
            {
              "description": "my existing configuration",
              "hooks": {
                "Stop": [
                  {
                    "matcher": "existing",
                    "hooks": [
                      {"type": "command", "command": "/usr/bin/existing-hook"}
                    ]
                  }
                ]
              },
              "unknownSetting": {"keep": true}
            }
            """.utf8
        )
        try original.write(to: file)

        let edit = try HookConfigurationEditor.makeEdit(
            target: .codex,
            file: file,
            operation: .install,
            executable: URL(fileURLWithPath: "/Applications/Notch Relay/relayctl"),
            storeRoot: URL(fileURLWithPath: "/tmp/notch relay"),
            fileManager: .default
        )

        #expect(edit.changed)
        #expect(edit.addedHandlers == 4)
        #expect(edit.removedHandlers == 0)
        let proposed = try #require(edit.proposedData)
        let object = try #require(JSONSerialization.jsonObject(with: proposed) as? [String: Any])
        #expect(object["description"] as? String == "my existing configuration")
        let unknown = try #require(object["unknownSetting"] as? [String: Any])
        #expect(unknown["keep"] as? Bool == true)
        let string = String(decoding: proposed, as: UTF8.self)
        #expect(string.contains("/usr/bin/existing-hook"))
        #expect(string.contains(ManagedHookCommand.marker))
        #expect(string.contains("'/Applications/Notch Relay/relayctl'"))
        #expect(try HookConfigurationEditor.managedHandlerCount(in: proposed, file: file) == 4)
        #expect(!edit.diff.isEmpty)
    }

    @Test
    func testInstallIsIdempotentAndUpdatesOwnedHandlers() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = try HookConfigurationEditor.makeEdit(
            target: .claude,
            file: file,
            operation: .install,
            executable: URL(fileURLWithPath: "/tmp/relay-v1"),
            storeRoot: root
        )
        try #require(first.proposedData).write(to: file)
        let second = try HookConfigurationEditor.makeEdit(
            target: .claude,
            file: file,
            operation: .install,
            executable: URL(fileURLWithPath: "/tmp/relay-v1"),
            storeRoot: root
        )
        #expect(!second.changed)
        #expect(try HookConfigurationEditor.managedHandlerCount(in: Data(contentsOf: file), file: file) == 6)

        let updated = try HookConfigurationEditor.makeEdit(
            target: .claude,
            file: file,
            operation: .install,
            executable: URL(fileURLWithPath: "/tmp/relay-v2"),
            storeRoot: root
        )
        #expect(updated.changed)
        let updatedString = String(decoding: try #require(updated.proposedData), as: UTF8.self)
        #expect(updatedString.contains("/tmp/relay-v2"))
        #expect(!updatedString.contains("/tmp/relay-v1"))
    }

    @Test
    func testUninstallRemovesOnlyOwnedHandler() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = Data(
            """
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {"type":"command","command":"/usr/bin/user-owned"},
                      {"type":"command","command":"NOTCH_RELAY_MANAGED=1 '/tmp/relayctl' ingest --source claude --fail-open"}
                    ]
                  }
                ]
              },
              "theme": "dark"
            }
            """.utf8
        )
        try source.write(to: file)

        let edit = try HookConfigurationEditor.makeEdit(
            target: .claude,
            file: file,
            operation: .uninstall,
            executable: URL(fileURLWithPath: "/tmp/unused"),
            storeRoot: root
        )
        let string = String(decoding: try #require(edit.proposedData), as: UTF8.self)
        #expect(edit.removedHandlers == 1)
        #expect(string.contains("/usr/bin/user-owned"))
        #expect(string.contains("\"theme\" : \"dark\""))
        #expect(!string.contains(ManagedHookCommand.marker))
    }

    @Test
    func testInvalidHooksShapeIsRejectedWithoutWriting() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("{\"hooks\":\"do not overwrite me\"}".utf8)
        try original.write(to: file)

        #expect(throws: (any Error).self) {
            try HookConfigurationEditor.makeEdit(
                target: .claude,
                file: file,
                operation: .install,
                executable: URL(fileURLWithPath: "/tmp/relayctl"),
                storeRoot: root
            )
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test
    func testPreviewDoesNotExposeExistingSensitiveValues() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = "TEST_TOKEN_CANARY_NOT_A_SECRET"
        let password = "TEST_PASSWORD_CANARY_NOT_A_SECRET"
        let original = Data(
            """
            {
              "env": {"AUTH_TOKEN": "\(token)"},
              "nested": [{"password": "\(password)"}],
              "model": "example-model"
            }
            """.utf8
        )
        try original.write(to: file)

        let edit = try HookConfigurationEditor.makeEdit(
            target: .claude,
            file: file,
            operation: .install,
            executable: URL(fileURLWithPath: "/tmp/relayctl"),
            storeRoot: root
        )

        let proposed = String(decoding: try #require(edit.proposedData), as: UTF8.self)
        #expect(proposed.contains(token))
        #expect(proposed.contains(password))
        #expect(!edit.diff.contains(token))
        #expect(!edit.diff.contains(password))
        #expect(!edit.diff.contains("example-model"))
        #expect(edit.diff.contains(ManagedHookCommand.marker))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-relay-config-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
