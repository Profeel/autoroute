# Good First Issue 候选清单

以下只是维护者候选任务，**尚未创建 GitHub Issues**。创建前应确认仍适用于当前代码、范围足够小，并补充实际仓库链接。不要提交真实 key、token、私有正文或配置备份。

## 1. 文档：补充 Anthropic 流式错误示例

- **背景**：新用户难以区分本地认证失败、预算 429 与上游错误。
- **文件入口**：`docs/integrations/claude-code.md`、`Sources/AutoModelCore/ProxyServer.swift`。
- **预期行为**：增加三个脱敏错误示例和处理表，不改变协议代码，不复制真实响应正文。
- **验收命令**：`swift test --filter P2DocumentationTests && git diff --check`。

## 2. 测试：旧 CallRecord 缺失来源字段迁移

- **背景**：旧收据没有 `executionOrigin`，必须解码为未知而不是误判真实或 demo。
- **文件入口**：`Sources/AutoModelCore/Models.swift`、`Tests/AutoModelCoreTests/P2LocalMetricsTests.swift`。
- **预期行为**：删除 JSON 中该字段后可解码，指标计入 `unclassifiedRouteSampleCount`，真实/demo 数不增加。
- **验收命令**：`swift test --filter P2LocalMetricsTests`。

## 3. UI 文案：预算阈值输入错误可访问性

- **背景**：预算输入错误需要更清晰、可被 VoiceOver 朗读。
- **文件入口**：`Sources/AutoModel/BudgetSettingsCard.swift`。
- **预期行为**：不改预算口径；说明自然月、0–1 阈值和 429 行为，错误反馈具备 accessibility label。
- **验收命令**：`swift test --filter P1BudgetTests && bash macos/build_app.sh`，并附 VoiceOver 手测记录。

## 4. 测试：A/B 重试成本与失败样本

- **背景**：可控上游产生首次失败、备选成功时，报告要保留 retryCount 和全部实际成本。
- **文件入口**：`Sources/AutoModelCore/ABReport.swift`、`Tests/AutoModelCoreTests/P1ABReportTests.swift`。
- **预期行为**：失败与重试不错误计为 0 成本，缺价格仍无可比价对，交错和独立 session 不变。
- **验收命令**：`swift test --filter P1ABReportTests`。

## 5. 文档：本地指标定义示例

- **背景**：用户容易把单用户 7 日活跃误读为项目留存。
- **文件入口**：`README.zh-CN.md`、`Sources/AutoModelCore/LocalProductMetrics.swift`、`docs/demo/60-second-demo.md`。
- **预期行为**：用两个虚拟日期解释活跃天数、最近秩 p50/p95 和旧版未知记录，不添加虚构产品数据。
- **验收命令**：`swift test --filter P2 && git diff --check`。

## 6. 集成测试：OpenCode 非托管 provider 保留

- **背景**：一键接入必须保留用户其他 provider，恢复不能被新别名破坏。
- **文件入口**：`Sources/AutoModelCore/AgentConfigService.swift`、`Tests/AutoModelCoreTests/AutoModelTests.swift`。
- **预期行为**：以临时 HOME 和哨兵 token 验证备份、接入、再次接入、恢复，其他 JSON 字段不变。
- **验收命令**：`swift test --filter AutoModelTests.testMagpieStyleAgentAutoConfigAndBackupRestore`。
