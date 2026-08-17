import AppKit
import Foundation
import RelayCore

@MainActor
final class TerminalTaskTitleResolver {
    private var cachedTitles: [String: String] = [:]
    private var cachedProcessIDs: [String: Int32] = [:]
    private var refreshedAt = Date.distantPast

    func resolve(
        processIDsBySessionKey: [String: Int32],
        now: Date = Date()
    ) -> [String: String] {
        if processIDsBySessionKey == cachedProcessIDs,
           now.timeIntervalSince(refreshedAt) < 5 {
            return cachedTitles
        }

        let ttyBySessionKey = processIDsBySessionKey.compactMapValues(tty(for:))
        let titlesByTTY = readTerminalTitles(for: Set(ttyBySessionKey.values))
        cachedTitles = ttyBySessionKey.reduce(into: [:]) { result, item in
            guard let rawTitle = titlesByTTY[item.value],
                  let title = TerminalTaskTitleParser.taskTitle(from: rawTitle) else { return }
            result[item.key] = title
        }
        cachedProcessIDs = processIDsBySessionKey
        refreshedAt = now
        return cachedTitles
    }

    func focusTerminalTab(processID: Int32) -> Bool {
        guard let tty = tty(for: processID) else { return false }
        let script = """
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if (tty of terminalTab as text) is "\(tty)" then
                        set selected tab of terminalWindow to terminalTab
                        set index of terminalWindow to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
            return false
        end tell
        """

        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              error == nil else { return false }
        return descriptor.booleanValue
    }

    private func tty(for processID: Int32) -> String? {
        guard processID > 0 else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(processID)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let value = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentTaskNavigation.terminalTTY(fromProcessOutput: value)
        } catch {
            return nil
        }
    }

    private func readTerminalTitles(for ttys: Set<String>) -> [String: String] {
        let validTTYs = ttys
            .filter { $0.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil }
            .sorted()
        guard !validTTYs.isEmpty else { return [:] }

        let requestedTTYs = validTTYs
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        let script = """
        tell application "Terminal"
            set requestedTTYs to {\(requestedTTYs)}
            set outputText to ""
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    set tabTTY to tty of terminalTab as text
                    if tabTTY is in requestedTTYs then
                        set tabTitle to custom title of terminalTab as text
                        set outputText to outputText & tabTTY & "|||" & tabTitle & linefeed
                    end if
                end repeat
            end repeat
            return outputText
        end tell
        """

        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              error == nil else { return [:] }

        return result.split(whereSeparator: \.isNewline).reduce(into: [:]) { titles, line in
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4,
                  parts[1].isEmpty,
                  parts[2].isEmpty else { return }
            let tty = String(parts[0])
            guard validTTYs.contains(tty) else { return }
            titles[tty] = String(parts[3])
        }
    }
}
