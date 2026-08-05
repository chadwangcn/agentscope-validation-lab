# AgentScope Validation Lab

本仓库是 AgentScope 独立验证区的公开交付源，保存固定依赖、受控 overlay、
Talk · Think · Memory Lab、GitHub CI、OCI 构建和 SRE 验收契约。正式验证区的
部署、域名、TLS、Secret Manager、发布和回滚已交由 SRE 执行；GitHub Actions
不会连接或修改服务器。

- 项目仓库：`https://github.com/chadwangcn/agentscope-validation-lab`
- 目标文档通道：AgentScope `2.0.6dev`
- 官方源码固定提交：`9edf84602c3af9399808afa448cd222f8fe1f7f9`
- 该提交包内版本：`2.0.5`
- 首个 SRE 交付标签：`sre-validation-zone-v0.1.0`

AgentScope 依赖契约见
[`dependencies/agentscope.lock.env`](dependencies/agentscope.lock.env) 和
[`dependencies/README.md`](dependencies/README.md)。CI 会重新拉取该固定提交、
应用 4 个 overlay、核对变更文件 allowlist，并构建 AgentScope UI 与 Lab。

## GitHub CI 与 OCI

`CI` 在 pull request 和 `main` push 上执行源码准备、前端构建、Python 编译、
Lab API 测试和公开仓库敏感内容检查。`OCI` 在 pull request 上只构建，在
`main`、交付 tag 或手动触发时发布到 GHCR：

- `ghcr.io/chadwangcn/agentscope-validation-lab-agentscope-service`
- `ghcr.io/chadwangcn/agentscope-validation-lab-agentscope-web`
- `ghcr.io/chadwangcn/agentscope-validation-lab-memory-lab`

SRE 必须使用工作流输出的不可变 image digest 部署，不使用可漂移的 `main`
标签。镜像构建不接收模型、语音、Neo4j 或入口认证密钥；这些只允许由 SRE
在运行时注入。详细契约见 [`docs/CI-OCI.md`](docs/CI-OCI.md)。

## 本地验证

```bash
./scripts/check-public-repository.sh
./scripts/prepare-agentscope-source.sh .build/agentscope-source
python -m pytest -q talk-think-memory-lab/tests
npm --prefix talk-think-memory-lab/frontend ci
npm --prefix talk-think-memory-lab/frontend run build
```

## 14 号临时环境（历史验证基线）

以下脚本保留用于当前 14 号临时环境的回归和关闭，不是新独立验证区的
自动部署入口：

- 服务器 SSH 别名：`k1-openclaw`
- 远端安装目录：`/opt/agentscope-2.0.6dev`
- Agent Service：`127.0.0.1:18080`
- Web UI：`127.0.0.1:15173`
- 独立 Redis：`127.0.0.1:6379`

14 号临时环境部署和验证：

```bash
./scripts/deploy.sh
./scripts/verify.sh
```

本地访问使用 SSH 隧道：

```bash
ssh \
  -L 15173:127.0.0.1:15173 \
  -L 18080:127.0.0.1:18080 \
  k1-openclaw
```

浏览器打开 `http://localhost:15173`，在初始化页将 Agent Service 地址设置为
`http://localhost:18080`。

## 临时公网访问

当前 14 号服务器通过已开放的 TCP `80` 提供公网 IP 路径入口：

- AgentScope UI：`http://14.103.221.4/agentscope/`
- AgentScope API：`http://14.103.221.4/agentscope-api/`
- Lab：`http://14.103.221.4/lab/`

AgentScope UI 和 API 由 Caddy HTTP Basic Auth 同时保护。入口用户名是 `agentscope`，强随机
密码只保存在本机 macOS 钥匙串的 `codex.agentscope-14.public-basic-auth` 项中；服务器仅保存
bcrypt 哈希，仓库不保存明文。可在本机终端读取密码：

```bash
security find-generic-password \
  -a agentscope \
  -s codex.agentscope-14.public-basic-auth \
  -w
```

首次通过入口认证后，AgentScope 初始化页仍需手动填写：

- Agent Service URL：`http://14.103.221.4/agentscope-api`
- 用户名：`synthetic-test-user`

初始化页不预填上述字段。入口账号只负责公网 Basic Auth；AgentScope 页面里的用户名仍是
官方示例使用的 `X-User-ID` 资源归属标识，不是生产身份认证。

## 火山方舟模型凭证

火山方舟已通过 OpenAI-compatible 接口配置在 AgentScope 后台，凭证名为 `Volcengine Ark`，
控制台模型标签为 `Volcengine Ark (Keychain)`。本机 macOS 钥匙串使用服务名
`volcengine.ark`，包含 `api_key`、`base_url`、`model` 三个 account；仓库和文档不保存这些值。
这个 Credential 的可见目录是真实验收清单，不是 OpenAI 静态能力大全：当前仅显示
1 个已通过供应商调用、AgentScope adapter 和完整 Agent Service 会话的 Chat 模型；
TTS 与向量目录均为 0。服务端同时拒绝用该 Credential 写入未验收模型的 Session 或
Knowledge Base，不只依赖 UI 过滤。

配置或轮换钥匙串内容后执行：

```bash
./scripts/configure-volcengine-ark.sh
```

脚本通过 SSH 标准输入把凭证送入 14 服务器，在 `synthetic-test-user` 资源空间内幂等创建或更新
Credential、运行时模型卡、`Volcengine Ark Smoke Agent` 和 `Volcengine Ark Smoke` 会话。脚本还会
用 AgentScope 自身的 `OpenAIChatModel` 适配器进行一次无工具非流式调用，再通过 Agent Service
完成一次语义为 `OK` 的真实 ReAct 会话，并校验回复、usage 和凭证响应脱敏；输出只包含布尔结果、
完成原因和对象 ID，不输出模型回复正文。

AgentScope 运行时将原始凭证保存在隔离 Redis 中供模型调用。当前环境额外应用服务端脱敏补丁，
Credential 列表和更新响应只返回 `type` 与 `name`，不会把 API Key 或 base URL 发到浏览器。公网
入口仍是 HTTP，因此不得通过 Web UI 创建或编辑敏感凭证；轮换只使用上述 SSH 脚本。重新部署
AgentScope 后应再次执行该脚本，以重建与钥匙串 `model` 对应的运行时模型卡。

Lab 的豆包 ASR 与 AgentScope Credential 分离：AgentScope 2.0.6dev 没有独立 ASR 模型抽象、
路由或 UI。钥匙串 `volcengine.speech` 的 `appid`/`api_key` 只在真实已知语义音频验收
通过后，由 `talk-think-memory-lab/scripts/configure-volcengine-speech.sh` 经 SSH 注入 Lab。
当前 ASR 已通过并在 `/lab/chat` 提供 WAV/MP3/OGG Opus 上传识别；TTS 和向量真实调用
未通过，所以仍不配置。

公网入口和监听开关的可重复操作：

```bash
./scripts/configure-agentscope-basic-auth.sh
./scripts/public-access.sh open
./scripts/public-access.sh status
```

三个高端口仍只作为 Caddy 宿主机上游，不是公网交付地址，也不得在 VolcStack 安全组中放行，
否则会绕过入口认证。ReME、Redis、Neo4j 始终只监听回环地址。动态 nip.io/sslip.io Host 会被
VolcStack WebBlock 拦截，本方案不依赖这些域名。

验证完成后手动关闭：

```bash
./scripts/public-access.sh close
```

`close` 会将三个应用恢复为回环监听；Caddy 路径仍存在，但连接后端时返回 502。再次执行
`open` 会恢复服务并幂等校验 Caddy 配置。

公网入口仍是 HTTP。Basic Auth 能阻止未认证访问，但不能加密链路；不要通过该入口提交模型、
Neo4j 或其他敏感凭证。火山方舟凭证只能从本机钥匙串经 SSH 配置。Lab 当前不设置应用层认证，
只允许合成测试数据。

详细边界和验收层次见 [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md) 与
[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)。

独立测试区、域名/HTTPS、SRE 分工、迁移、验收和回滚要求见
[SRE 任务包](docs/SRE-TASK-PACKAGE-AGENTSCOPE-VALIDATION-ZONE.md)。
