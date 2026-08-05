# 官方版本与兼容性记录

核对日期：2026-08-05。

## AgentScope

主环境按用户指定使用 `2.0.6dev` 文档通道和固定官方源码提交
`9edf84602c3af9399808afa448cd222f8fe1f7f9`。该源码自身仍报告包版本 `2.0.5`。
新验证区实验室依赖同一个固定官方源码 commit，不跟随 PyPI `2.0.4`；框架服务、ReME 与 Lab
仍保持独立进程和数据边界，避免把模型、记忆和框架问题混在一起。

## ReME

- 官方仓库：<https://github.com/agentscope-ai/ReMe>
- 固定 PyPI 包：`reme-ai==0.4.1.3`
- 对应官方 Git 标签：`v0.4.1.3`，标签对象
  `b4333fbef8ddd8a48210f1d86cd4759edcd61618`
- Python：3.11+
- Python 入口：`from reme import ReMe`
- 服务入口：`reme start`，默认 `127.0.0.1:2333`；本实验隔离到 `127.0.0.1:12333`
- HTTP 契约：作业映射为 `POST /{job.name}`；普通作业返回 JSON，流作业返回 SSE。
- 已确认的基础作业包括 `version`、`health_check`、`status`、`search`、`read`、`write`、
  `edit`、`delete`、`reindex`、`auto_memory`、`auto_resource`、`auto_dream`、`proactive`。

限制：文件、BM25、Wiki link 等基础能力可无模型凭证运行；embedding 默认关闭；
`auto_memory`、`auto_resource` 和 `auto_dream` 需要运行时 LLM 凭证。当前部署不注入任何模型
凭证，也不把 ReME 自带的文件生命周期当作 Memory Studio 的发布审核契约。

ReME `v0.4.1.3` 的 `[core]` extra 声明固定 `agentscope==2.0.4`，但新验证区不安装该 extra，
而是安装 `reme-ai==0.4.1.3` 基础包和用户指定的 AgentScope `2.0.6dev` 固定源码 commit。
该组合必须在 CI/OCI 中通过 `import reme`、服务启动、`POST /version` 与 Lab API 回归后才可交付；
不能仅以依赖解析成功视为兼容。完整 `[core]` 会引入本阶段不用的 Claude Agent SDK、
OpenAI Codex、FAISS 等依赖，因此仍不安装。

14 号服务器默认 PyPI 镜像缺少这些新版本及部分 FastMCP 元数据依赖，部署脚本只从官方
PyPI 获取固定 wheel 放入隔离 wheelhouse，其余依赖仍走服务器镜像。当前兼容解析固定
`fastmcp==3.2.4`，并在 `/status` 暴露实际版本。

14 号旧环境曾以 `2.0.4` 最小组合验证默认 HTTP 服务、BM25/Wiki link 文件存储和
`POST /version`；新验证区已对 `2.0.6dev` 固定源码组合完成无供应商调用的启动与
`POST /version` 兼容性 smoke，并仍需由 CI 在 Linux OCI 构建中重复。未安装
`[core]` 中的可选组件，因此 Claude/Codex Agent wrapper、FAISS、本地 rjieba 和 cookbook
不属于当前验收范围。后续启用相应能力时必须显式扩展依赖并单独验收。

## Neo4j

- 官方 Community 镜像：`neo4j:2026.06.0`
- 模式：单实例 Community，适合实验和小规模工作组，不具备 Enterprise 的集群、在线备份、
  RBAC 等能力。
- 数据和日志使用独立 Docker volumes。
- 凭证在服务器首次部署时随机生成，分别存入 root/服务用户受限文件；容器使用官方
  `NEO4J_AUTH_FILE` 文件秘密契约，部署和验收均不回显密码。

参考：

- <https://github.com/agentscope-ai/ReMe/tree/v0.4.1.3>
- <https://docs.agentscope.io/reme>
- <https://neo4j.com/docs/operations-manual/current/docker/docker-compose-standalone/>
- <https://neo4j.com/docs/operations-manual/current/docker/introduction/>
