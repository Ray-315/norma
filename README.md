# NORMA

macOS 原生科研工作站的开发版本。**当前不是正式发布版，也没有完成 ScientistTwo 全链路验收。**

当前可运行部分包括 SwiftUI 三栏窗口、主题系统、独立 LaunchAgent/XPC 服务、GRDB/WAL 持久化、隔离 ChatGPT 登录、本机只读环境检测，以及带授权和证据追踪的五点数值实验。六阶段科研状态机与角色执行组件已建立，但尚未接成完整自主科研运行器。

## 当前授权

- 仅本机验证，不连接 SSH 服务器。
- ChatGPT 登录已完成；模型推理调用等待用户另行授权。
- 预设模型为 `gpt-6.1-sol`、`medium`；实际可用性由 `model/list` 确认，不静默替换模型。
- 本机实验入口限定为内置最小二乘验证；授权中的模型预算固定为 0。
- 不读取或覆盖用户原有 `~/.codex`。

## 构建和运行

此机器实际为 macOS，使用已有 zsh、Xcode、XcodeGen、系统 Python；没有创建 Python 环境或安装模型。

```sh
cd /Users/mac/Documents/ChatGPT/Norma
zsh scripts/build-local.sh
open artifacts/local/NORMA.app
```

本机脚本显式使用已安装的 Xcode 27.2 工具链及 SDK，以 Swift 6 模式构建，不改变全局 `xcode-select`。产物为本机 ad-hoc 签名的开发包，不是公证分发包。构建前关闭应用；如果有 running/cancelPending/unknown 任务，脚本拒绝替换后台服务。

重签名开发包后，macOS 偶尔保留旧的后台程序登记，表现为服务 EX_CONFIG、界面无数据。关闭 NORMA，在没有执行中任务时运行以下命令，再重新打开应用：

```sh
artifacts/local/NORMA.app/Contents/MacOS/NORMA --unregister-service
open artifacts/local/NORMA.app
```

Xcode 工程由 `project.yml` 生成：

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -list -project NORMA.xcodeproj
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project NORMA.xcodeproj -scheme NORMA -destination 'platform=macOS' build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project NORMA.xcodeproj -scheme NORMA -destination 'platform=macOS' test
```

**本机 Xcode 许可尚未接受，以上 xcodebuild 验收未通过。** 许可应由用户在 Xcode 或 `sudo xcodebuild -license` 中亲自审阅和决定。SwiftPM 工具链构建成功不等于 Xcode 工程验收成功。

## 验证

```sh
zsh scripts/test-local.sh
zsh scripts/smoke-local.sh
```

第一条运行独立的 Swift 单元/契约测试与 Python Worker 契约测试，不调用真实模型。第二条只验证 `y = 2x + 1` 的五个点，1 batch、1 seed、0 training steps，包含一次独立方法复现；不下载数据或模型。每次结果写入新的 `artifacts/local/smoke-*` 目录，45 秒超时。不会写入日常应用研究库。

测试脚本使用已安装 Xcode 中的 XCTest 运行器；不将此结果记为 `xcodebuild test` 或 UI 测试通过。

## 代码与数据

| 目录 | 内容 |
| --- | --- |
| `apps/` | SwiftUI 应用、独立 XPC 后台服务 |
| `packages/ResearchContracts` | DTO、授权、计划、运行、证据契约 |
| `packages/ResearchStore` | 事务、版本冲突、事件、outbox、证据图和调用检查点 |
| `packages/ResearchKernel` | 公平调度、六阶段状态机、本机执行、备份与导出门禁 |
| `packages/CodexBridge`, `AuthCoordinator`, `AgentRuntime` | 隔离认证、JSONL 协议、角色线程和取消 |
| `packages/ComputeController`, `ExperimentManager`, `EvidenceEngine` | 环境检测、执行门禁、产物校验 |
| `packages/NORMAClient`, `NORMAUI` | XPC 客户端、显式 Demo Provider、原生页面与主题 |
| `workers/experiment-runner` | 受限 Python 数值 Worker |
| `specs/` | 论文参数契约和本机 Codex 生成的 JSON Schema |
| `docs/` | 架构修订与验收/差异记录 |

应用数据位于 `~/Library/Application Support/NORMA`。ChatGPT 与 API profile 分开存放，认证由 Codex 原生 Keychain 管理。研究备份仅包含数据库和被引用的内容寻址证据，不包含认证 profile、Keychain 或 Worker 签名密钥。备份校验已实现；完整应用内恢复流程尚未完成。

证据不足、状态未知、模型预算为零时均不能生成“正式成功”结果。数值 smoke 的 I3/I4 保持 unknown，不能通过正式论文导出门禁。

发布前必须关闭的缺口见 [验收记录](docs/VALIDATION.md) 和 [设计差异](docs/DESIGN_DIFFERENCES.md)。
