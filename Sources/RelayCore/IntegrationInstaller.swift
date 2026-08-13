import Foundation

public struct InstallationLayout: Equatable, Sendable {
    public var storeRoot: URL
    public var sourceExecutable: URL
    public var installedExecutable: URL
    public var codexConfiguration: URL
    public var claudeConfiguration: URL
    public var launchAgent: URL

    public init(
        storeRoot: URL,
        sourceExecutable: URL,
        installedExecutable: URL,
        codexConfiguration: URL,
        claudeConfiguration: URL,
        launchAgent: URL
    ) {
        self.storeRoot = storeRoot.standardizedFileURL
        self.sourceExecutable = sourceExecutable.standardizedFileURL
        self.installedExecutable = installedExecutable.standardizedFileURL
        self.codexConfiguration = codexConfiguration.standardizedFileURL
        self.claudeConfiguration = claudeConfiguration.standardizedFileURL
        self.launchAgent = launchAgent.standardizedFileURL
    }

    public static func defaults(
        sourceExecutable: URL,
        storeRoot: URL,
        fileManager: FileManager = .default
    ) -> InstallationLayout {
        let userRoot = fileManager.homeDirectoryForCurrentUser
        return InstallationLayout(
            storeRoot: storeRoot,
            sourceExecutable: sourceExecutable,
            installedExecutable: storeRoot
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("relayctl", isDirectory: false),
            codexConfiguration: userRoot
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("hooks.json", isDirectory: false),
            claudeConfiguration: userRoot
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false),
            launchAgent: userRoot
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("local.notchrelay.processor.plist", isDirectory: false)
        )
    }

    public var manifest: URL {
        storeRoot.appendingPathComponent("installation.json", isDirectory: false)
    }

    public var backups: URL {
        storeRoot.appendingPathComponent("backups", isDirectory: true)
    }
}

public struct InstallationPreview: Sendable {
    public var operation: IntegrationOperation
    public var layout: InstallationLayout
    public var configurationEdits: [ConfigurationEdit]
    public var launchAgentOriginalData: Data?
    public var launchAgentProposedData: Data?
    public var launchAgentDiff: String
    public var executableWillChange: Bool

    public var changed: Bool {
        executableWillChange
            || launchAgentOriginalData != launchAgentProposedData
            || configurationEdits.contains(where: \.changed)
    }
}

public struct InstallationReceipt: Equatable, Sendable {
    public var operation: IntegrationOperation
    public var backupDirectory: URL
    public var changedFiles: [URL]
}

public struct IntegrationInstaller: Sendable {
    public static let launchAgentLabel = "local.notchrelay.processor"
    public let layout: InstallationLayout

    public init(layout: InstallationLayout) {
        self.layout = layout
    }

    public func preview(
        operation: IntegrationOperation,
        fileManager: FileManager = .default
    ) throws -> InstallationPreview {
        if operation == .install {
            guard fileManager.fileExists(atPath: layout.sourceExecutable.path) else {
                throw RelayError.storage("source executable does not exist: \(layout.sourceExecutable.path)")
            }
            guard fileManager.isExecutableFile(atPath: layout.sourceExecutable.path) else {
                throw RelayError.storage("source executable is not executable: \(layout.sourceExecutable.path)")
            }
        }

        var edits = try [
            HookConfigurationEditor.makeEdit(
                target: .codex,
                file: layout.codexConfiguration,
                operation: operation,
                executable: layout.installedExecutable,
                storeRoot: layout.storeRoot,
                fileManager: fileManager
            ),
            HookConfigurationEditor.makeEdit(
                target: .claude,
                file: layout.claudeConfiguration,
                operation: operation,
                executable: layout.installedExecutable,
                storeRoot: layout.storeRoot,
                fileManager: fileManager
            )
        ]
        if operation == .uninstall,
           let manifest = try loadInstallationManifest(fileManager: fileManager) {
            for index in edits.indices {
                let existedBeforeInstall = edits[index].target == .codex
                    ? manifest.codexConfigurationExisted
                    : manifest.claudeConfigurationExisted
                guard !existedBeforeInstall,
                      let proposedData = edits[index].proposedData,
                      isEffectivelyEmptyConfiguration(proposedData) else { continue }
                let before = edits[index].originalData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                edits[index].proposedData = nil
                edits[index].diff = renderWholeFileDiff(
                    before: before,
                    after: "",
                    file: edits[index].file.path
                )
            }
        }

        let launchOriginal = fileManager.fileExists(atPath: layout.launchAgent.path)
            ? try Data(contentsOf: layout.launchAgent)
            : nil
        let launchProposed = operation == .install ? makeLaunchAgentData() : nil
        let before = launchOriginal.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let after = launchProposed.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let executableWillChange = operation == .install
            ? try filesDiffer(layout.sourceExecutable, layout.installedExecutable, fileManager: fileManager)
            : fileManager.fileExists(atPath: layout.installedExecutable.path)

        return InstallationPreview(
            operation: operation,
            layout: layout,
            configurationEdits: edits,
            launchAgentOriginalData: launchOriginal,
            launchAgentProposedData: launchProposed,
            launchAgentDiff: before == after
                ? ""
                : renderWholeFileDiff(before: before, after: after, file: layout.launchAgent.path),
            executableWillChange: executableWillChange
        )
    }

    public func install(fileManager: FileManager = .default) throws -> InstallationReceipt {
        let plan = try preview(operation: .install, fileManager: fileManager)
        let existingManifest = try loadInstallationManifest(fileManager: fileManager)
        let mutationTargets = plan.configurationEdits.map(\.file) + [
            layout.installedExecutable,
            layout.launchAgent,
            layout.manifest
        ]
        let backup = try createBackup(of: mutationTargets, fileManager: fileManager)
        var changed: [URL] = []

        do {
            try fileManager.createDirectory(
                at: layout.storeRoot.appendingPathComponent("logs", isDirectory: true),
                withIntermediateDirectories: true
            )
            if plan.executableWillChange {
                let executableData = try Data(contentsOf: layout.sourceExecutable)
                try write(executableData, to: layout.installedExecutable, permissions: 0o755, fileManager: fileManager)
                changed.append(layout.installedExecutable)
            }
            for edit in plan.configurationEdits where edit.changed {
                guard let data = edit.proposedData else { continue }
                try write(data, to: edit.file, permissions: nil, fileManager: fileManager)
                changed.append(edit.file)
            }
            if plan.launchAgentOriginalData != plan.launchAgentProposedData,
               let launchData = plan.launchAgentProposedData {
                try write(launchData, to: layout.launchAgent, permissions: nil, fileManager: fileManager)
                changed.append(layout.launchAgent)
            }

            let manifest = InstallationManifest(
                schemaVersion: 1,
                installedAt: Date(),
                executable: layout.installedExecutable.path,
                codexConfiguration: layout.codexConfiguration.path,
                claudeConfiguration: layout.claudeConfiguration.path,
                launchAgent: layout.launchAgent.path,
                codexConfigurationExisted: existingManifest?.codexConfigurationExisted
                    ?? plan.configurationEdits[0].existedBefore,
                claudeConfigurationExisted: existingManifest?.claudeConfigurationExisted
                    ?? plan.configurationEdits[1].existedBefore
            )
            let manifestData = try RelayJSON.makeEncoder(prettyPrinted: true).encode(manifest)
            try write(manifestData, to: layout.manifest, permissions: nil, fileManager: fileManager)
            changed.append(layout.manifest)
        } catch {
            try? restoreBackup(at: backup, fileManager: fileManager)
            throw error
        }

        return InstallationReceipt(
            operation: .install,
            backupDirectory: backup,
            changedFiles: changed
        )
    }

    public func rollback(
        _ receipt: InstallationReceipt,
        fileManager: FileManager = .default
    ) throws {
        try restoreBackup(at: receipt.backupDirectory, fileManager: fileManager)
    }

    public func uninstall(fileManager: FileManager = .default) throws -> InstallationReceipt {
        let plan = try preview(operation: .uninstall, fileManager: fileManager)
        let existingManifest = try loadInstallationManifest(fileManager: fileManager)
        let mutationTargets = plan.configurationEdits.map(\.file) + [
            layout.installedExecutable,
            layout.launchAgent,
            layout.manifest
        ]
        let backup = try createBackup(of: mutationTargets, fileManager: fileManager)
        var changed: [URL] = []

        do {
            for edit in plan.configurationEdits where edit.changed {
                let didExistOriginally: Bool
                switch edit.target {
                case .codex:
                    didExistOriginally = existingManifest?.codexConfigurationExisted ?? true
                case .claude:
                    didExistOriginally = existingManifest?.claudeConfigurationExisted ?? true
                }

                if !didExistOriginally, edit.proposedData == nil {
                    if fileManager.fileExists(atPath: edit.file.path) {
                        try fileManager.removeItem(at: edit.file)
                    }
                } else if let data = edit.proposedData {
                    try write(data, to: edit.file, permissions: nil, fileManager: fileManager)
                }
                changed.append(edit.file)
            }

            for ownedFile in [layout.launchAgent, layout.installedExecutable, layout.manifest]
            where fileManager.fileExists(atPath: ownedFile.path) {
                try fileManager.removeItem(at: ownedFile)
                changed.append(ownedFile)
            }
        } catch {
            try? restoreBackup(at: backup, fileManager: fileManager)
            throw error
        }

        return InstallationReceipt(
            operation: .uninstall,
            backupDirectory: backup,
            changedFiles: changed
        )
    }

    private func makeLaunchAgentData() -> Data {
        let standardOutput = layout.storeRoot.appendingPathComponent("logs/daemon.out.log").path
        let standardError = layout.storeRoot.appendingPathComponent("logs/daemon.err.log").path
        let values = [
            layout.installedExecutable.path,
            "daemon",
            "--store",
            layout.storeRoot.path,
            "--interval-ms",
            "250"
        ].map { "        <string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(values)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>ThrottleInterval</key>
            <integer>2</integer>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(standardOutput))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(standardError))</string>
        </dict>
        </plist>
        """
        return Data((plist + "\n").utf8)
    }

    private func createBackup(
        of files: [URL],
        fileManager: FileManager
    ) throws -> URL {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let directory = layout.backups.appendingPathComponent(
            "\(timestamp)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var items: [BackupItem] = []
        for (index, file) in files.enumerated() {
            let exists = fileManager.fileExists(atPath: file.path)
            let backupName = "\(index)-\(file.lastPathComponent)"
            if exists {
                try fileManager.copyItem(at: file, to: directory.appendingPathComponent(backupName))
            }
            items.append(BackupItem(path: file.path, existed: exists, backupName: exists ? backupName : nil))
        }
        let manifest = BackupManifest(schemaVersion: 1, createdAt: Date(), items: items)
        let data = try RelayJSON.makeEncoder(prettyPrinted: true).encode(manifest)
        try data.write(to: directory.appendingPathComponent("backup.json"), options: [.atomic])
        return directory
    }

    private func restoreBackup(at directory: URL, fileManager: FileManager) throws {
        let manifestURL = directory.appendingPathComponent("backup.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try RelayJSON.makeDecoder().decode(BackupManifest.self, from: data)
        for item in manifest.items {
            let destination = URL(fileURLWithPath: item.path)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            guard item.existed, let backupName = item.backupName else { continue }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(
                at: directory.appendingPathComponent(backupName),
                to: destination
            )
        }
    }

    private func loadInstallationManifest(fileManager: FileManager) throws -> InstallationManifest? {
        guard fileManager.fileExists(atPath: layout.manifest.path) else { return nil }
        let data = try Data(contentsOf: layout.manifest)
        return try RelayJSON.makeDecoder().decode(InstallationManifest.self, from: data)
    }

    private func write(
        _ data: Data,
        to file: URL,
        permissions: Int?,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: [.atomic])
        if let permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
    }

    private func filesDiffer(
        _ source: URL,
        _ destination: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: destination.path) else { return true }
        if source == destination { return false }
        return try Data(contentsOf: source) != Data(contentsOf: destination)
    }

    private func isEffectivelyEmptyConfiguration(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        for (key, value) in object {
            if key == "hooks", let hooks = value as? [String: Any] {
                let containsHandlerGroups = hooks.values.contains { value in
                    guard let groups = value as? [Any] else { return true }
                    return !groups.isEmpty
                }
                if !containsHandlerGroups { continue }
            }
            return false
        }
        return true
    }

    private func renderWholeFileDiff(before: String, after: String, file: String) -> String {
        var lines = ["--- \(file)", "+++ \(file) (proposed)", "@@"]
        lines.append(contentsOf: before.split(separator: "\n", omittingEmptySubsequences: false).map { "-\($0)" })
        lines.append(contentsOf: after.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private struct InstallationManifest: Codable {
    var schemaVersion: Int
    var installedAt: Date
    var executable: String
    var codexConfiguration: String
    var claudeConfiguration: String
    var launchAgent: String
    var codexConfigurationExisted: Bool
    var claudeConfigurationExisted: Bool
}

private struct BackupManifest: Codable {
    var schemaVersion: Int
    var createdAt: Date
    var items: [BackupItem]
}

private struct BackupItem: Codable {
    var path: String
    var existed: Bool
    var backupName: String?
}
