# AutoRoute 发布与仓库维护清单

本清单是维护者操作指南，不表示任何外部步骤已经执行。勾选前必须保留真实命令输出或外部链接证据。

## 1. 版本、变更与升级准备

- [ ] 在 `macos/version.env` 更新 `AUTOROUTE_VERSION` / `AUTOROUTE_BUILD_NUMBER`，不另建第二份版本真源。
- [ ] Git tag 必须严格等于 `v${AUTOROUTE_VERSION}`；Release workflow 会在构建前校验 `GITHUB_REF_NAME`，不一致时明确失败，避免 tag 与应用版本错配。
- [ ] 更新 `CHANGELOG.md`：安全迁移、功能、修复、升级步骤、已知限制；未发布内容保留在 Unreleased。
- [ ] 核对 README 中英文端口、token、模型别名、构建路径与当前代码一致。
- [ ] 备份演示环境配置，验证旧 JSON、显式隐私选择、手动三档覆盖、Agent 配置和历史迁移。
- [ ] 写明升级：退出 Agent → 安装 → 检查配置 → 同步端口/真实本地 token → 真实 socket 验收。

## 2. 自动测试与 UI 手测

```bash
swift test
bash macos/build_app.sh
git diff --check
codesign --verify --deep --strict dist/AutoRoute.app
```

- [ ] 全部安全、迁移、协议、预算、A/B、指标测试通过，无 filter 隐藏失败。
- [ ] 空配置到真实验收的首次引导手测；模拟链路不误标真实成功。
- [ ] Codex、Claude Code、OpenCode、Hermes、Shell/Continue 的预览、备份、接入、断开恢复手测。
- [ ] Chat/Responses/Anthropic 普通与 SSE、tools、vision、reasoning、usage 回归。
- [ ] 端口冲突、401/403、Host/Origin、预算 429、清空确认与脱敏导出手测。
- [ ] 真实截图覆盖首次引导、三档策略、Agent 接入、收据/A/B；逐张检查无 key、token、账号、私有代码或通知。

## 3. 真实 A/B（不能用模拟结果替代）

- [ ] 使用 `public-text-v1` 或明确版本样例，固定基线与 auto 交错运行至少 3 轮，独立会话。
- [ ] 明确质量评估方法；未评估时不声称质量或成功率等价。
- [ ] 保存原始 `autoroute-ab-report.json`，重新解码核对样本和汇总，确认无提示词、响应正文和凭据。
- [ ] 区分上游实测、历史/本地估算、缺失 usage/价格；与供应商账单核对。
- [ ] 没有额度时标 **DONE-BUT-UNVERIFIED**，不提交伪造“官方成绩”。

## 4. Developer ID、公证与资产

**P0 未闭环项：** 全新 macOS runner 不会凭空拥有 Developer ID 私钥或 notarytool profile。**仅凭 tag 不代表可发布**；缺少任一凭据、证书不包含私钥、签名身份不匹配或公证失败时，workflow 必须失败且不得上传资产，ad-hoc 不能替代正式 Release。

GitHub Release 使用 `macos/prepare_release_signing.sh` 在 runner 的临时目录创建受限 keychain，解码并导入 PKCS#12 证书/私钥，设置 codesign partition list，调用 `notarytool store-credentials --validate --keychain`，再由 `macos/cleanup_release_signing.sh` 在 `always()` 步骤删除临时 keychain 和文件。证书与密码只在准备步骤注入，仓库不保存真实值。

`prepare_release_signing.sh` 是 **CI-only**：必须设置 `GITHUB_ACTIONS=true`，否则脚本会在触碰任何 Keychain 前退出。不要在本机日常签名环境执行它，因为它会替换 keychain 搜索列表和默认 keychain。

维护者只需在 GitHub 仓库 Secrets 中配置以下**名称**（这里不填写真实值）：

| Secret 名称 | 内容 |
| --- | --- |
| `DEVELOPER_ID_APPLICATION` | Developer ID Application 证书完整 Common Name |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | 含证书和私钥的 PKCS#12 文件 base64 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | PKCS#12 导出密码 |
| `NOTARYTOOL_APPLE_ID` | 用于公证的 Apple ID |
| `NOTARYTOOL_APPLE_PASSWORD` | 对应 Apple ID 的 App 专用密码 |
| `NOTARYTOOL_TEAM_ID` | Apple Developer Team ID |

`NOTARYTOOL_KEYCHAIN_PROFILE` 是 workflow 固定的临时 profile 名称，不是现成凭据，也不需要作为 secret 提供。准备脚本会验证身份和公证凭据；Release 构建还会检查 `codesign` 的 `Authority`，防止仅有环境变量或 ad-hoc 签名通过。

本地受信任环境若已有 Developer ID 和 notarytool profile，可单独执行以下命令；这不是 CI 凭据的替代品：

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: ...'
export NOTARYTOOL_KEYCHAIN_PROFILE='实际 notarytool keychain profile'
export AUTOROUTE_REQUIRE_DEVELOPER_ID=1
bash macos/build_app.sh
bash macos/package_app.sh
bash macos/notarize_app.sh
source macos/version.env
cd dist && shasum -a 256 -c "AutoRoute-${AUTOROUTE_VERSION}.zip.sha256"
```

- [ ] 确认 Developer ID 私钥已导入、hardened runtime、`codesign --verify --deep --strict` 和匹配的 `Authority`。
- [ ] 公证前始终先执行 `bash macos/package_app.sh` 生成新的 ZIP，不复用旧包；Release workflow 的 package 步骤必须先于 notarize。
- [ ] `notarytool --wait` 成功、staple 成功、`spctl -a -vv` 通过；本地 ad-hoc 结果不可替代。
- [ ] ZIP 与 `.sha256` 来自同一最终公证 app，SHA 文件只含 dist 内相对 ZIP 文件名，重新解压后再次验签并可执行 `shasum -a 256 -c`。
- [ ] 无 Apple 凭据时只完成脚本，标 **DONE-BUT-UNVERIFIED**；不要宣称 tag 即可正式发布。

## 5. Release Notes、GitHub Release 与 Homebrew

- [ ] 从 CHANGELOG 编写 Release Notes：安全升级、兼容范围、已知限制、SHA、升级/回滚。
- [ ] 先审阅 tag 与 release workflow；远程 Actions 成功后才宣称 CI/Release 验证。
- [ ] 创建实际 GitHub Release 并上传最终 ZIP/SHA；记录真实 URL，不预写不存在链接。
- [ ] 基于实际 ZIP 运行 `bash macos/generate_homebrew_cask.sh`，审查 cask 的 version/sha256/url。
- [ ] 仅在 cask 已发布到可访问 tap 后执行 `brew install --cask autoroute` 验证；生成模板不等于安装通过。
- [ ] Homebrew 更新指向实际 Release 资产，不指向本机 `dist`。

## 6. 回滚与故障处理

- [ ] 发布说明包含回滚：停止代理 → 在各 Agent 中恢复备份 → 安装已验证旧版本 → 重新接入/验收。
- [ ] 保留 Application Support 与 Keychain；不要以删除用户配置作为常规回滚。
- [ ] 提醒旧版本可能无法识别新增 Agent 策略、预算、来源标记和指标字段；必要时从升级前备份恢复整个配置目录。
- [ ] 若签名、公证、协议或迁移发现阻断问题，停止发布，不删除失败证据，不用本地成功替代外部结果。

## 7. 仓库元数据建议（需单独授权执行）

推荐 **description**：

> Local-first macOS multi-model router for Codex, Claude Code, OpenCode, and OpenAI/Anthropic-compatible agents.

推荐 **topics**：

`macos`, `swift`, `swiftui`, `llm`, `openai`, `anthropic`, `codex`, `claude-code`, `opencode`, `local-first`, `model-router`

推荐 **homepage**：使用实际仓库 README 或已维护的项目页面；没有官网时留空，不填写不存在域名。

- [ ] 审查并设置 description/topics/homepage；未执行时保持本项未勾选。
- [ ] 主分支保护建议：要求 PR、要求 CI `test-and-build` 通过、限制直接推送、要求对话解决；实际修改需维护者授权。
- [ ] 从 `docs/community/GOOD_FIRST_ISSUES.md` 审查后创建 Issues；候选清单不等于已创建。

## 8. 发布后证据与回滚观察

- [ ] 记录实际 Actions、Release、notarization、Homebrew 安装链接和命令结果。
- [ ] 仅从 GitHub 平台读取 Star、下载、Issue、贡献者数据；本地客户端不上传也不伪造项目级 cohort。
- [ ] 观察升级、认证和兼容 Issue；出现严重安全/数据破坏问题时按回滚流程撤下资产并发布修复。
