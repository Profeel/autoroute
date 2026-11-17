# Codex 接入 AutoRoute

## 一键接入（推荐）

1. 在 AutoRoute 配置健康模型、三档和策略，启动本地代理。
2. 打开“Agent 接入”，选择 **Codex**。先查看预览；预览中的本地 token 显示为 `[REDACTED_LOCAL_TOKEN]`。
3. 点击“备份并接入”。原 `~/.codex/config.toml` 会备份到 AutoRoute 的本地 `agent_backups` 目录，已有非托管 section 保留。
4. 重启 Codex，发送一个普通请求，再在 AutoRoute 路由收据核对实际模型、协议、耗时和费用。

默认稳定模型身份为 `auto/agent/codex`；可选 `auto/agent/codex/low`、`/medium`、`/high`。该身份支持 Codex 独立策略与预算，不污染其他 Agent 的会话粘性。显式档位或具体模型仍可覆盖默认 Agent 策略。

## 手动接入

在“设置”复制真实本地 token，并替换下面的 `<LOCAL_TOKEN>`。不要把含真实 token 的文件提交到 Git 或粘贴到 Issue。

```toml
# ~/.codex/config.toml
model = "auto/agent/codex"
model_provider = "autoroute"

[model_providers.autoroute]
name = "AutoRoute"
base_url = "http://127.0.0.1:8765/v1"
wire_api = "responses"
requires_openai_auth = true
http_headers = { "Authorization" = "Bearer <LOCAL_TOKEN>" }
```

AutoRoute 的 Responses 路由会保留需要原生 Responses 的能力；普通 function calls 仍可使用 Chat 兼容路径。

## 恢复

在“Agent 接入 → Codex”点击“断开并恢复备份”。恢复前仍可预览；操作只还原该 Agent 的备份，不清空供应商、模型、历史或其他 Agent。若手动修改过配置，先另存副本再恢复。

## 故障排查

- **401 / 403**：不要使用任意占位 key。重新复制本地 token，或重新一键接入；检查 Authorization 是否被旧环境变量覆盖。
- **400 `unknown_agent_alias`**：使用小写精确别名 `auto/agent/codex`，不要写 `auto/agent/CODEX` 或不存在的 Agent。
- **端口冲突**：在 AutoRoute 设置应用新端口并重启代理，然后点击“一键同步 Agent 端口”或更新 `base_url`；重启 Codex。
- **上游 401/429**：这与本地 token 不同。检查供应商 Keychain 密钥、额度及“月度预算”；本地硬预算会返回 `429 budget_exceeded`。
- **无响应或协议错误**：保留脱敏收据，记录 Codex 版本、`/v1/responses`、是否流式及实际执行模型；不要提交提示词、代码、响应正文或 token。

预算按本机自然月统计。达到上限只阻止新请求，在途请求、延迟 usage 和价格变化仍可能超支，请同时核对供应商账单。
