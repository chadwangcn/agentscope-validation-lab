# AgentScope 2.0.6dev 测试环境设计

## 1. 目标

在 14 号临时验证服务器上部署一套与既有 Dify、Lumi 和反向代理服务隔离的
AgentScope 2.0 测试环境，用于验证 SDK、Agent Service、Web UI、工具、权限、
工作区、RAG、调度与多智能体团队等能力。

## 2. 版本契约

用户指定的官方文档通道为 `2.0.6dev`。截至 2026-08-05：

- PyPI 最新正式包是 `2.0.5`，不存在名为 `2.0.6.dev*` 的发布包；
- 官方 `main` 分支包含 `2.0.6dev` 文档所述的开发中能力；
- 本环境固定官方源码提交
  `9edf84602c3af9399808afa448cd222f8fe1f7f9`，不跟随 `main` 漂移；
- 该提交内 `agentscope.__version__` 仍报告 `2.0.5`。

因此验收必须分别记录文档通道、Git 提交与包内版本，不得把文档通道伪装成已发布
的 Python 包版本。

## 3. 服务器资源基线

- Ubuntu 24.04，x86_64
- 2 vCPU，7.8 GiB RAM
- 根盘可用空间约 35 GiB（盘点时）
- Python 3.12.3
- Node.js 22.22.3
- Docker 29.1.3
- 无 GPU

服务器已有 Dify、Caddy、Nginx 与 Lumi 服务。除本仓库记录的三个 TCP `80` 路径路由外，本环境
不得修改已有容器、网络、既有站点、443/8080/8443 或 `127.0.0.1:8000`。

## 4. 部署拓扑

| 组件 | 运行方式 | 监听地址 | 持久化 |
| --- | --- | --- | --- |
| AgentScope 源码 | 固定提交、editable install | 不适用 | `/opt/agentscope-2.0.6dev/source` |
| Python 环境 | `venv` | 不适用 | `/opt/agentscope-2.0.6dev/venv` |
| Redis | 独立 Docker 容器 | `127.0.0.1:6379` | Docker volume |
| Agent Service | systemd + Uvicorn | 默认 `127.0.0.1:18080`，临时公网 `0.0.0.0:18080` | Redis + workspaces |
| Web UI | systemd + Vite preview | 默认 `127.0.0.1:15173`，临时公网 `0.0.0.0:15173` | 静态构建产物 |

默认只允许通过 SSH 隧道访问，也不把 AgentScope 文档中的 `X-User-ID` 占位头当作生产鉴权。

例外：显式执行 `scripts/public-access.sh open` 后，AgentScope UI/API 与 Lab UI/API 监听三个
固定高端口，直到执行 `close`。共享 Caddy 在现有 `:80` Lumi 站点内提供三个互不重叠的路径：

- `/agentscope/*`：保留前缀转发到官方 Web UI；
- `/agentscope-api/*`：去前缀转发到 Agent Service；
- `/lab/*`：去前缀转发到 Lab UI/API/WebSocket。

AgentScope UI/API 路径同时要求 Caddy Basic Auth；Lab 路径保持无应用层认证。整个入口没有 TLS。
三个高端口不得在云安全组中放行，否则会绕过 Basic Auth。ReME、Redis、Neo4j 始终保持回环
监听。新造的 nip.io/sslip.io Host 会被 VolcStack WebBlock 拦截，本交付不依赖动态域名。

Caddy 部署脚本在运行时读取共享 Compose 网络网关，不硬编码 Docker 网段；同时读取服务器
root-only 的 Basic Auth 用户名和 bcrypt 哈希。`scripts/deploy-ip-path-ingress.sh` 负责候选校验、
带时间戳备份、标记块幂等更新、只重建 Caddy Compose 服务及失败回滚，不会重启 Lumi 后端
或 Dify。`scripts/configure-agentscope-basic-auth.sh` 在本机生成/读取钥匙串密码，并只把 bcrypt
哈希写到服务器。

官方固定提交额外应用四类受控 overlay：运行参数 overlay 将 Redis、Workspace 与默认 MCP
开关参数化；前端 overlay 将 Vite 基址设为 `/agentscope/`、路由
改用 hash router，并使 API URL 构造保留用户填写的 `/agentscope-api` 基址；凭证脱敏 overlay
确保所有 HTTP-facing Credential 响应只包含 `type` 与 `name`，运行时模型解析仍使用存储层原始
凭证；能力门禁 overlay 按 Credential 过滤模型目录，并在 Session/Knowledge Base 写入时阻止
未验证 Ark 模型。部署与验收脚本会校验准确文件集合。

## 5. 依赖范围

安装源码的以下 extras：

- `service`
- `storage-redis`
- `tools`
- `rag`
- `vdb-qdrant`

不默认安装 `full`，以避免在 2 vCPU / 8 GiB 主机上引入当前验证不需要的 Kubernetes、
Milvus、MongoDB、Elasticsearch、Mem0 等重型依赖。模型 API 的 OpenAI、DashScope 与
Anthropic 客户端属于核心依赖。

## 6. 凭证与数据边界

- 通用部署脚本不读取、不复制、不打印模型 API Key；
- 火山方舟专用脚本只从本机 macOS 钥匙串服务 `volcengine.ark` 读取 `api_key`、`base_url`、
  `model`，通过 SSH 标准输入传输，不写入仓库或命令行参数；
- 火山方舟凭证存入隔离 Redis 的 `synthetic-test-user` 资源空间，运行时模型卡只存在于服务器
  AgentScope 源码目录，重新部署后由专用脚本幂等重建；
- 公网 HTTP Credential 列表与更新响应只保留 `type`、`name`，不返回 API Key 或 base URL；
- 公网 UI 不允许创建或编辑敏感凭证，凭证轮换必须再次执行 SSH 专用脚本；
- 证据只记录凭证类型是否可用，不记录值、请求头或供应商原始响应；
- Redis 与 workspace 数据属于测试数据，清理前仍需明确授权；
- 官方示例的 `X-User-ID` 仅提供资源归属占位，不构成真实身份认证。
- 钥匙串条目或静态模型卡的存在不构成能力成功；只有供应商真实调用、返回格式/语义
  校验和应用适配路径全部通过后，才可进入可见清单。
