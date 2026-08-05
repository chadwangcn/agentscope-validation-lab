# AgentScope dependency contract

This repository does not vendor or follow the AgentScope `main` branch. The
validation service is assembled from the exact upstream repository and commit
in `agentscope.lock.env`, then the patches under `deploy/patches/` are applied
in this order:

1. `agentscope-runtime-env.patch`
2. `agentscope-web-ui-ip-path.patch`
3. `agentscope-credential-redaction.patch`
4. `agentscope-credential-model-filter.patch`

`agentscope-overlay-files.txt` is an allowlist. Source preparation fails if a
patch changes any other upstream file. GitHub CI repeats the same preparation
and builds the upstream Web UI before an OCI image can be published.

The documentation channel is `2.0.6dev`, while the pinned source reports
package version `2.0.5`. Both values are intentionally retained. Updating the
commit, patch set, package version, or allowlist is a reviewed dependency
change and requires all acceptance tests to run again.

No API key, provider endpoint, model identifier, password, or server runtime
data belongs in this directory.
