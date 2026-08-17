import Foundation

public enum AgentTaskNavigation {
    public static func destinationURL(source: AgentSource, sessionID: String) -> URL? {
        guard source == .codex,
              !sessionID.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(sessionID)"
        return components.url
    }

    public static func terminalTTY(fromProcessOutput output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^ttys[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "/dev/\(value)"
    }
}
