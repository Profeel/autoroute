# OpenCode 接入 AutoRoute

## 一键接入（推荐）

1. 在 AutoRoute 配置模型和策略并启动代理。
2. 打开“Agent 接入 → OpenCode”，查看脱敏预览并点击“备份并接入”。
3. 原 `~/.config/opencode/opencode.json` 会备份；已有其他 provider 保留，AutoRoute 管理 `provider.automodel`。
4. 重启 OpenCode，发送请求并核对路由收据。

默认模型为 `automodel/auto/agent/opencode`，轻量模型为 `automodel/auto/agent/opencode/low`。另可用 `/medium`、`/high`。OpenCode 身份有独立策略、会话粘性命名空间和月度预算。

## 手动接入

把 `<LOCAL_TOKEN>` 替换为设置中复制的本地 token。以下只展示托管字段；合入现有配置时保留其他 provider：

```json
{
  "provider": {
    "automodel": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "AutoRoute Local Router",
      "options": {
        "baseURL": "http://127.0.0.1:8765/v1",
        "apiKey": "<LOCAL_TOKEN>"
      },
      "models": {
        "auto/agent/opencode": {
          "name": "AutoRoute OpenCode",
          "limit": { "context": 200000, "output": 16384 }
        }
      }
    }
  },
  "model": "automodel/auto/agent/opencode",
  "small_model": "automodel/auto/agent/opencode/low"
}
```

不要把含真实 token 的配置提交到 Git、Issue 或公开日志。

## 恢复

在“Agent 接入 → OpenCode”点击“断开并恢复备份”。恢复只影响 OpenCode，不清空 AutoRoute 供应商、历史或其他 Agent；恢复后重启 OpenCode。

## 故障排查

- **401 / 403**：`options.apiKey` 必须是 AutoRoute 本地 token，不能使用任意占位 key。
- **模型不存在**：模型名需同时包含 provider 前缀，例如 `automodel/auto/agent/opencode`；未知 Agent 别名会返回 `400 unknown_agent_alias`。
- **端口冲突**：在 AutoRoute 设置中换端口并重启代理，然后“一键同步 Agent 端口”或修改 `options.baseURL`。
- **429 / 预算**：检查供应商额度和 OpenCode 月度预算。硬上限在调用上游前生效，但在途请求、延迟 usage 和价格变化仍可能超支。
- **Tools / SSE 问题**：记录 OpenCode 版本、请求协议、是否流式、实际模型和脱敏收据；不要附提示词、代码、响应正文、API Key 或 token。
