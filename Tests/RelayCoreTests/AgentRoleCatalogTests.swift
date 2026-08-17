import Testing
@testable import RelayCore

@Suite("Agent role catalog")
struct AgentRoleCatalogTests {
    @Test
    func approvedCatalogContainsEightRolesPerApprovedGroup() {
        #expect(AgentRoleCatalog.approvedConcepts.count == 24)
        #expect(AgentRoleCatalog.approvedConcepts.filter { $0.group == .core }.count == 8)
        #expect(AgentRoleCatalog.approvedConcepts.filter { $0.group == .coding }.count == 8)
        #expect(AgentRoleCatalog.approvedConcepts.filter { $0.group == .cloud }.count == 8)
        #expect(AgentRoleCatalog.approvedConcepts.filter { !$0.isApprovedConcept }.isEmpty)
    }

    @Test
    func settingsCatalogAddsPiAndGenericWithoutClaimingApproval() {
        #expect(AgentRoleCatalog.all.count == 26)
        #expect(AgentRoleCatalog.role(id: "pi")?.displayName == "Pi")
        #expect(AgentRoleCatalog.role(id: "pi")?.group == .core)
        #expect(AgentRoleCatalog.role(id: "pi")?.isApprovedConcept == false)
        #expect(AgentRoleCatalog.role(id: "pi")?.runtimeAssetName == "pi-spirit-v1")
        #expect(AgentRoleCatalog.role(id: "generic")?.displayName == "其他 Agent")
        #expect(AgentRoleCatalog.role(id: "generic")?.group == .other)
        #expect(AgentRoleCatalog.role(id: "generic")?.isApprovedConcept == false)
        #expect(AgentRoleCatalog.role(id: "generic")?.runtimeAssetName == "generic-spirit-v3")
    }

    @Test
    func onlyPreparedRolesClaimDedicatedRuntimeAssets() {
        let assetRoles = AgentRoleCatalog.all.filter { $0.runtimeAssetName != nil }
        #expect(assetRoles.map(\.id) == ["codex", "claude-code", "cursor", "deepseek", "pi", "generic"])
    }
}
