## 变更范围

<!-- 说明用户问题、实现方案和涉及 P0/P1/P2。保持单一主题，不夹带无关重构。 -->

## 实际测试证据

<!-- 粘贴实际命令与结果；未运行写 NOT RUN，不伪造外部验证。 -->

- [ ] `swift test`
- [ ] `bash macos/build_app.sh`
- [ ] `git diff --check`
- [ ] 相邻协议/路由/Agent 备份恢复回归
- [ ] UI 手测与真实截图（涉及 UI 时）
- [ ] Developer ID / 公证 / 真实上游 A/B 已执行，或明确标为 DONE-BUT-UNVERIFIED

## 兼容性

- [ ] 旧配置/历史有确定性解码默认值，显式用户选择不被清空
- [ ] Chat Completions、Responses、Anthropic Messages 普通与 SSE 未破坏
- [ ] 三档、回退、粘性、冷却、重试与 Agent 恢复保持兼容
- [ ] 无兼容性影响，或已在上方说明迁移/回滚

## 隐私与安全

- [ ] 不含真实 API key、本地 token、私有正文、账号或个人路径
- [ ] 未扩大监听、Host/Origin/CORS 或匿名接口权限
- [ ] 正文默认不记录；收据/A/B/指标导出无新增敏感字段
- [ ] 指标功能未增加隐蔽上传或额外网络请求

## 文档与截图

- [ ] 中英文文档、端口、token、别名和构建路径已同步
- [ ] 截图来自真实 UI，已检查无敏感信息；未链接不存在的 GIF/Release
- [ ] CHANGELOG / ROADMAP / 发布清单按需更新
