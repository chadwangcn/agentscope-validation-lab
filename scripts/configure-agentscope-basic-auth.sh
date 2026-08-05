#!/usr/bin/env bash
set -Eeuo pipefail

host_alias="${PUBLIC_ACCESS_HOST_ALIAS:-k1-openclaw}"
public_ip="${PUBLIC_ACCESS_IP:-14.103.221.4}"
auth_user="${AGENTSCOPE_PUBLIC_AUTH_USER:-agentscope}"
keychain_service="${AGENTSCOPE_PUBLIC_KEYCHAIN_SERVICE:-codex.agentscope-14.public-basic-auth}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! printf '%s' "${auth_user}" | grep -Eq '^[A-Za-z0-9._-]{1,64}$'; then
  echo "Invalid Basic Auth username" >&2
  exit 2
fi

if security find-generic-password -a "${auth_user}" -s "${keychain_service}" >/dev/null 2>&1; then
  auth_password="$(security find-generic-password -a "${auth_user}" -s "${keychain_service}" -w)"
else
  auth_password="$(openssl rand -hex 24)"
  test "${#auth_password}" -ge 24
  security add-generic-password -U \
    -a "${auth_user}" \
    -s "${keychain_service}" \
    -w "${auth_password}" >/dev/null
fi

auth_hash="$(printf '%s\n' "${auth_password}" | ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'docker exec -i lumi-backend-service-caddy-1 caddy hash-password --algorithm bcrypt')"
if ! printf '%s' "${auth_hash}" | grep -Eq '^\$2[aby]\$'; then
  echo "Caddy did not return a bcrypt hash" >&2
  exit 1
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  "bash -s -- '${auth_user}' '${auth_hash}'" <<'REMOTE'
set -Eeuo pipefail
auth_user="$1"
auth_hash="$2"
auth_dir="/etc/agentscope-public-access"
user_tmp="$(mktemp)"
hash_tmp="$(mktemp)"
cleanup() {
  find "${user_tmp}" "${hash_tmp}" -maxdepth 0 -type f -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT
printf '%s\n' "${auth_user}" >"${user_tmp}"
printf '%s\n' "${auth_hash}" >"${hash_tmp}"
install -d -m 0700 "${auth_dir}"
install -m 0600 "${user_tmp}" "${auth_dir}/basic-auth-user"
install -m 0600 "${hash_tmp}" "${auth_dir}/basic-auth.hash"
REMOTE

unset auth_password auth_hash
"${script_dir}/deploy-ip-path-ingress.sh"

unauth_ui="$(curl --noproxy '*' -sS --max-time 8 -o /dev/null -w '%{http_code}' \
  "http://${public_ip}/agentscope/")"
unauth_api="$(curl --noproxy '*' -sS --max-time 8 -o /dev/null -w '%{http_code}' \
  "http://${public_ip}/agentscope-api/openapi.json")"
auth_password="$(security find-generic-password -a "${auth_user}" -s "${keychain_service}" -w)"
auth_ui="$(curl --noproxy '*' -sS --max-time 8 -u "${auth_user}:${auth_password}" \
  -o /dev/null -w '%{http_code}' "http://${public_ip}/agentscope/")"
auth_api="$(curl --noproxy '*' -sS --max-time 8 -u "${auth_user}:${auth_password}" \
  -o /dev/null -w '%{http_code}' "http://${public_ip}/agentscope-api/openapi.json")"
unset auth_password

test "${unauth_ui}" = 401
test "${unauth_api}" = 401
test "${auth_ui}" = 200
test "${auth_api}" = 200

printf 'AgentScope Basic Auth configured.\n'
printf 'Username: %s\n' "${auth_user}"
printf 'Password: stored in macOS Keychain service %s\n' "${keychain_service}"
