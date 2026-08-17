import Foundation
import Testing
@testable import RelayCore

@Suite("Agent task navigation")
struct AgentTaskNavigationTests {
    @Test
    func codexSessionBuildsExactThreadDeepLink() {
        let url = AgentTaskNavigation.destinationURL(
            source: .codex,
            sessionID: "synthetic-session-id"
        )

        #expect(url?.absoluteString == "codex://threads/synthetic-session-id")
    }

    @Test
    func unsupportedSourcesDoNotInventDeepLinks() {
        #expect(AgentTaskNavigation.destinationURL(source: .claude, sessionID: "session") == nil)
        #expect(AgentTaskNavigation.destinationURL(source: .cursor, sessionID: "session") == nil)
        #expect(AgentTaskNavigation.destinationURL(source: .generic, sessionID: "session") == nil)
    }

    @Test
    func emptyCodexSessionDoesNotBuildADeepLink() {
        #expect(AgentTaskNavigation.destinationURL(source: .codex, sessionID: "") == nil)
    }

    @Test
    func terminalTTYAcceptsOnlyBoundedMacTerminalIdentifiers() {
        #expect(
            AgentTaskNavigation.terminalTTY(fromProcessOutput: " ttys012\n")
                == "/dev/ttys012"
        )
        #expect(AgentTaskNavigation.terminalTTY(fromProcessOutput: "??") == nil)
        #expect(AgentTaskNavigation.terminalTTY(fromProcessOutput: "pts/1") == nil)
        #expect(AgentTaskNavigation.terminalTTY(fromProcessOutput: "ttys1\nmalicious") == nil)
    }
}
