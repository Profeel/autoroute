# Auto Model

[MIT License](LICENSE)

**Auto Model** 是一款开源的原生 macOS 多模型路由 App。它运行在用户本机的 `127.0.0.1` 上，作为 OpenAI 兼容的本地 API 代理：你在自己的 AI 客户端里填写本机地址并将模型设为 `auto`，Auto Model 会根据用户配置的策略和请求特征在本机完成模型选择并转发请求，并在 Mac App 中为你保留一张可核对的「**路由收据**」。

开源版无需注册账号、无需连接托管服务、无强制遥测。

---

## 核心特性（v1）

- **原生 macOS App (SwiftUI + AppKit)**：主窗口 + 菜单栏状态入口，自适应系统浅色/深色外观。
- **供应商与模型目录**：接入任意 OpenAI 兼容模型厂商、中转站或本地服务（如 Ollama / LM Studio / vLLM）；支持测试连通性与自动拉取 `/v1/models`。
- **本机模型自动发掘与主动测活剔除**：自动扫描本机已配置的 OpenCode、Codex CLI、LM Studio、Ollama 等模型配置与本地 OpenAI 端口；通过实际轻量请求测活，自动剔除额度耗尽、已下线或超时的不可用模型。
- **低 / 中 / 高三档模型配置与用户自定义**：基于测活可用模型自动推荐并分配 **低档 (`auto/low`)**、**中档 (`auto/medium`)**、**高档 (`auto/high`)** 模型；支持在界面随时下拉修改任意档位，不可用模型被剔除时自动替补健康模型。
- **类 Magpie 多 Agent 一键配置**：自动检测 `~/.codex/config.toml`、`~/.config/opencode/opencode.json`、`~/.hermes/config.yaml`、`~/.claude/settings.json` 及 Shell/Continue 环境，支持自定义每个 Agent 绑定的模型/档位、安全备份原配置并一键注入本地网关，随时一键断开恢复原始配置。
- **API Key 安全保存**：所有供应商密钥均保存在 **macOS Keychain**，绝不写入配置文件、调用历史或导出收据。
- **本机确定性路由器**：
  - 先按硬约束过滤（启用状态、供应商可用性、`tools` 能力、`vision` 能力、上下文上限、输入/输出价格上限）。
  - 开箱即用三套策略：**省钱优先**、**均衡模式**、**质量优先**，支持固定模型、默认回退模型、多轮会话粘性（避免无意义切换破坏缓存）与失败自动重试。
  - 预留 `RoutingDeciderPlugin` 可替换接口，未来可作为可选插件扩展 Jev、本地小模型或自定义决策器；默认不向任何第三方决策模型发送请求。
- **可核对的路由收据**：
  - 分开展示：**路由判断耗时**、**上游首字时间 (TTFT)**、**总完成时间**。
  - 分开展示：**上游实测用量**（若上游未返回 `usage` 则明确标注本地估算及方法）、**按用户单价计算的费用**（未配置单价时显示“无法计算费用”）、**失败重试附加成本**。
  - **诚实对照**：仅在存在真实历史样本（标注「历史估算」）或测试台主动运行 A/B 对照（标注「实测对照」）时才展示对比节省，绝不用未运行模型的想象耗时相减。
- **隐私控制**：调用记录保存在本机，支持一键清空历史、脱敏导出收据 JSON，以及关闭请求/响应正文记录。

---

## 环境要求与构建

- macOS 14.0+（已在 Apple Silicon macOS + Swift 6.2.3 / Xcode 26.2 下构建验证）
- Swift 5.10+ / Xcode Command Line Tools

### 运行测试

```bash
swift test
```

### 构建并打包 `.app`

```bash
bash macos/build_app.sh
open dist/AutoModel.app
```

构建产物位于 `dist/AutoModel.app`。

---

## 使用指南

### 1. 添加供应商与模型

1. 打开 **Auto Model**，在「供应商与模型」中添加你的 OpenAI 兼容中转站或本地服务（例如 `http://127.0.0.1:11434` 或 `https://your-relay.example.com/v1`）。
2. 输入 API Key（会存入 macOS Keychain），点击 **测试连接 & 拉取模型** 验证连通性。
3. 至少添加两个可用模型，配置输入/输出单价（不填则显示“无法计算费用”）、上下文窗口、能力标签（如 `工具调用`、`视觉图像`、`代码工程`）与默认用途。

### 2. 在测试台验证

切换到「测试台」，发送普通或流式（SSE）请求，确认上游正常返回，并在右侧查看实时生成的「路由收据」。

### 3. 连接第三方 AI 应用

本地代理默认监听 `http://127.0.0.1:8765`（可在「设置」中修改端口）：

- **Base URL**: `http://127.0.0.1:8765/v1`
- **API Key**: 任意非空占位字符串（例如 `local-auto-model`）
- **Model**: `auto`（按任务与策略自动映射三档），或显式指定 `auto/low`、`auto/medium`、`auto/high`，也可填写具体模型 ID 直连转发。
- **自动接入本地 Agent**：在 App 左侧进入「Agent 自动配置」，无需手动修改配置文件即可一键写入或恢复 Codex、OpenCode、Hermes 等应用。

示例（`curl` 流式调用）：

```bash
curl -N http://127.0.0.1:8765/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "stream": true,
    "messages": [{"role": "user", "content": "用三句话解释 Raft 共识算法"}]
  }'
```

每个响应都会附带 `X-AutoModel-Executed-Model`、`X-AutoModel-Strategy`、`X-AutoModel-Policy-Version`、`X-AutoModel-Decision-Ms` 等响应头，同时 JSON chunk 中的 `model` 字段会反映实际执行的模型 ID。

---

## 数据流向说明

```
第三方 AI 应用 ──(http://127.0.0.1:8765/v1/chat/completions)──▶ Auto Model 本地代理
                                                                   │
                                       [本机硬约束过滤 + 策略评分] ──┘
                                                                   │
                                       (读取 macOS Keychain 密钥)  ▼
                                                         用户配置的上游供应商
                                                                   │
                                                                   ▼
                                           响应透传回调用方 + 本机生成路由收据
```

所有路由判断和历史存储均在用户本机执行，除用户配置的目标模型供应商外，不会向任何其他服务端发送数据。

---

## 兼容范围与已知限制

- **已实现**：
  - `GET /health`、`GET /v1/health`
  - `GET /v1/models`（返回 `auto`、`auto/low`、`auto/medium`、`auto/high` 及已启用的配置模型）
  - `POST /v1/chat/completions`（OpenAI Chat Completions 普通 JSON 与流式 SSE 转发、工具调用、视觉多模态消息、`reasoning_content` 提取）
  - `POST /v1/messages`（Anthropic Messages API 兼容转发，支持普通 JSON 与流式 SSE，适配 Claude Code 等客户端）
  - `POST /v1/responses`（OpenAI Responses API 兼容转发，支持普通 JSON 与流式 SSE，适配新版 Codex / Responses 客户端）
- **暂未实现（返回 `501 Not Implemented`）**：
  - `POST /v1/embeddings`、图片生成等非对话接口
- **参数限制**：
  - 暂不支持 `audio` / `modalities: ["audio"]` 或 `n > 1` 多候选采样（会返回明确的 `400` 错误，不会静默忽略）。
- **费用计算前提**：
  - 费用按用户填写的每百万 tokens 单价计算，仅作对账估算；未填写单价或上游未返回/流式未携带 `usage` 时，会在收据中如实标记。
