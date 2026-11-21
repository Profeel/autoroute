# Security Policy

## 支持版本

安全修复优先应用于 `main` 和最新正式发布版本。本地 ad-hoc 构建、旧 fork 和未维护分支不保证获得修复。版本状态以实际 GitHub Release 为准；源码中的版本号不代表已经发布。

## 私密报告漏洞

请使用 GitHub 仓库的 **Security → Advisories → Report a vulnerability** 私密漏洞报告入口，不要在公开 Issue、PR、Discussion 或录屏中先披露可利用细节。如果仓库尚未启用该入口，请通过维护者 GitHub 资料中实际公开且经验证的私密渠道联系；本文件不提供虚构邮箱。

报告请包含：

- 受影响版本/commit、macOS/Swift 版本与最小复现步骤。
- 影响范围：本机 token 绕过、Host/Origin/DNS Rebinding、Keychain、正文泄露、协议走私、Agent 配置破坏、预算绕过等。
- 预期与实际行为、可行修复建议和是否已公开。

## 报告前脱敏

- **不要提交真实供应商 API Key、本地 API token、cookies、Keychain 导出或完整配置备份。**使用 `sk-test-sentinel` 等明确哨兵值。
- 不要提交私有提示词、代码、响应正文、账号、个人路径或未脱敏收据。先用测试数据和 Settings 的脱敏导出。
- 本地 API 问题可附 Host/Origin、状态码和脱敏 header 名称，但移除 Authorization 与 `x-api-key` 的值。
- 若误发真实密钥，立即在供应商处轮换；删除 GitHub 内容并不等于密钥已失效。

## 安全边界摘要

AutoRoute 只绑定 `127.0.0.1`，但 loopback 不等于可信。所有非最小健康接口需要本地随机 token；Host 与 Origin 校验、常量时间比较和无通配符 CORS 是必备回归。供应商密钥与本地 token 使用独立 Keychain 条目。

正文记录默认关闭。本地历史、A/B 和指标导出应由用户主动触发；指标功能不应产生额外网络请求。Agent 一键接入必须预览、备份、保留非托管配置并可恢复。

## 响应流程

维护者收到报告后会确认范围、复现并评估影响，再协调修复与披露时间。没有已执行修复或发布证据时，不会声称漏洞已解决。请勿在修复可用前公开 exploit、真实用户数据或可利用配置。
