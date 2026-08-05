# talk-think-memory-lab

独立的 Thinker–Talker、记忆召回和 ReME＋Neo4j 对照实验环境。本阶段包含 FastAPI、
WebSocket、SQLite/JSONL 轨迹、强制 `memory_space` 隔离、记忆生命周期契约、ReME
本地服务、Neo4j Community，以及由 FastAPI 同源提供的 React/Vite Web UI。

当前可直接使用的界面：

- `/chat`：WAV/MP3/OGG Opus 上传、豆包 ASR 真实转写、浏览器录音/本地回放和
  实时 WebSocket 事件轨迹；
- `/memories`：Markdown/ZIP 导入、编辑，以及草稿、审核、发布、撤回、回收、恢复、永久清除；
- `/ui/status`：读取 Lab API、ReME、Neo4j 和 SQLite/JSONL 的真实运行状态；
- `/evaluations`：保留真实评测入口；模型与评测适配器接通前不生成虚构指标。

当前不包含真实 Talker/Thinker/TTS 模型链、ReME 自动生成/检索适配器、Neo4j 记忆图写入查询
和跨存储物理清除闭环。这些能力在 UI 中均明确标为未配置，不以占位数据伪装成功。
豆包 ASR 是唯一已验证语音模型能力；TTS 与向量调用未通过，不登记也不展示。

本地测试：

```bash
python3 -m venv .venv
.venv/bin/pip install '.[test]'
.venv/bin/pytest
```

部署和验收：

```bash
./scripts/deploy.sh
./scripts/configure-volcengine-speech.sh
./scripts/verify.sh
```

14 号服务器监听：

| 组件 | 地址 |
| --- | --- |
| Lab UI / API / OpenAPI / WebSocket | `127.0.0.1:18280` |
| ReME | `127.0.0.1:12333` |
| Neo4j Browser | `127.0.0.1:17474` |
| Neo4j Bolt | `127.0.0.1:17687` |

通过 SSH 隧道访问：

```bash
ssh -L 18280:127.0.0.1:18280 -L 17474:127.0.0.1:17474 k1-openclaw
```

浏览器打开 `http://127.0.0.1:18280/chat`、`/memories` 或 `/ui/status`。所有服务仅监听
回环地址；运行凭证不写入仓库，也不在验收输出中回显。

需要临时公网访问时，从仓库根目录运行 `./scripts/public-access.sh open`。公网页面是
`http://14.103.221.4/lab/chat`、`/lab/memories`、`/lab/evaluations` 与 `/lab/ui/status`；
WebSocket 地址为 `ws://14.103.221.4/lab/ws/v1/spaces/{memory_space}/events`。Caddy 会去除
外层 `/lab` 后再转发，Lab 内部 API 契约保持不变。执行 `close` 可恢复回环监听。
公网 Lab 没有 TLS 或应用层鉴权，只允许合成测试数据；ReME 与 Neo4j 不随 Lab 一起公开。
浏览器通常禁止普通 HTTP 地址调用麦克风，因此公网 HTTP 页面会禁用录音按钮并提示使用
HTTPS 或 `localhost` SSH 隧道；记忆、状态、评测与 WebSocket 功能仍可正常验证。

详见 [架构契约](docs/ARCHITECTURE.md)、[整体设计复核](docs/DESIGN-REVIEW.md)、
[前端规格](docs/FRONTEND-SPEC.md) 和 [官方版本兼容性](docs/OFFICIAL-COMPATIBILITY.md)。
