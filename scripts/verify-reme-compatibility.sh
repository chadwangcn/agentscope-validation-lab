#!/usr/bin/env bash
set -euo pipefail

python_bin="${PYTHON_BIN:-python}"
reme_bin="${REME_BIN:-reme}"
port="${REME_SMOKE_PORT:-12339}"
workspace_dir="$(mktemp -d /tmp/reme-agentscope-206dev.XXXXXX)"
log_file="$(mktemp /tmp/reme-agentscope-206dev.XXXXXX.log)"

cleanup() {
  if [ -n "${server_pid:-}" ]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  find "${workspace_dir}" -depth -delete >/dev/null 2>&1 || true
  find "${log_file}" -maxdepth 0 -type f -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${python_bin}" - <<'PY'
import agentscope
import reme

assert agentscope.__version__ == "2.0.5", agentscope.__version__
assert reme.__version__ == "0.4.1.3", reme.__version__
PY

env \
  -u ALL_PROXY -u all_proxy \
  -u HTTP_PROXY -u http_proxy \
  -u HTTPS_PROXY -u https_proxy \
  LLM_API_KEY=validation-smoke-no-provider-call \
  NO_PROXY=127.0.0.1,localhost \
  no_proxy=127.0.0.1,localhost \
  "${reme_bin}" start \
  "workspace_dir=${workspace_dir}" \
  enable_logo=false \
  log_to_file=false \
  service.host=127.0.0.1 \
  "service.port=${port}" >"${log_file}" 2>&1 &
server_pid="$!"

for _ in $(seq 1 45); do
  if ! kill -0 "${server_pid}" >/dev/null 2>&1; then
    sed -n '1,160p' "${log_file}" >&2
    exit 1
  fi
  if curl -fsS --max-time 2 -X POST \
    -H 'Content-Type: application/json' \
    --data '{}' \
    "http://127.0.0.1:${port}/version" 2>/dev/null \
    | "${python_bin}" -c 'import json,sys; payload=json.load(sys.stdin); assert payload' \
    >/dev/null 2>&1; then
    if grep -Eq 'ERROR|Traceback|Missing credentials' "${log_file}"; then
      sed -n '1,160p' "${log_file}" >&2
      exit 1
    fi
    echo "ReME 0.4.1.3 compatibility smoke passed with AgentScope 2.0.6dev source line."
    exit 0
  fi
  sleep 1
done

sed -n '1,160p' "${log_file}" >&2
exit 1
