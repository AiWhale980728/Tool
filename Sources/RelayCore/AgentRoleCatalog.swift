import Foundation

public enum AgentRoleGroup: String, CaseIterable, Sendable {
    case core
    case coding
    case cloud
    case other

    public var displayName: String {
        switch self {
        case .core: "核心 Agent"
        case .coding: "编程 Agent"
        case .cloud: "云端 Agent"
        case .other: "其他"
        }
    }
}

public struct AgentRoleDefinition: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var group: AgentRoleGroup
    public var identityDescription: String
    public var source: AgentSource?
    public var runtimeAssetName: String?
    public var isApprovedConcept: Bool

    public init(
        id: String,
        displayName: String,
        group: AgentRoleGroup,
        identityDescription: String,
        source: AgentSource? = nil,
        runtimeAssetName: String? = nil,
        isApprovedConcept: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.group = group
        self.identityDescription = identityDescription
        self.source = source
        self.runtimeAssetName = runtimeAssetName
        self.isApprovedConcept = isApprovedConcept
    }
}

public enum AgentRoleCatalog {
    public static let approvedConcepts: [AgentRoleDefinition] = [
        .init(id: "codex", displayName: "Codex", group: .core, identityDescription: "白色折纸狐与几何制图工具", source: .codex, runtimeAssetName: "codex-spirit-v2", isApprovedConcept: true),
        .init(id: "claude-code", displayName: "Claude Code", group: .core, identityDescription: "珊瑚色纸墨飞蛾、书本与墨水瓶", source: .claude, runtimeAssetName: "claude-spirit-v2", isApprovedConcept: true),
        .init(id: "cursor", displayName: "Cursor", group: .core, identityDescription: "石墨色雨燕与紫色编辑轨迹", source: .cursor, runtimeAssetName: "cursor-spirit-v2", isApprovedConcept: true),
        .init(id: "gemini", displayName: "Gemini", group: .core, identityDescription: "蓝紫色双生水晶星与银色轨道", isApprovedConcept: true),
        .init(id: "kimi", displayName: "Kimi", group: .core, identityDescription: "深蓝月猫、望远镜与提灯", isApprovedConcept: true),
        .init(id: "deepseek", displayName: "DeepSeek", group: .core, identityDescription: "深海蓝鲸与探险提灯", runtimeAssetName: "deepseek-spirit-v2", isApprovedConcept: true),
        .init(id: "grok", displayName: "Grok", group: .core, identityDescription: "炭黑宇宙刺猬与克制的蓝色火花", isApprovedConcept: true),
        .init(id: "opencode", displayName: "OpenCode", group: .core, identityDescription: "暖灰寄居蟹工坊与鼠尾草色工具", isApprovedConcept: true),

        .init(id: "github-copilot", displayName: "GitHub Copilot", group: .coding, identityDescription: "炭黑与薄荷色双猫头鹰导航员", isApprovedConcept: true),
        .init(id: "windsurf", displayName: "Windsurf", group: .coding, identityDescription: "海沫绿信天翁与折叠航图", isApprovedConcept: true),
        .init(id: "cline", displayName: "Cline", group: .coding, identityDescription: "锈红与鼠尾草色山羊工程师", isApprovedConcept: true),
        .init(id: "roo-code", displayName: "Roo Code", group: .coding, identityDescription: "赭色袋鼠信使与任务纸条", isApprovedConcept: true),
        .init(id: "continue", displayName: "Continue", group: .coding, identityDescription: "苔绿色陆龟与连续路径线", isApprovedConcept: true),
        .init(id: "aider", displayName: "Aider", group: .coding, identityDescription: "暖红熊猫结对程序员与补丁纸带", isApprovedConcept: true),
        .init(id: "warp", displayName: "Warp", group: .coding, identityDescription: "深蓝蝠鲼导航员与薄荷色水流", isApprovedConcept: true),
        .init(id: "trae", displayName: "TRAE", group: .coding, identityDescription: "浅蓝仙鹤架构师与纸质模块", isApprovedConcept: true),

        .init(id: "devin", displayName: "Devin", group: .cloud, identityDescription: "灰蓝海狸建造者与桥梁蓝图", isApprovedConcept: true),
        .init(id: "manus", displayName: "Manus", group: .cloud, identityDescription: "炭黑与象牙白纸艺章鱼协调者", isApprovedConcept: true),
        .init(id: "replit-agent", displayName: "Replit Agent", group: .cloud, identityDescription: "柔和珊瑚色浣熊工坊与模块积木", isApprovedConcept: true),
        .init(id: "jules", displayName: "Jules", group: .cloud, identityDescription: "浅蓝松鸦信使与验收清单", isApprovedConcept: true),
        .init(id: "amazon-q", displayName: "Amazon Q", group: .cloud, identityDescription: "暖赭色短尾矮袋鼠图书管理员", isApprovedConcept: true),
        .init(id: "junie", displayName: "Junie", group: .cloud, identityDescription: "鼠尾草绿小鹿学徒与制图尺", isApprovedConcept: true),
        .init(id: "lovable", displayName: "Lovable", group: .cloud, identityDescription: "灰粉爱情鸟架构师与纸房子", isApprovedConcept: true),
        .init(id: "bolt", displayName: "Bolt", group: .cloud, identityDescription: "柔金野兔机械师与模块框架", isApprovedConcept: true)
    ]

    public static let pi = AgentRoleDefinition(
        id: "pi",
        displayName: "Pi",
        group: .core,
        identityDescription: "蓝白折纸变色龙工程师与多工具背包",
        runtimeAssetName: "pi-spirit-v1",
        isApprovedConcept: false
    )

    public static let generic = AgentRoleDefinition(
        id: "generic",
        displayName: "其他 Agent",
        group: .other,
        identityDescription: "象牙白折纸向导、提灯与折叠地图",
        source: .generic,
        runtimeAssetName: "generic-spirit-v3",
        isApprovedConcept: false
    )

    public static let all: [AgentRoleDefinition] = approvedConcepts + [pi, generic]

    public static func role(id: String) -> AgentRoleDefinition? {
        all.first { $0.id == id }
    }
}
