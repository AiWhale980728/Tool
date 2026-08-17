<h1 align="center">Notch Relay</h1>

<p align="center">
  面向 macOS 的 AI-native、跨 Agent Supervisor。<br>
  用确定性 Harness 观察任务，用有界证据复核结果，把真正需要判断的决定交还给人。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square&logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-6.2%20compatible-f05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2 compatible">
  <img src="https://img.shields.io/badge/local--first-privacy-168f91?style=flat-square" alt="Local-first privacy">
  <img src="https://img.shields.io/badge/license-noncommercial-d63d4b?style=flat-square" alt="Noncommercial license">
</p>

<p align="center">
  <a href="#五分钟本地运行"><strong>五分钟本地运行</strong></a>
  ·
  <a href="#隐私边界"><strong>隐私边界</strong></a>
  ·
  <a href="https://github.com/HiWhaleW/notch-relay/issues"><strong>反馈问题</strong></a>
</p>

> [!IMPORTANT]
> **Experimental MVP · 仅限非商业用途。** 当前交付物是确定性 Agent Harness、原生 macOS
> Supervisor Shell 和有界 Completion Review Shadow Runtime，不是生产级自动审批系统。模型只能给出
> 建议，不能绕过身份、时效、授权、确定性策略或人工决定。

## Notch Relay 是什么

Notch Relay 帮助同时使用 Codex、Claude Code 等 Agent 的人回答三类问题：

- 哪些任务仍在工作，哪些任务正在等待输入或权限？
- Agent 声称结束时，现有证据是否足以支持“已经完成”？
- 哪些风险或证据缺口需要人现在介入？

刘海 Launcher、菜单栏入口和三栏工作台只是交互表面。产品核心是：

> Supervisor Loop Engineering built on a deterministic Agent Harness, supported by Context,
> Evaluation, and Policy/Safety Engineering.

Notch Relay 不是通用刘海工具、任务看板、Agent runtime、IDE、终端复用器或自动授权工具。它监督用户
已经选择的 Agent，不替代它们，也不替人批准权限。

## 当前实现状态

| 能力 | 状态 | 已有边界与剩余缺口 |
| --- | --- | --- |
| Agent Harness | `已实现` | Codex、Claude Code Hook 接入；白名单事件、原子队列、重放、去重、隔离与确定性状态投影。 |
| 原生 macOS Shell | `已实现` | 刘海 Launcher、菜单栏、三栏工作台、任务返回、任务优先级与单实例保护。正式接入的 Agent 目前只有 Codex 与 Claude Code。 |
| Completion Review Shadow Runtime | `部分实现` | 用户逐次确认目标、验收标准、证据和精确 Provider 后，才可手动触发结构化复核；在线模型质量、延迟、成本和自动触发尚未形成生产验收。 |
| 本地与 CI Evidence adapters | `部分实现` | 已包含 Git、GitHub CI、Swift、Python unittest、pytest、项目本地 Jest、Cargo nextest 及用户选择的 Artifact 路径；部分外部工具链与真实项目组合仍待扩大验收。Artifact 只证明文件存在与基本格式有效。 |
| 独立 AI Evaluator | `部分实现` | 必须使用与 Supervisor 不同的模型，只能并列复核结构化 assessment；生产 Gold Set、阈值与在线 calibration 尚未完成。 |
| OpenJudge + Label Studio 评测边缘 | `部分实现` | 固定版本的离线/CI adapter、匿名导出和 synthetic 合同已验证；真实授权数据集和生产阈值仍未建立。 |
| 生产分发 | `未开发` | Developer ID、Hardened Runtime、公证、正式安装器、自动更新和完整无障碍验收尚未完成。 |

> [!NOTE]
> 公开源码不包含 Notch Relay 的两份产品系统 Prompt。它们由开发者本地、被 Git 忽略的 Private Prompt
> Pack 注入；缺少该 Pack 时，AI Completion Review 会在任何网络请求前停止并安全降级为
> Harness-only，其余确定性 Harness 功能仍可构建和运行。

测试、schema、fixture、角色图片或单个证据适配器只证明相应组件，不等于完整 Supervisor Loop 已经生产
就绪。

## Supervisor Loop

```text
Codex / Claude Code Hooks
  -> metadata allowlist
  -> append-only event queue
  -> deterministic state projection
  -> bounded context and evidence
  -> AI Completion Review (shadow)
  -> deterministic evaluator and policy gate
  -> optional independent AI evaluator
  -> human decision
```

Provider 事实、Evidence、模型推断、独立 Evaluator 结果、确定性策略和人工决定分别存放、分别校验，
不能互相冒充。模型输出不会直接写入 canonical state。

## 你现在可以做什么

- 通过受管 Hook 本地观察 Codex 与 Claude Code 生命周期、提问、权限、失败和待复核状态。
- 在刘海 Launcher、菜单栏和工作台查看任务，并返回准确的 Codex 任务或有界的 Claude Code Terminal
  会话。
- Codex 同名当前任务会按有界标题更新时间在展示层去重；writer lock 只证明 writer 已加载，不冒充
  精确 active/idle 状态。
- Codex 额度只展示主订阅窗口；当前任务模型来自 Hook 的精确 `model` 元数据，并可在本地只读显示
  最新日与累计 Token 汇总。模型专项限额桶不会再被当成当前模型。
- 对最新 `Ready to review` 结果补充目标和逐条验收标准，先检查完整 Consent Preview，再手动运行
  Completion Review。
- 逐次选择本地验证与 Artifact evidence；原始测试输出、文件路径、文件名和 Artifact 内容不会进入
  Provider 请求。
- 让确定性 Evaluator 检查证据覆盖、风险、不确定性、身份和过期时间；需要时再运行不同模型的独立
  AI Evaluator。
- 在本地确认完成、删除单个任务的 review 数据，或在任何模型故障时继续使用 Harness-only fallback。

Notch Relay 不会替你点击 Agent 的 Allow/Deny，不会自动执行 Agent 工具，也不会把“Agent 停止”直接
写成“任务完成”。

Codex 的 `PermissionRequest` 也不自动等于“仍在等人审批”：`mcp__codex_apps__*` 连接器检查保持工作中，
只有受支持且能证明需要人工决定的权限请求才进入待审批状态。

## 五分钟本地运行

### Requirements

- macOS 13 或更高版本
- Swift 6.2-compatible toolchain

克隆、验证并从源码启动：

```bash
git clone https://github.com/HiWhaleW/notch-relay.git
cd notch-relay
swift build
./scripts/verify.sh
swift run NotchRelayApp
```

2026-08-17 的验证基线为 **237 tests / 40 suites**。这证明当前确定性代码与 synthetic evaluation
合同通过本地验证，不代表在线模型质量、Provider 数据处理、签名、公证或干净 Mac 分发已经验收。

生成本地临时签名的 App bundle：

```bash
./scripts/package-local-app.sh
```

产物位于 `.build/local-app/Notch Relay.app`。它只用于本地开发与验收，不是正式发布安装包。

## 安全接入 Agent Hooks

克隆、构建或启动 App 都不会自动修改 Agent 配置。先只读预览：

```bash
.build/debug/relayctl integration preview
```

确认精确 diff 和回滚范围后，才显式应用：

```bash
.build/debug/relayctl integration install --apply
.build/debug/relayctl doctor
```

卸载同样默认只预览；`--apply` 只移除带 Notch Relay ownership marker 的内容，并保留备份：

```bash
.build/debug/relayctl integration uninstall
.build/debug/relayctl integration uninstall --apply
```

## 隐私边界

Notch Relay local-first 运行，不提供 Relay 云账号、远端数据库或监听网络端口。canonical event 使用显式
metadata allowlist，不保存：

- prompt、transcript、模型原始响应或 source code；
- 文件内容、原始命令、tool arguments、tool results 或详细错误；
- API Key、Token、Cookie、Credential 或环境变量内容。

真实模型调用默认关闭。只有在用户配置功能与精确远端 Provider、将 Key 存入 macOS Keychain、检查
逐次 Consent Preview 并点击复核后，才会发送有界目标、验收标准和结构化 evidence 摘要。用户选择的
Artifact 路径只存在于工作台内存；Provider 不接收文件内容、文件名、路径或本地 SHA-256 reference。

高置信敏感文本扫描可以阻断常见密钥、私钥、连接串和粘贴源码，但不能证明任意文本绝对安全。不要把
秘密、源码或私人内容粘贴到目标、验收标准或结果摘要中。

详见 [SECURITY.md](SECURITY.md)。报告安全问题时，不要在公开 Issue 中提交密钥、私人 prompt、本地
路径或利用细节。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/RelayCore/` | canonical Harness、状态投影、接入与 Supervisor contracts/runtime |
| `Sources/NotchRelayApp/` | 原生 macOS Launcher、菜单栏、工作台和 Completion Review UI |
| `Sources/RelayCLI/` | `relayctl` ingestion、daemon、诊断和 preview-first integration CLI |
| `Tests/RelayCoreTests/` | 确定性状态、隐私边界、evidence、policy、runtime 与 UI projection 测试 |
| `Evaluation/OpenJudge/` | 与 App 隔离的固定版本离线/CI 指标 adapter |
| `Evaluation/LabelStudio/` | 与 App 隔离的本地标注、共识/仲裁与匿名导出合同 |
| `scripts/` | 全量验证、来源审计、本地打包与 evaluation smoke 脚本 |

依赖来源、固定版本与许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## License

Notch Relay 采用 [PolyForm Noncommercial License 1.0.0](LICENSE)，仅允许许可证定义范围内的非商业
用途。商业使用不被允许；若本摘要与正式许可证文本不一致，以许可证文本为准。
