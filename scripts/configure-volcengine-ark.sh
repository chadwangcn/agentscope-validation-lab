#!/usr/bin/env bash
set -Eeuo pipefail

host_alias="${AGENTSCOPE_HOST_ALIAS:-k1-openclaw}"
user_id="${AGENTSCOPE_USER_ID:-synthetic-test-user}"
keychain_service="${VOLCENGINE_ARK_KEYCHAIN_SERVICE:-volcengine.ark}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${script_dir}/internal/configure-volcengine-ark.py"
remote_helper="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'mktemp /tmp/configure-volcengine-ark.XXXXXX.py')"

cleanup() {
  unset ark_api_key ark_base_url ark_model
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
    "find '${remote_helper}' -maxdepth 0 -type f -delete" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! printf '%s' "${user_id}" | grep -Eq '^[A-Za-z0-9._-]{3,64}$'; then
  echo "Invalid AgentScope user ID" >&2
  exit 2
fi

for keychain_account in api_key base_url model; do
  if ! security find-generic-password \
    -s "${keychain_service}" -a "${keychain_account}" >/dev/null 2>&1; then
    echo "Missing Keychain item: service=${keychain_service}, account=${keychain_account}" >&2
    exit 1
  fi
done

ark_api_key="$(security find-generic-password -s "${keychain_service}" -a api_key -w)"
ark_base_url="$(security find-generic-password -s "${keychain_service}" -a base_url -w)"
ark_model="$(security find-generic-password -s "${keychain_service}" -a model -w)"

scp -q "${helper}" "${host_alias}:${remote_helper}"

ARK_API_KEY_VALUE="${ark_api_key}" \
ARK_BASE_URL_VALUE="${ark_base_url}" \
ARK_MODEL_VALUE="${ark_model}" \
python3 - <<'PY' | ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  "/opt/agentscope-2.0.6dev/venv/bin/python '${remote_helper}' '${user_id}'"
import json
import os

print(
    json.dumps(
        {
            "api_key": os.environ["ARK_API_KEY_VALUE"],
            "base_url": os.environ["ARK_BASE_URL_VALUE"],
            "model": os.environ["ARK_MODEL_VALUE"],
        },
    ),
)
PY

trap - EXIT
cleanup
