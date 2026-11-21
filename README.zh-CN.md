# AutoRoute

[English](README.md) · [MIT License](LICENSE) · [贡献指南](CONTRIBUTING.md) · [安全政策](SECURITY.md)

**AutoRoute** 是开源、原生 macOS 的本地多模型路由器。它仅在 `127.0.0.1` 提供 API，根据本机策略、请求能力和模型健康状态选择上游，把请求转发给你配置的供应商，并保留可核对的路由收据。

无需账号、无托管控制面、无强制遥测。供应商、额度与密钥由你自己管理。

## 核心能力

- `auto`、`auto/low`、`auto/medium`、`auto/high` 三档别名；省钱、均衡、质量三种策略。
- 硬约束优先：Tools、Vision、上下文、价格上限、健康状态、冷却、顺序回退和多轮会话粘性。
- Codex、Claude Code、OpenCode、Hermes、Shell/Continue 的预览、备份、一键接入与恢复。
- 稳定 Agent 身份，例如 `auto/agent/codex`，可追加 `/low`、`/medium`、`/high`；旧 `auto` 配置保持兼容。
- 路由收据区分路由耗时、TTFT、总耗时、上游实测用量、本地估算、重试成本、未定价和无用量。
- 全局与按 Agent 自然月预算、重复交错 A/B、脱敏报告和本地优先聚合指标。

## 均衡自动路由

使用 `auto` 或 Agent 的默认自动别名时，均衡策略按当前任务选择已配置的模型。

| 请求 | 目标档位 | 默认思考强度 |
| --- | --- | --- |
| 分类、提取、短摘要、简单检索 | 低档，如 Haiku 5.5 | `low` |
| 局部修改、按规格实现、文档、日常工具编排 | 中档，如 Sonnet 5.5 | `medium` |
| 开放式工程与分析、意图不明确的任务 | 高档，如 Opus 5.5 | `medium` |
| 架构设计、迁移、性能优化和疑难调试 | 高档 | `high` |

在「路由策略 → 稳定性与容错」开启会话阶段切换后，复杂任务可在新的用户回合升档，连续两个常规用户回合可降档。工具续跑优先保留同一模型。高档可手动绑定 Fable 5.2 等模型，实际候选受能力、健康状态、价格上限和用户配置约束。[Claude 选型指南](https://claude.dev/blog/which-claude-model-should-you-build-with/)

## 60 秒演示

演示脚本按“发现 → 接入 → 请求 → 收据 → 回退”操作，并说明如何录制真实屏幕。内置模拟上游只用于离线演示，不算真实路由成功或实测节省。

[查看 60 秒演示与录屏脚本](docs/demo/60-second-demo.md)。仓库不链接不存在的 GIF，也不提交伪造的“官方成绩”。

## 支持 Agent 与协议

教程：[Codex](docs/integrations/codex.md) · [Claude Code](docs/integrations/claude-code.md) · [OpenCode](docs/integrations/opencode.md)

| 本机接口 | 兼容范围 |
| --- | --- |
| `POST /v1/chat/completions` | OpenAI Chat Completions，普通 JSON 与 SSE |
| `POST /v1/responses` | OpenAI Responses，普通 JSON 与 SSE；需要时走原生 Responses 路由 |
| `POST /v1/messages` | Anthropic Messages，普通 JSON 与 SSE |
| `GET /v1/models` | 旧三档别名、稳定 Agent 别名和已启用具体模型 |
| `GET /health`、`GET /v1/health` | 仅返回最小匿名健康信息 |

支持文本、工具调用、视觉消息、思考内容分离/透传和 usage 提取。暂未实现 embeddings、图片生成、音频与 `n > 1`；不支持的参数返回明确错误，不静默忽略。

## 安装与构建

要求 macOS 14+、Swift 5.10+ 或 Xcode Command Line Tools。已在 Apple Silicon、Swift 6.2.3 环境验证本地开发构建。

```bash
git clone <你获授权的仓库地址> autoroute
cd autoroute
swift test
bash macos/build_app.sh
open dist/AutoRoute.app
```

产物为 `dist/AutoRoute.app`。未提供 `DEVELOPER_ID_APPLICATION` 时仅使用 **ad-hoc 本地开发签名**，不是公证发行版。Developer ID、公证、ZIP/SHA-256 和 Homebrew cask 生成见[发布清单](docs/release/RELEASE_CHECKLIST.md)；源码存在不代表公开 Release 已发布。

## 5 分钟快速开始

1. **连接提供商**：添加提供商和兼容模型，或主动发现本机配置。发现会读取受支持的 Agent 配置并测活已启用的上游，可能产生费用；新发现的提供商默认关闭，需手动启用。密钥存于 macOS Keychain。
2. **预览并接入一个 Agent**：核对托管配置后确认备份和写入；默认使用均衡策略和自动档位，也可恢复原配置。
3. **从 Agent 发出第一条请求**：重启 Agent 并发送普通请求；应用区分配置已写入和真实 Agent 请求已成功。独立 HTTP 验收、手动 curl、策略调整和模拟演示仍在高级选项中。

要使用 WorkBuddy 作为上游，在「提供商 → 添加 → 添加 API 提供商」中选择对应版本的预设，填入 API Key，保存后点击「测试连通性」导入账号可用的模型。[国内版 API Keys](https://www.workbuddy.cn/profile/keys) · [国际版 API Keys](https://www.workbuddy.ai/profile/keys)

```bash
export AUTOROUTE_BASE_URL='http://127.0.0.1:8765/v1'
export AUTOROUTE_API_TOKEN='粘贴从 AutoRoute 设置复制的本机 token'
curl -N "$AUTOROUTE_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $AUTOROUTE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "stream": true,
    "messages": [{"role": "user", "content": "用三句话解释 Raft 共识算法"}]
  }'
```

除最小健康检查外，所有接口都要求真实本地 token，可用 `Authorization: Bearer` 或 `x-api-key`。旧版本的任意占位 key 不再可用。

## 安全、隐私与预算

- 仅绑定 `127.0.0.1`，校验 Host/Origin，常量时间比较 token，不授予通配符 CORS。
- 供应商 Key 与本地 token 使用独立 Keychain 条目。不要提交 token、私有正文、未脱敏收据或配置备份。
- 本地 token 无法持久化到 Keychain 时，只保留每次启动重新生成的临时凭据，并阻断代理启动与 Agent 写入，直到显式修复并重试成功。
- 请求/响应正文记录默认关闭；旧配置中用户显式选择会保留。关闭时，正文派生的子任务摘要和上游错误正文都不持久化，只保留固定错误类别与 HTTP 状态。
- 历史、预算 ledger 与最小引导漏斗状态仅存本机。设置页可查看、确认清空并主动导出带 schema/definition 版本的聚合 JSON；清空持久化失败会显示错误，不会声称已删除。
- 指标不保存提示词、代码、响应、token 或广告式标识符，不额外发起网络请求；演示和旧版无法判别记录不混入真实路由指标。
- 月度预算使用独立持久化 ledger，不依赖最多 500 条的 UI 历史，早期消费仍会触达硬上限；明确标记为 demo 的消费不计入预算。设置预警阈值不阻断请求，只有达到硬上限才在上游前返回 `429 budget_exceeded`。在途并发、延迟 usage 和价格变化仍可能超支，请核对供应商账单。

安全报告见 [SECURITY.md](SECURITY.md)，验收合同见 [P0–P2 开发文档](docs/development/P0-P2-DEVELOPMENT.md)。

## 可复现 A/B 与费用口径

测试台只通过可审计的交错 A/B runner 将 `auto` 与固定基线按轮运行，每次使用独立会话；普通单次请求不会隐式调用基线。两侧均生成 CallRecord，并经过预算、usage 和重试计量。报告保存样例/策略/Agent 元数据、非敏感请求参数、模型、时间、重试、路由/TTFT/总耗时、usage 来源和费用状态。

报告逐 attempt 拆分实测与估算，估算重试不会混入实测差值；真实 A/B 成本指标只接受双方均为 upstreamReported 且无估算重试的配对。缺失 usage/价格不按 0 元。质量选择“未评估”时不能声称质量不下降。真实上游报告需由使用者产生，仓库没有伪造官方 benchmark。

## 测试、贡献与发布

```bash
swift test
bash macos/build_app.sh
git diff --check
codesign --verify --deep --strict dist/AutoRoute.app
bash macos/package_app.sh
```

CI 运行全部测试，不过滤安全、迁移、预算、A/B 或指标用例。请参阅[贡献指南](CONTRIBUTING.md)、[路线图](ROADMAP.md)、[变更日志](CHANGELOG.md)、[Good First Issue 候选](docs/community/GOOD_FIRST_ISSUES.md)和[发布清单](docs/release/RELEASE_CHECKLIST.md)。

## License

[MIT License](LICENSE)。为兼容升级，内部模块/可执行目标 `AutoModel` 和 Bundle ID `org.automodel.app` 保留；用户可见产品名为 AutoRoute。
