# 验收契约

## A. 安装与来源

- [x] 源码 `HEAD` 等于固定提交 `9edf84602c3af9399808afa448cd222f8fe1f7f9`
- [x] Git remote 指向官方 `agentscope-ai/agentscope`
- [x] `import agentscope` 成功并记录包内版本
- [x] Python 满足官方要求（3.11 及以上）
- [x] 四个受控 overlay 只修改 allowlist 内文件
- [x] 固定源码的 AgentScope Web UI 生产构建通过
- [x] ReME `0.4.1.3` 在固定 AgentScope 源码线上启动并完成真实 `POST /version`
- [ ] GitHub `CI` 与三项 `linux/amd64` OCI build 通过
- [ ] SRE 交付记录包含三个 GHCR 不可变 digest、SBOM 与 provenance

## B. 运行时与隔离

- [x] 独立 Redis 容器健康，未复用 Dify Redis
- [x] `open` 模式下 Agent Service 监听 `0.0.0.0:18080`，默认/`close` 目标为 `127.0.0.1:18080`
- [x] `open` 模式下 Web UI 监听 `0.0.0.0:15173`，默认/`close` 目标为 `127.0.0.1:15173`
- [x] 既有容器与既有监听端口保持运行
- [x] systemd 服务重启后恢复健康

## C. API 与结构能力

- [x] OpenAPI 可读取
- [x] Agent、Session、Credential、Model、Schedule、Workspace 路由存在
- [x] Knowledge Base/RAG 路由存在
- [ ] Team、MCP Hub 与 Skill Hub 路由按该源码提交实际能力存在
- [x] SDK 消息、工具、权限和工作区类型可导入

## D. Web UI

- [x] Web UI 首页返回成功
- [ ] 可通过 SSH 隧道打开
- [ ] 可配置 Agent Service 地址和测试用户标识

## E. 模型业务闭环（需要运行时模型凭证）

- [x] 从本机钥匙串经 SSH 创建/更新火山方舟 Credential
- [x] 创建火山方舟 Smoke Agent 与 Session
- [x] AgentScope `OpenAIChatModel` 非流式适配器得到非空回复并记录 usage
- [x] 公网 Credential 列表与更新响应不包含 API Key 或 base URL
- [x] Agent Service 完整 ReAct 会话以 `completed` 结束并返回语义精确的 `OK`
- [x] Ark Credential 仅显示 1 个已验证 Chat 模型，TTS/向量目录为 0
- [x] 服务端拒绝 Ark 未验证 Chat/TTS Session 和 Ark 向量 Knowledge Base 写入
- [x] 豆包 ASR 使用合成 WAV 完成供应商直调与 Lab 公网 API 语义验收
- [x] TTS 与向量真实调用失败后保持未配置/不可选
- [ ] 流式回复产生可识别事件序列
- [ ] 工具调用与权限确认形成闭环
- [ ] 会话重连后可读取历史
- [ ] 至少一次 RAG 检索闭环
- [ ] 至少一次计划或 Agent Team 闭环

A-D 通过只证明安装、服务与结构能力。E 必须使用真实模型服务单独验证；HTTP 200、
进程健康或前端可打开都不能替代模型业务闭环。

## F. 临时公网访问

- [x] `open` 后仅 `15173`、`18080`、`18280` 监听 `0.0.0.0`
- [x] Redis、ReME、Neo4j 仍只监听 `127.0.0.1`
- [x] 从 14 服务器之外通过 `http://14.103.221.4/agentscope/`、`/agentscope-api/` 和 `/lab/` 访问成功
- [x] AgentScope UI 和 API 未认证返回 401，使用钥匙串凭证后返回 200
- [ ] AgentScope UI 保存带 `/agentscope-api` 路径的服务地址后，Agent、Credential、Knowledge Base 请求均保留该前缀
- [x] Lab HTTP、WebSocket 与合成记忆生命周期可用
- [x] Lab 公网上传合成 WAV 返回真实 ASR 转写，且轨迹不持久化转写正文
- [x] Lab 在公网 HTTP 非安全上下文中明确禁用麦克风并提示 HTTPS/localhost 要求
- [x] 共享 Lumi Caddy、Dify 与既有 AgentScope 服务回归正常
- [ ] `close` 后三个高端口恢复为 `127.0.0.1`
- [ ] `close` 后路径入口无法连接应用后端（Caddy 路由保留时可返回 502），再次 `open` 恢复

公网访问只用于临时验证，不得从浏览器注入模型或其他敏感凭证。火山方舟凭证只能从本机钥匙串
经 SSH 配置，公网 Credential 响应必须保持脱敏。Basic Auth 是入口访问控制，但 HTTP 不提供链路
机密性，开放状态不构成 TLS 或生产部署验收。高端口不得在云安全组放行，以免绕过 Caddy 认证；
动态 nip.io/sslip.io 地址不作为交付地址。
