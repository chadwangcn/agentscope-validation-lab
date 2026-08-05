#!/usr/bin/env bash
set -euo pipefail

host_alias="${AGENTSCOPE_HOST_ALIAS:-k1-openclaw}"
remote_root="/opt/agentscope-2.0.6dev"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
lock_file="${project_root}/dependencies/agentscope.lock.env"
# shellcheck disable=SC1090
. "${lock_file}"
source_repository="${AGENTSCOPE_SOURCE_REPOSITORY}"
source_commit="${AGENTSCOPE_SOURCE_COMMIT}"
runtime_overlay="${project_root}/deploy/patches/agentscope-runtime-env.patch"
web_ui_overlay="${project_root}/deploy/patches/agentscope-web-ui-ip-path.patch"
credential_redaction_overlay="${project_root}/deploy/patches/agentscope-credential-redaction.patch"
credential_model_filter_overlay="${project_root}/deploy/patches/agentscope-credential-model-filter.patch"
remote_runtime_overlay="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'mktemp /tmp/agentscope-runtime-env.XXXXXX.patch')"
remote_overlay="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'mktemp /tmp/agentscope-web-ui-overlay.XXXXXX.patch')"
remote_credential_overlay="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'mktemp /tmp/agentscope-credential-redaction.XXXXXX.patch')"
remote_model_filter_overlay="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'mktemp /tmp/agentscope-credential-model-filter.XXXXXX.patch')"

cleanup() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
    "find '${remote_runtime_overlay}' '${remote_overlay}' '${remote_credential_overlay}' '${remote_model_filter_overlay}' -maxdepth 0 -type f -delete" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

scp -q "${runtime_overlay}" "${host_alias}:${remote_runtime_overlay}"
scp -q "${web_ui_overlay}" "${host_alias}:${remote_overlay}"
scp -q "${credential_redaction_overlay}" "${host_alias}:${remote_credential_overlay}"
scp -q "${credential_model_filter_overlay}" "${host_alias}:${remote_model_filter_overlay}"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  "bash -s -- '${remote_root}' '${source_repository}' '${source_commit}' '${remote_runtime_overlay}' '${remote_overlay}' '${remote_credential_overlay}' '${remote_model_filter_overlay}'" <<'REMOTE'
set -euo pipefail

remote_root="$1"
source_repository="$2"
source_commit="$3"
runtime_overlay="$4"
web_ui_overlay="$5"
credential_redaction_overlay="$6"
credential_model_filter_overlay="$7"
source_dir="${remote_root}/source"
venv_dir="${remote_root}/venv"

install -d -m 0755 "${remote_root}"

if [ ! -d "${source_dir}/.git" ]; then
  git init "${source_dir}"
  git -C "${source_dir}" remote add origin "${source_repository}"
else
  current_origin="$(git -C "${source_dir}" remote get-url origin)"
  if [ "${current_origin}" != "${source_repository}" ]; then
    echo "Refusing unexpected source origin: ${current_origin}" >&2
    exit 1
  fi
fi

if ! git -C "${source_dir}" cat-file -e "${source_commit}^{commit}" 2>/dev/null; then
  git -C "${source_dir}" fetch --depth 1 origin "${source_commit}"
fi
git -C "${source_dir}" checkout --detach --force "${source_commit}"
test "$(git -C "${source_dir}" rev-parse HEAD)" = "${source_commit}"
git -C "${source_dir}" apply --recount --check "${runtime_overlay}"
git -C "${source_dir}" apply --recount "${runtime_overlay}"
git -C "${source_dir}" apply --check "${web_ui_overlay}"
git -C "${source_dir}" apply "${web_ui_overlay}"
git -C "${source_dir}" apply --check "${credential_redaction_overlay}"
git -C "${source_dir}" apply "${credential_redaction_overlay}"
git -C "${source_dir}" apply --recount --check "${credential_model_filter_overlay}"
git -C "${source_dir}" apply --recount "${credential_model_filter_overlay}"
git -C "${source_dir}" diff --check
test "$(git -C "${source_dir}" diff --name-only | sort | paste -sd, -)" = \
  "examples/agent_service/main.py,examples/web_ui/frontend/src/App.tsx,examples/web_ui/frontend/src/api/client.ts,examples/web_ui/frontend/src/api/knowledgeBase.ts,examples/web_ui/frontend/src/api/model.ts,examples/web_ui/frontend/src/api/workspace.ts,examples/web_ui/frontend/src/components/chat/TextInput.tsx,examples/web_ui/frontend/src/hooks/useAvailableModels.ts,examples/web_ui/frontend/src/hooks/useAvailableTTSModels.ts,examples/web_ui/frontend/src/hooks/useMessages.ts,examples/web_ui/frontend/src/pages/chat/ChatViewport.tsx,examples/web_ui/frontend/src/pages/credential/index.tsx,examples/web_ui/frontend/src/utils/common.ts,examples/web_ui/frontend/vite.config.ts,src/agentscope/app/_router/_credential.py,src/agentscope/app/_router/_embedding_model.py,src/agentscope/app/_router/_knowledge_base.py,src/agentscope/app/_router/_model.py,src/agentscope/app/_router/_schema/_embedding_model.py,src/agentscope/app/_router/_schema/_model.py,src/agentscope/app/_router/_schema/_tts_model.py,src/agentscope/app/_router/_session.py,src/agentscope/app/_router/_tts_model.py,src/agentscope/app/_service/_access.py,src/agentscope/app/_service/_knowledge_base.py"

if [ ! -x "${venv_dir}/bin/python" ]; then
  python3 -m venv "${venv_dir}"
fi
"${venv_dir}/bin/python" -m pip install --upgrade pip setuptools wheel
"${venv_dir}/bin/python" -m pip install -e \
  "${source_dir}[service,storage-redis,tools,rag,vdb-qdrant]"

corepack enable pnpm
corepack prepare pnpm@10.14.0 --activate
corepack pnpm --dir "${source_dir}/examples/web_ui" install --frozen-lockfile
corepack pnpm --dir "${source_dir}/examples/web_ui" build:frontend

if /usr/bin/docker inspect agentscope-206dev-redis >/dev/null 2>&1; then
  owner_label="$(/usr/bin/docker inspect --format '{{ index .Config.Labels "io.agentscope.testenv" }}' agentscope-206dev-redis)"
  if [ "${owner_label}" != "2.0.6dev" ]; then
    echo "Refusing to reuse container without expected ownership label" >&2
    exit 1
  fi
else
  if ss -ltn | awk '{print $4}' | grep -Eq '(^|:)6379$'; then
    echo "TCP port 6379 is already in use" >&2
    exit 1
  fi
  /usr/bin/docker pull redis:7.4-alpine
  /usr/bin/docker run -d \
    --name agentscope-206dev-redis \
    --label io.agentscope.testenv=2.0.6dev \
    --restart unless-stopped \
    --cpus 0.25 \
    --memory 256m \
    -p 127.0.0.1:6379:6379 \
    -v agentscope_206dev_redis_data:/data \
    redis:7.4-alpine \
    redis-server --appendonly yes --save 60 1000 \
      --maxmemory 192mb --maxmemory-policy noeviction
fi

/usr/bin/docker start agentscope-206dev-redis >/dev/null
REMOTE

scp -q \
  "${project_root}/deploy/systemd/agentscope-test-backend.service" \
  "${host_alias}:/etc/systemd/system/agentscope-test-backend.service"
scp -q \
  "${project_root}/deploy/systemd/agentscope-test-frontend.service" \
  "${host_alias}:/etc/systemd/system/agentscope-test-frontend.service"
scp -q \
  "${project_root}/deploy/DEPLOYMENT-METADATA" \
  "${host_alias}:${remote_root}/DEPLOYMENT-METADATA"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" '
  set -e
  systemctl daemon-reload
  systemctl enable --now agentscope-test-backend.service
  systemctl enable --now agentscope-test-frontend.service
  systemctl restart agentscope-test-backend.service
  systemctl restart agentscope-test-frontend.service

  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 2 http://127.0.0.1:18080/openapi.json >/dev/null \
      && curl -fsS --max-time 2 http://127.0.0.1:15173/agentscope/ >/dev/null; then
      test "$(systemctl is-active agentscope-test-backend.service)" = active
      test "$(systemctl is-active agentscope-test-frontend.service)" = active
      exit 0
    fi
    sleep 1
  done

  systemctl --no-pager --full status \
    agentscope-test-backend.service agentscope-test-frontend.service >&2 || true
  exit 1
'

echo "AgentScope test environment deployed on ${host_alias}."

trap - EXIT
cleanup
