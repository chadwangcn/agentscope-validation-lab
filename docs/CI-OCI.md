# GitHub CI and OCI delivery contract

## Responsibility boundary

GitHub Actions validates source and publishes OCI images. It does not connect
to, configure, restart, or deploy the SRE validation environment. SRE selects
an accepted image digest, injects runtime secrets, configures DNS/TLS/ingress,
and owns rollout and rollback.

## Source verification

`CI` runs on every pull request and push to `main`:

- rejects generated environments, private keys, and common API-key shapes;
- reads `dependencies/agentscope.lock.env`;
- fetches the exact upstream AgentScope commit;
- applies the four controlled overlays and compares the changed files with the
  allowlist;
- compiles the patched Python code and builds the AgentScope Web UI;
- installs the Lab with the same pinned AgentScope commit, starts ReME and
  calls its real `/version` job, runs Lab API tests, and builds the Lab UI.

CI success is source/build evidence only. It is not provider capability or
deployment acceptance.

## OCI images

The `OCI` workflow builds `linux/amd64` images on pull requests. On `main`, an
SRE delivery tag, or manual dispatch it also publishes to GHCR:

| Component | GHCR image |
| --- | --- |
| Agent Service | `ghcr.io/chadwangcn/agentscope-validation-lab-agentscope-service` |
| AgentScope Web UI | `ghcr.io/chadwangcn/agentscope-validation-lab-agentscope-web` |
| Lab API/UI and optional ReME command | `ghcr.io/chadwangcn/agentscope-validation-lab-memory-lab` |

Each build emits an immutable digest, an SBOM, and BuildKit provenance. SRE
must deploy by digest rather than by `main` or a mutable tag. Redis and Neo4j
remain separately pinned upstream images; they are not rebuilt here.

The Lab image default command starts the Lab API/UI. SRE may use the same image
for ReME by overriding the command, keeping a separate data volume and service
identity:

```text
reme-no-provider workspace_dir=/var/lib/talk-think-memory-lab/reme service.host=0.0.0.0 service.port=12333
```

`reme-no-provider` sets a documented non-secret sentinel only when no
`LLM_API_KEY` exists. This prevents ReME's optional model adapter from logging
a missing-credential startup error; infrastructure health/version checks do
not invoke an LLM job. Real ReME model use still requires a separately tested
SRE runtime secret. Port `12333` must only be reachable on the private
container network.

## Runtime-only configuration

No workflow or Docker build accepts a model credential as a build argument or
secret. The following values are runtime inputs owned by SRE Secret Manager:

- Ark `api_key`, `base_url`, and validated `model`;
- Volcengine Speech `appid` and `api_key`;
- Neo4j password;
- ingress authentication material.

The Agent Service image accepts non-secret runtime topology variables:

- `AGENTSCOPE_REDIS_HOST` and `AGENTSCOPE_REDIS_PORT`;
- `AGENTSCOPE_WORKSPACE_DIR`;
- `AGENTSCOPE_ENABLE_BROWSER_MCP` (disabled in the OCI image by default).

The validated Ark model card is a runtime SRE input, not image content. If the
existing one-shot credential provisioning script is adapted to the container,
its generated model card must be mounted into the corresponding path under
`/opt/agentscope/source/src/agentscope/model/_openai_chat/_models/`, and the
raw Credential is written only to the dedicated Redis. The file content and
Redis data never enter GitHub Actions or an OCI layer.

The Lab image accepts `REME_BASE_URL`, `NEO4J_URI`, `NEO4J_USER`,
`NEO4J_PASSWORD`, and the documented Lab data/speech environment variables.

## SRE release input

For a deployment request, application owners provide:

1. Git commit and signed/reviewed delivery tag;
2. all three GHCR image names and immutable digests;
3. successful `CI` and `OCI` run URLs;
4. the SRE task package and acceptance checklist;
5. no credential values.

The first planned delivery tag is `sre-validation-zone-v0.1.0`.
