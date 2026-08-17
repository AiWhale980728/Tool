import Foundation

public enum IntegrationTarget: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum IntegrationOperation: String, Codable, Sendable {
    case install
    case uninstall
}

public struct ConfigurationEdit: Equatable, Sendable {
    public var target: IntegrationTarget
    public var file: URL
    public var existedBefore: Bool
    public var originalData: Data?
    public var proposedData: Data?
    public var addedHandlers: Int
    public var removedHandlers: Int
    public var diff: String

    public init(
        target: IntegrationTarget,
        file: URL,
        existedBefore: Bool,
        originalData: Data?,
        proposedData: Data?,
        addedHandlers: Int,
        removedHandlers: Int,
        diff: String
    ) {
        self.target = target
        self.file = file
        self.existedBefore = existedBefore
        self.originalData = originalData
        self.proposedData = proposedData
        self.addedHandlers = addedHandlers
        self.removedHandlers = removedHandlers
        self.diff = diff
    }

    public var changed: Bool {
        originalData != proposedData
    }
}

public enum ManagedHookCommand {
    public static let marker = "NOTCH_RELAY_MANAGED=1"

    public static func make(
        executable: URL,
        source: AgentSource,
        storeRoot: URL
    ) throws -> String {
        guard executable.path.hasPrefix("/"), storeRoot.path.hasPrefix("/") else {
            throw RelayError.storage("managed Hook paths must be absolute")
        }
        return [
            marker,
            shellQuote(executable.standardizedFileURL.path),
            "ingest",
            "--source",
            source.rawValue,
            "--store",
            shellQuote(storeRoot.standardizedFileURL.path),
            "--fail-open"
        ].joined(separator: " ")
    }

    public static func isManaged(_ command: String) -> Bool {
        command.contains(marker)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public enum HookConfigurationEditor {
    public static func makeEdit(
        target: IntegrationTarget,
        file: URL,
        operation: IntegrationOperation,
        executable: URL,
        storeRoot: URL,
        fileManager: FileManager = .default
    ) throws -> ConfigurationEdit {
        let existed = fileManager.fileExists(atPath: file.path)
        let originalData = existed ? try Data(contentsOf: file) : nil
        var root = try decodeRoot(originalData, file: file)
        var hooks = try hooksObject(from: root, file: file)
        let removed = stripManagedHandlers(from: &hooks)

        var added = 0
        if operation == .install {
            let source: AgentSource = target == .codex ? .codex : .claude
            let command = try ManagedHookCommand.make(
                executable: executable,
                source: source,
                storeRoot: storeRoot
            )
            for specification in specifications(for: target) {
                try appendManagedGroup(
                    event: specification.event,
                    matcher: specification.matcher,
                    command: command,
                    hooks: &hooks,
                    file: file
                )
                added += 1
            }
        }

        if operation == .uninstall, removed == 0 {
            return ConfigurationEdit(
                target: target,
                file: file,
                existedBefore: existed,
                originalData: originalData,
                proposedData: originalData,
                addedHandlers: 0,
                removedHandlers: 0,
                diff: ""
            )
        }

        root["hooks"] = hooks
        let proposedData = try encode(root, file: file)
        let before = try previewJSON(originalData, file: file)
        let after = try previewJSON(proposedData, file: file)
        return ConfigurationEdit(
            target: target,
            file: file,
            existedBefore: existed,
            originalData: originalData,
            proposedData: proposedData,
            addedHandlers: added,
            removedHandlers: removed,
            diff: LineDiff.render(before: before, after: after, file: file.path)
        )
    }

    private static func previewJSON(_ data: Data?, file: URL) throws -> String {
        guard let data else { return "" }
        let root = try decodeRoot(data, file: file)
        guard let redacted = redactSensitiveValues(in: root) as? [String: Any] else {
            throw RelayError.storage("failed to prepare a safe preview for \(file.path)")
        }
        let normalized = try encode(redacted, file: file)
        return String(decoding: normalized, as: UTF8.self)
    }

    private static func redactSensitiveValues(in value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, element in
                result[element.key] = isSensitiveKey(element.key)
                    ? "<redacted>"
                    : redactSensitiveValues(in: element.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(redactSensitiveValues(in:))
        }
        return value
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return [
            "token", "secret", "password", "passwd", "apikey", "accesskey",
            "privatekey", "credential", "authorization", "cookie", "sessionkey"
        ].contains { normalized.contains($0) }
    }

    public static func managedHandlerCount(
        in data: Data,
        file: URL
    ) throws -> Int {
        let root = try decodeRoot(data, file: file)
        let hooks = try hooksObject(from: root, file: file)
        var count = 0
        for value in hooks.values {
            guard let groups = value as? [Any] else { continue }
            for rawGroup in groups {
                guard let group = rawGroup as? [String: Any],
                      let handlers = group["hooks"] as? [Any] else { continue }
                for rawHandler in handlers {
                    guard let handler = rawHandler as? [String: Any],
                          let command = handler["command"] as? String,
                          ManagedHookCommand.isManaged(command) else { continue }
                    count += 1
                }
            }
        }
        return count
    }

    private static func decodeRoot(_ data: Data?, file: URL) throws -> [String: Any] {
        guard let data else { return [:] }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any] else {
                throw RelayError.storage("\(file.path) must contain a JSON object")
            }
            return root
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.storage("failed to parse \(file.path): \(error.localizedDescription)")
        }
    }

    private static func hooksObject(
        from root: [String: Any],
        file: URL
    ) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw RelayError.storage("hooks in \(file.path) must be a JSON object")
        }
        return hooks
    }

    private static func stripManagedHandlers(from hooks: inout [String: Any]) -> Int {
        var removed = 0
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [Any] else { continue }
            let removedBeforeEvent = removed
            var retainedGroups: [Any] = []

            for rawGroup in groups {
                guard var group = rawGroup as? [String: Any],
                      let handlers = group["hooks"] as? [Any] else {
                    retainedGroups.append(rawGroup)
                    continue
                }

                let retainedHandlers = handlers.filter { rawHandler in
                    guard let handler = rawHandler as? [String: Any],
                          let command = handler["command"] as? String,
                          ManagedHookCommand.isManaged(command) else {
                        return true
                    }
                    removed += 1
                    return false
                }
                if retainedHandlers.isEmpty, !handlers.isEmpty {
                    continue
                }
                group["hooks"] = retainedHandlers
                retainedGroups.append(group)
            }
            if retainedGroups.isEmpty, removed > removedBeforeEvent {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = retainedGroups
            }
        }
        return removed
    }

    private static func appendManagedGroup(
        event: String,
        matcher: String?,
        command: String,
        hooks: inout [String: Any],
        file: URL
    ) throws {
        let existing: [Any]
        if let raw = hooks[event] {
            guard let groups = raw as? [Any] else {
                throw RelayError.storage("Hook event \(event) in \(file.path) must be an array")
            }
            existing = groups
        } else {
            existing = []
        }

        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": 3
            ]]
        ]
        if let matcher {
            group["matcher"] = matcher
        }
        hooks[event] = existing + [group]
    }

    private static func encode(_ object: [String: Any], file: URL) throws -> Data {
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            return data
        } catch {
            throw RelayError.storage("failed to encode \(file.path): \(error.localizedDescription)")
        }
    }

    private static func specifications(for target: IntegrationTarget) -> [HookSpecification] {
        switch target {
        case .codex:
            return [
                HookSpecification(event: "SessionStart"),
                HookSpecification(event: "UserPromptSubmit"),
                HookSpecification(event: "PermissionRequest"),
                HookSpecification(event: "PostToolUse"),
                HookSpecification(event: "Stop"),
                HookSpecification(event: "SessionEnd")
            ]
        case .claude:
            return [
                HookSpecification(event: "SessionStart"),
                HookSpecification(event: "UserPromptSubmit"),
                HookSpecification(event: "PermissionRequest"),
                HookSpecification(event: "PostToolUse"),
                HookSpecification(
                    event: "Notification",
                    matcher: "idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|agent_completed"
                ),
                HookSpecification(event: "Stop"),
                HookSpecification(event: "StopFailure"),
                HookSpecification(event: "SessionEnd")
            ]
        }
    }
}

private struct HookSpecification {
    var event: String
    var matcher: String?
}

private enum LineDiff {
    static func render(before: String, after: String, file: String) -> String {
        guard before != after else { return "" }
        let oldLines = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard oldLines.count <= 2_000, newLines.count <= 2_000 else {
            return "--- \(file)\n+++ \(file) (proposed)\n@@ full file changed; diff omitted because it exceeds 2,000 lines @@\n"
        }

        var lengths = Array(
            repeating: Array(repeating: 0, count: newLines.count + 1),
            count: oldLines.count + 1
        )
        if !oldLines.isEmpty, !newLines.isEmpty {
            for oldIndex in stride(from: oldLines.count - 1, through: 0, by: -1) {
                for newIndex in stride(from: newLines.count - 1, through: 0, by: -1) {
                    lengths[oldIndex][newIndex] = oldLines[oldIndex] == newLines[newIndex]
                        ? lengths[oldIndex + 1][newIndex + 1] + 1
                        : max(lengths[oldIndex + 1][newIndex], lengths[oldIndex][newIndex + 1])
                }
            }
        }

        var result = ["--- \(file)", "+++ \(file) (proposed)", "@@"]
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count,
               newIndex < newLines.count,
               oldLines[oldIndex] == newLines[newIndex] {
                oldIndex += 1
                newIndex += 1
            } else if newIndex < newLines.count,
                      (oldIndex == oldLines.count
                        || lengths[oldIndex][newIndex + 1] >= lengths[oldIndex + 1][newIndex]) {
                result.append("+\(newLines[newIndex])")
                newIndex += 1
            } else if oldIndex < oldLines.count {
                result.append("-\(oldLines[oldIndex])")
                oldIndex += 1
            }
        }
        return result.joined(separator: "\n") + "\n"
    }
}
