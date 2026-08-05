#!/usr/bin/env bash
set -euo pipefail

action="${1:-status}"
host_alias="${PUBLIC_ACCESS_HOST_ALIAS:-k1-openclaw}"
public_ip="${PUBLIC_ACCESS_IP:-14.103.221.4}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
public_ui_host="${PUBLIC_ACCESS_UI_HOST:-}"
public_api_host="${PUBLIC_ACCESS_API_HOST:-}"
public_lab_host="${PUBLIC_ACCESS_LAB_HOST:-}"
remote_ui_host="${public_ui_host:-__UNSET__}"
remote_api_host="${public_api_host:-__UNSET__}"
remote_lab_host="${public_lab_host:-__UNSET__}"

case "${action}" in
  open|close|status) ;;
  *)
    echo "Usage: $0 open|close|status" >&2
    exit 2
    ;;
esac

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  bash -s -- "${action}" "${public_ip}" "${remote_ui_host}" "${remote_api_host}" "${remote_lab_host}" <<'REMOTE'
set -euo pipefail

action="$1"
public_ip="$2"
public_ui_host="$3"
public_api_host="$4"
public_lab_host="$5"
[ "${public_ui_host}" = "__UNSET__" ] && public_ui_host=""
[ "${public_api_host}" = "__UNSET__" ] && public_api_host=""
[ "${public_lab_host}" = "__UNSET__" ] && public_lab_host=""
services=(
  agentscope-test-backend.service
  agentscope-test-frontend.service
  talk-think-memory-lab.service
)

write_override() {
  local service="$1"
  local bind_host="$2"
  local override_dir="/etc/systemd/system/${service}.d"
  local temporary
  temporary="$(mktemp)"
  trap 'rm -f "${temporary}"' RETURN
  printf '[Service]\nEnvironment=BIND_HOST=%s\n' "${bind_host}" >"${temporary}"
  install -d -m 0755 "${override_dir}"
  install -m 0644 "${temporary}" "${override_dir}/public-bind.conf"
  rm -f "${temporary}"
  trap - RETURN
}

wait_for_http() {
  local url="$1"
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for ${url}" >&2
  return 1
}

assert_listener() {
  local address="$1"
  if ! ss -ltnH | awk '{print $4}' | grep -Fxq "${address}"; then
    echo "Expected listener missing: ${address}" >&2
    return 1
  fi
}

assert_loopback_only() {
  local port="$1"
  local addresses
  addresses="$(ss -ltnH | awk -v port=":${port}" '$4 ~ (port "$") {print $4}' | sort -u | paste -sd, -)"
  if [ "${addresses}" != "127.0.0.1:${port}" ]; then
    echo "Expected only 127.0.0.1:${port}, found: ${addresses:-none}" >&2
    return 1
  fi
}

effective_bind_host() {
  local service="$1"
  systemctl show -p Environment --value "${service}" \
    | tr ' ' '\n' | sed -n 's/^BIND_HOST=//p' | tail -n1
}

http_status() {
  local host="$1"
  local path="$2"
  local status
  status="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://127.0.0.1${path}" 2>/dev/null || true)"
  printf '%s' "${status:-000}"
}

print_status() {
  local api_host ui_host lab_host mode caddy_gateway
  local listeners
  api_host="$(effective_bind_host agentscope-test-backend.service)"
  ui_host="$(effective_bind_host agentscope-test-frontend.service)"
  lab_host="$(effective_bind_host talk-think-memory-lab.service)"
  if [ "${api_host}" = "0.0.0.0" ] && [ "${ui_host}" = "0.0.0.0" ] && [ "${lab_host}" = "0.0.0.0" ]; then
    mode=public
  elif [ "${api_host}" = "127.0.0.1" ] && [ "${ui_host}" = "127.0.0.1" ] && [ "${lab_host}" = "127.0.0.1" ]; then
    mode=loopback
  else
    mode=mixed
  fi
  caddy_gateway="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' lumi-backend-service-caddy-1 2>/dev/null || true)"
  listeners="$(ss -ltnH \
    | awk '$4 ~ /:(6379|12333|15173|17474|17687|18080|18280)$/ {print $4}' \
    | sort | paste -sd, -)"
  printf '{\n'
  printf '  "mode": "%s",\n' "${mode}"
  printf '  "bind_hosts": {\n'
  printf '    "agentscope_ui": "%s",\n' "${ui_host}"
  printf '    "agentscope_api": "%s",\n' "${api_host}"
  printf '    "lab": "%s"\n' "${lab_host}"
  printf '  },\n'
  printf '  "services": {\n'
  printf '    "agentscope_ui": "%s",\n' "$(systemctl is-active agentscope-test-frontend.service)"
  printf '    "agentscope_api": "%s",\n' "$(systemctl is-active agentscope-test-backend.service)"
  printf '    "lab": "%s"\n' "$(systemctl is-active talk-think-memory-lab.service)"
  printf '  },\n'
  printf '  "public_urls": {\n'
  printf '    "agentscope_ui": "http://%s/agentscope/",\n' "${public_ip}"
  printf '    "agentscope_api": "http://%s/agentscope-api/",\n' "${public_ip}"
  printf '    "lab": "http://%s/lab/"\n' "${public_ip}"
  printf '  },\n'
  if [ -n "${public_ui_host}" ] && [ -n "${public_api_host}" ] && [ -n "${public_lab_host}" ]; then
    printf '  "optional_domain_urls": {\n'
    printf '    "agentscope_ui": "http://%s",\n' "${public_ui_host}"
    printf '    "agentscope_api": "http://%s",\n' "${public_api_host}"
    printf '    "lab": "http://%s"\n' "${public_lab_host}"
    printf '  },\n'
  else
    printf '  "optional_domain_urls": null,\n'
  fi
  printf '  "direct_high_port_urls": {\n'
  printf '    "agentscope_ui": "http://%s:15173",\n' "${public_ip}"
  printf '    "agentscope_api": "http://%s:18080",\n' "${public_ip}"
  printf '    "lab": "http://%s:18280"\n' "${public_ip}"
  printf '  },\n'
  printf '  "ingress": {\n'
  printf '    "caddy_gateway": "%s",\n' "${caddy_gateway}"
  ui_http="$(http_status "${public_ip}" /agentscope/)"
  api_http="$(http_status "${public_ip}" /agentscope-api/openapi.json)"
  lab_http="$(http_status "${public_ip}" /lab/health)"
  if [ "${ui_http}" = 401 ] && [ "${api_http}" = 401 ] && [ "${lab_http}" = 200 ]; then
    printf '    "configured": true,\n'
  else
    printf '    "configured": false,\n'
  fi
  printf '    "agentscope_ui_http": "%s",\n' "${ui_http}"
  printf '    "agentscope_api_http": "%s",\n' "${api_http}"
  printf '    "lab_http": "%s",\n' "${lab_http}"
  printf '    "agentscope_auth_required": true\n'
  printf '  },\n'
  printf '  "listeners": "%s"\n' "${listeners}"
  printf '}\n'
}

if [ "${action}" = "status" ]; then
  print_status
  exit 0
fi

if [ "${action}" = "open" ]; then
  bind_host="0.0.0.0"
else
  bind_host="127.0.0.1"
fi

for service in "${services[@]}"; do
  write_override "${service}" "${bind_host}"
done

systemctl daemon-reload
systemd-analyze verify "${services[@]}"
systemctl restart "${services[@]}"

wait_for_http http://127.0.0.1:15173/agentscope/
wait_for_http http://127.0.0.1:18080/openapi.json
wait_for_http http://127.0.0.1:18280/health

assert_listener "${bind_host}:15173"
assert_listener "${bind_host}:18080"
assert_listener "${bind_host}:18280"
assert_loopback_only 6379
assert_loopback_only 12333
assert_loopback_only 17474
assert_loopback_only 17687

if [ "${action}" = "open" ]; then
  echo "WARNING: AgentScope and Lab now listen on all interfaces without application authentication." >&2
  echo "Run this script with 'close' to restore loopback-only access." >&2
else
  print_status
fi
REMOTE

if [ "${action}" = "open" ]; then
  "${script_dir}/deploy-ip-path-ingress.sh"
  exec "${script_dir}/public-access.sh" status
fi
