# 本机验收记录

日期：2026-11-07。结论：**本机开发构建可运行，正式版验收未完成。**

本轮遵守用户最新边界：只完成 ChatGPT 登录和本机验证；真实模型推理调用为 0，SSH 远端连接为 0。原始架构文件保留，未创建或管理任何云实例。

## 已执行

| 验证 | 结果 | 证据/限制 |
| --- | --- | --- |
| SwiftPM 编译 | 通过 | 显式 Xcode 工具链/SDK；Swift 6；所有当前源代码模块及两个可执行文件 |
| 本机 app 打包/签名 | 通过 | `artifacts/local/NORMA.app`；ad-hoc；`codesign --verify --deep --strict` |
| Swift 单元/契约测试 | 24 项通过，0 失败 | `artifacts/local/validation/tests.log`；并发准入、门禁、CAS、不可变合同、主题、状态机、产物篡改、备份、隔离传输、确认/目标持久化 |
| Python Worker 契约测试 | 6 项通过，0 失败 | 同一日志；解析解/独立算法、尺度限制、非法签名、过期授权、环境漂移、幂等冲突、产物取回 |
| 已知解真实微型实验 | 通过 | `scripts/smoke-local.sh`；运行目录含 `smoke-report.json`、SQLite、内容寻址证据、Worker 清单和结果 |
| 数值结果 | slope=2, intercept=1, MSE=0 | 同一份五点输入；正向正规方程计算和独立中心化协方差计算各一次 |
| 证据关联 | 通过 | 6 个证据对象、8 条 derivedFrom 关联；对象 SHA256 复核；待派发 outbox=0 |
| I1/I2 数值检查 | pass/pass | I3/I4 为 unknown，不能导出正式研究；不声称数值验证具有科学创新性 |
| 原生应用/XPC/持久化 | 通过已测路径 | 实际通过界面创建课题；应用/服务重启仍恢复同一 UUID；修改经 XPC 到 SQLite |
| ChatGPT 登录 | Connected | 独立 NORMA profile；用户完成 MFA；原生 Keychain 模式；profile 内无 auth.json；不读取 token 内容 |
| 模型发现 | 已读取 | UI 找到 GPT-6.1-Sol；未执行 `turn/start` 的真实推理验收 |
| 本机环境 | 通过 | 系统 Python 3.9.6 arm64；只读发现，不安装依赖/容器 |
| 未授权门禁 | 已核对 | 未授权时“启动实验”不可用；冻结、确认、目标选择、预检在服务侧独立检查 |
| 主题/基本导航 | 部分通过 | 九个主页面浅/深截图；登录与预检 Sheet；见 screenshots 目录 |

单元/契约测试与真实微型实验分开记录。没有将完整测试套件当成 Smoke Test 扩大科研规模。迭代修复后仅对同一个五点问题重复验证；没有多种子、参数搜索、训练或大数据下载。

## 明确未通过或未验证

- `xcodebuild -list` 返回 69：Xcode 许可未接受。相应 Xcode 工程 build/test、XCUITest 均未通过验收。SwiftPM 编译/XCTest runner 结果不替代这些检查。
- 完整 ScientistTwo 自主科研编排未接通；真实模型预算由用户要求暂缓，不能将 Mock 或数值 Worker 当作真实六阶段科研链。
- I3/I4 全流程、正向正式导出、应用内备份恢复、通用实验代码执行、SSH Worker/租约/配额未完成或未验收。
- 所有 24 个设计画板及 1360×820、1440×900、1120×720 三种窗口尺寸的完整视觉验收未完成。当前主窗口截图为 2880×1740 像素（Retina 1440×870 点）。空数据页面截图不替代真实满载页面验收。
- 未执行长时间稳定性、内存压力、真正八模型并发、远端断线、所有服务崩溃点的恢复测试。
- 旧 ad-hoc 构建替换后发现 macOS 缓存旧后台服务登记，出现 EX_CONFIG。关闭应用，使用当前包注销服务并再次打开后恢复；这一开发分发问题仍需在正式签名构建中验证。
- macOS 14 最低目标已经声明，但实际运行平台是当前机器的 macOS 27.2，未在 macOS 14 真机测试。

## 可复查产物

- `artifacts/local/NORMA.app`
- `artifacts/local/validation/tests.log`
- `artifacts/local/validation/build.log`
- `artifacts/local/validation/xcodebuild-list.log`
- `artifacts/local/validation/source-manifest.json`
- `artifacts/local/validation/latest-smoke.txt`：最后一次真实 smoke 的绝对路径
- `artifacts/local/screenshots/`：本机实际捕获截图

完整发布待办和论文差异见 `docs/DESIGN_DIFFERENCES.md`。这些未完成事项不计为通过，也不把“当前本机可运行”表述为“正式版已交付”。
