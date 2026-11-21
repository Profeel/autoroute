# Contributing to AutoRoute

感谢贡献。请保持改动可审查、兼容现有用户配置，并先阅读[开发验收文档](docs/development/P0-P2-DEVELOPMENT.md)与[行为准则](CODE_OF_CONDUCT.md)。

## 环境与本地构建

- macOS 14+，Swift 5.10+；当前开发基线使用 Swift 6.x。
- 不依赖托管 AutoRoute 服务。测试供应商使用受控本地上游或明确的 mock，不消耗真实额度。
- 保留未提交的用户工作；不要为“清理”而回滚无关修改。

```bash
swift test
bash macos/build_app.sh
git diff --check
codesign --verify --deep --strict dist/AutoRoute.app
```

本地构建默认是 ad-hoc 签名，不可描述为 Developer ID 或公证版本。

## 分支、提交与 Pull Request

1. 从最新 `main` 创建聚焦分支，例如 `fix/responses-stream-usage`。
2. 每个垂直切片先添加能复现问题且会失败的测试，再实现，并运行相邻回归。
3. 提交保持单一主题；不提交 `.build`、`dist`、Keychain 导出、真实 token、私有配置或生成的大文件。
4. PR 填写模板：范围、实际命令和结果、UI 截图、兼容性、隐私/安全与文档影响。未运行项目明确写 `NOT RUN`，不要复制虚假成功结果。
5. 协议、路由、预算、指标或持久化改动需要相应维护者审查。外部发布、Issue 批量创建、仓库元数据和分支保护变更需要单独授权。

## 代码风格与架构

- `AutoModelCore` 放可测试的认证、路由、协议、预算、指标与报告逻辑；SwiftUI 只收集意图和展示。
- 使用清晰 Swift 命名、值类型与显式错误；避免无关重构、全局单例和隐式网络副作用。
- 保留 `AutoModel` 模块/可执行目标与 `org.automodel.app` Bundle ID；用户可见名称为 AutoRoute。
- 新配置字段提供确定性解码默认值和旧 JSON 测试，不能清空显式用户选择。
- 新用户可见文案使用清晰中文；英文入口提供等效快速开始。

## 协议与路由兼容

- Chat Completions、Responses、Anthropic Messages 的普通 JSON 与 SSE 都需回归。
- 覆盖 tools、vision、reasoning content、usage、错误透传、原生 Responses 需要的能力与不支持参数。
- 保持三档、顺序回退、粘性、阶段切换、冷却、重试和 Agent 备份/恢复；SSE 已输出后不得换模型造成重复内容。
- 固定基线与 `auto` 的 A/B 除会话标识外保持相同参数；独立 session，交错顺序，不把缺价格当 0 元。

## 隐私与安全要求

- 本地代理只能绑定 `127.0.0.1`；保留 Host/Origin/token 边界，不恢复通配符 CORS。
- 供应商密钥与本地 token 分开存 Keychain。测试使用哨兵值，不使用真实凭据。
- 请求/响应正文记录默认关闭；新增派生字段也要检查是否泄露正文。
- 收据、A/B 和聚合指标导出不得包含 token、API key、提示词、代码或响应正文（除非未来有明确、单独、默认关闭的用户选择）。
- 指标功能不得增加隐蔽上传或后台网络任务。外部平台数据只能由维护者从平台读取。

## 测试证据

相关改动至少运行：

```bash
swift test --filter P0SecurityTests
swift test --filter P1
swift test --filter P2
swift test
```

UI 改动还需在 PR 中列出实际手测路径与真实截图；证书、公证、真实上游 A/B、远程 Actions/Release 无法执行时标 `DONE-BUT-UNVERIFIED`，不要声称已验证。

安全漏洞不要先开公开 Issue，请按 [SECURITY.md](SECURITY.md) 报告。
