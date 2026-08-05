# Talk–Think–Memory Lab 后端契约

## 边界

本目录是独立实验环境，不是 Lumi 子系统，不调用 S1～S6、Device Platform、Dify、
设备鉴权、Redis、AG-UI 或 A2UI。当前后端交付 Memory Studio 和已通过真实供应商
调用的豆包录音文件 ASR；Qwen Omni、TTS、LLM 级联、Speech Gate、AgentScope Runner、
ReME 自动整理和图谱写入仍是后续适配层。未验证或验证失败的模型不得出现在
可选列表中。

所有数据必须是虚构儿童和合成数据。服务默认只监听 loopback，通过 SSH 隧道访问；显式
执行仓库根目录的公网开关后，只有 Lab UI/API 可临时监听 `0.0.0.0:18280`，并经共享 Caddy
的 `http://14.103.221.4/lab/*` 路径访问；Caddy 去除 `/lab` 前缀后转发。ReME、Neo4j 和其他
内部存储仍保持 loopback，高端口不得在云安全组中单独放行。

## 数据与隔离

- 每个状态 API 都要求路径参数 `memory_space`；不存在无空间的兼容路由。
- `memory_space` 仅接受小写字母、数字、下划线和连字符，长度 3～64。
- SQLite 主键是 `(memory_space, id)`，所有读取和写入都显式带空间条件。
- JSONL 按 `<memory_space>.jsonl` 分文件，事件内再次记录空间。
- Neo4j 的 Memory、Entity 和 Event 契约均保留 `memory_space` 属性；后续图谱适配器不得执行
  无空间限定的查询。

## 生命周期

```text
draft -> review -> published -> withdrawn -> published
  |        |                       |
  |        +-> draft               v
  +----------------------------> trashed -> purged
                                   |
                                   +-> withdrawn
```

`trashed` 是可恢复回收站状态，恢复后进入 `withdrawn`；`purged` 是永久终态。已发布记忆
不能直接编辑或移入回收站，必须先撤回。每次变更使用 `expected_version` 做乐观并发控制，
并写入 JSONL 轨迹。

永久清理使用独立 `POST .../{id}/purge`，请求必须同时包含匹配路径的 `confirm_memory_id`、
`confirm_irreversible: true`、版本和原因。当前阶段会清除 SQLite 正文并保留最小墓碑，同时
返回 SQLite、JSONL、ReME、Neo4j 和索引逐层报告；未实现的跨存储清理明确标为
`not_configured`，因此 `complete=false`，不得把它当作删除完整率 100% 的证据。

## API

- `GET /health`：仅检查进程和 SQLite。
- `GET /status`：检查 ReME、Neo4j 和精确包版本，不回显凭证。
- `POST/GET /api/v1/spaces/{memory_space}/memories`
- `GET/PATCH/DELETE /api/v1/spaces/{memory_space}/memories/{id}`
- `POST /api/v1/spaces/{memory_space}/memories/{id}/transitions`
- `POST /api/v1/spaces/{memory_space}/memories/{id}/purge`
- `POST /api/v1/spaces/{memory_space}/speech/asr`：接收 WAV/MP3/OGG Opus 合成音频，返回真实转写。
- `GET /api/v1/capabilities`：只展示已验证/未配置状态，不返回凭证或模型 ID。
- `WS /ws/v1/spaces/{memory_space}/events`

构建后的 Web UI 由 FastAPI 同源托管在内部 `/chat`、`/memories`、`/evaluations` 和
`/ui/status`，公网分别映射为 `/lab/chat`、`/lab/memories`、`/lab/evaluations` 和
`/lab/ui/status`；API `/status` 保持优先且不被 SPA fallback 覆盖。

ASR 凭证只能从本机 macOS 钥匙串经 SSH 注入服务器 root-only 运行时环境文件。
音频和转写不写入 SQLite/JSONL；轨迹只记录能力、耗时、字节数和成功状态。
WebSocket 会发送 `speech.asr.completed`，但当前不传输音频流。
