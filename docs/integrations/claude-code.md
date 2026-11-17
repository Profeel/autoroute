# Claude Code 接入 AutoRoute

## 一键接入（推荐）

1. 在 AutoRoute 启动代理并确认低/中/高档模型。
2. 打开“Agent 接入 → Claude Code”，检查脱敏预览后点击“备份并接入”。
3. 原 `~/.claude/settings.json` 会备份，已有 hooks 和其他设置保留；写入 Anthropic 地址、本地 token 和三档模型映射。
4. 重启 Claude Code，发送请求并检查 AutoRoute 的 `/v1/messages` 收据。

默认身份为 `auto/agent/claudeCode`；Haiku/Sonnet/Opus 分别映射到该身份的 `/low`、`/medium`、`/high`。策略与月度预算可按 Claude Code 独立设置。

## 手动接入

将 `<LOCAL_TOKEN>` 替换为 AutoRoute 设置中复制的真实本地 token。以下为相关字段示例，合入现有 JSON 时保留其他设置：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8765",
    "ANTHROPIC_AUTH_TOKEN": "<LOCAL_TOKEN>",
    "OPENAI_BASE_URL": "http://127.0.0.1:8765/v1",
    "ANTHROPIC_MODEL": "auto/agent/claudeCode",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "auto/agent/claudeCode/low",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "auto/agent/claudeCode/medium",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "auto/agent/claudeCode/high"
  }
}
```

注意 `ANTHROPIC_BASE_URL` 不带 `/v1`；AutoRoute 接收 `/v1/messages`，完成普通/SSE Anthropic 协议适配。不要把真实 token 写入公开文档或 Issue。

## 恢复

在 AutoRoute 的 Claude Code 卡片点击“断开并恢复备份”。该操作只恢复 Claude Code 配置，不删除供应商、调用历史或其他 Agent。恢复后重启 Claude Code。

## 故障排查

- **401 / 403**：确认 `ANTHROPIC_AUTH_TOKEN` 是本地随机 token，不是占位符；检查 shell 环境是否覆盖 settings.json。
- **404 / 协议错误**：确认 Base URL 路径没有重复 `/v1/v1`，客户端实际请求 `/v1/messages`，并记录 Claude Code 版本。
- **端口冲突**：在设置中更换端口、重启代理，再“一键同步 Agent 端口”或手动更新两个 Base URL。
- **429**：区分供应商额度与 AutoRoute 月度预算；`budget_exceeded` 在上游前本地拒绝。
- **预算**：按本机自然月、按 `claudeCode` 身份独立统计；在途请求和延迟 usage 仍可能超支。
- **报告兼容性问题时**：附脱敏收据、HTTP 状态、普通/SSE 和协议路径；不要提交 key、token、私有代码或消息正文。
