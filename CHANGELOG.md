# Changelog

本项目采用 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 结构，版本号遵循语义化版本。只有实际创建并验证 GitHub Release 后，条目才能移动到带日期的已发布版本；当前条目不代表公开 Release 已存在。

## [Unreleased]

### Security

- 本地 API 默认要求 Keychain-backed 随机 token，支持 Bearer 与 `x-api-key`；旧任意占位 key 不再可用。
- 统一 `127.0.0.1` Host/Origin/认证边界，移除通配符 CORS；匿名健康接口只返回 `status` 与 `app`。
- 请求/响应正文记录默认关闭，同时清除正文派生的子任务摘要；保留旧配置中显式选择。
- Agent 配置预览脱敏，真实本地 token 与供应商密钥使用独立 Keychain 条目。

### Added

- AutoRoute 用户品牌、单一版本元数据、ad-hoc/Developer ID 构建分支、ZIP/SHA-256、公证和 Homebrew cask 自动化。
- Release CI 增加临时 keychain、Developer ID PKCS#12 私钥导入、签名 Authority 校验、notarytool profile 验证与清理；缺少完整 secrets 时明确拒绝发布。
- 预算达到预警阈值时显示非阻断提示；实测、估算、未定价口径与硬上限拒绝保持分离。
- A/B 报告升级为 `ab-report-v2`，记录 Agent、策略名与非敏感请求参数，并逐 attempt 拆分实测/估算成本。
- 真实 A/B 成本对照现在来自明确的 testBench/外部代理真实运行，但不计入外部代理 7 日活跃或延迟。
- Agent 恢复改为受管 provider/env/block 定向移除，保留接入后新增的外部配置；Shell env 使用受管区块标记。
- 本地 token 无法持久化时显示阻断性修复指引，并禁止自动代理与 Agent 写入。
- 正文记录关闭时，上游错误正文不再进入历史、健康备注或导出；Codex 注入不再要求 OpenAI 登录态。
- 预算排除 demo 消费，并改用独立持久化 ledger，UI 历史截断到 500 条后仍保留月度硬上限。
- 测试台移除旧的隐式单次基线旁路，只保留有 CallRecord、预算和追溯元数据的交错 A/B；真实 A/B 指标只接受双方 upstreamReported 实测成本。
- 全局与 Agent 预算预警统一使用 `MonthlyBudgetSettings.warningThreshold`，旧字段仅保留解码兼容。
- 损坏备份 manifest 时拒绝 apply/restore，已有原始 `.bak` 绝不被覆盖。
- `prepare_release_signing.sh` 限制为 CI-only，缺少 `GITHUB_ACTIONS=true` 时在触碰 Keychain 前退出。
- 清空历史会同步清空预算 ledger；持久化失败向上抛出并在 UI 显示，内存与磁盘状态保持一致。
- 真实 HTTP socket 首次验收，明确区分演示与真实完成；保留显式跳过。
- `auto/agent/<agent>` 稳定身份、按 Agent 策略优先级、收据元数据和会话粘性隔离。
- 本机自然月全局/Agent 硬预算及 `429 budget_exceeded`；实测、估算、未定价分开。
- 重复交错 A/B、独立会话、样例/策略/报告版本和脱敏 JSON 导出。
- 本地首次路由漏斗、7 日活跃、路由 p50/p95、跨模型恢复、成本对照与主动聚合导出。
- 英文/中文 README、Codex/Claude Code/OpenCode 教程、社区模板、发布清单和 Good First Issue 候选。

### Changed

- 用户可见应用和产物统一为 AutoRoute / `dist/AutoRoute.app`；内部 `AutoModel` 与 Bundle ID 保留以兼容升级。
- `/v1/models` 同时列出旧三档、稳定 Agent 别名和可用具体模型。
- 清空调用历史需要确认，并同时重置会话粘性和本地指标；供应商配置与 Keychain 密钥保留。

## 升级与回滚摘要

1. 升级前退出 Agent，记录当前端口，在 Agent 接入页确认存在备份；不要手动删除 Application Support 或 Keychain。
2. 安装新版本后检查旧配置、显式正文记录选择、三档手动覆盖、Agent 连接和历史迁移，再重新同步端口。
3. 本地 token 迁移后，所有客户端必须使用设置中的真实 token；旧占位 key 失效是预期安全变化。
4. 回滚应用前先恢复各 Agent 备份并停止代理。保留原配置目录；旧版本可能无法识别新增字段，不能假设新增 Agent 策略、预算、来源标记或指标向后兼容。
5. 完整命令与发布核对见 [docs/release/RELEASE_CHECKLIST.md](docs/release/RELEASE_CHECKLIST.md)。
