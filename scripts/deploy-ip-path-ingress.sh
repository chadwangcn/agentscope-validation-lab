#!/usr/bin/env bash
set -Eeuo pipefail

host_alias="${PUBLIC_ACCESS_HOST_ALIAS:-k1-openclaw}"
public_ip="${PUBLIC_ACCESS_IP:-14.103.221.4}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
snippet_template="${project_root}/deploy/caddy/agentscope-lab-ip-path.caddy"
remote_template="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'mktemp /tmp/agentscope-lab-ip-path.XXXXXX.caddy')"

cleanup() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
    "find '${remote_template}' -maxdepth 0 -type f -delete" >/dev/null 2>&1 || true
}
trap cleanup EXIT

scp -q "${snippet_template}" "${host_alias}:${remote_template}"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  "bash -s -- '${remote_template}' '${public_ip}'" <<'REMOTE'
set -Eeuo pipefail

snippet_template="$1"
public_ip="$2"
compose_root="/opt/lumi-backend-service"
caddyfile="${compose_root}/deploy/Caddyfile"
container="lumi-backend-service-caddy-1"
candidate="$(mktemp /tmp/Caddyfile.agentscope-lab-ip-path.XXXXXX)"
snippet="$(mktemp /tmp/agentscope-lab-ip-path.rendered.XXXXXX.caddy)"
container_candidate="/tmp/Caddyfile.agentscope-lab-ip-path.candidate"
auth_dir="/etc/agentscope-public-access"
auth_user_file="${auth_dir}/basic-auth-user"
auth_hash_file="${auth_dir}/basic-auth.hash"

cleanup_remote() {
  find "${candidate}" "${snippet}" -maxdepth 0 -type f -delete >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT

gateway="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "${container}")"
if ! printf '%s' "${gateway}" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
  echo "Unable to resolve the Caddy host gateway" >&2
  exit 1
fi
if [ ! -s "${auth_user_file}" ] || [ ! -s "${auth_hash_file}" ]; then
  echo "AgentScope Basic Auth is not configured; run scripts/configure-agentscope-basic-auth.sh" >&2
  exit 1
fi
auth_user="$(tr -d '\r\n' <"${auth_user_file}")"
auth_hash="$(tr -d '\r\n' <"${auth_hash_file}")"
if ! printf '%s' "${auth_user}" | grep -Eq '^[A-Za-z0-9._-]{1,64}$'; then
  echo "Invalid AgentScope Basic Auth username" >&2
  exit 1
fi
if ! printf '%s' "${auth_hash}" | grep -Eq '^\$2[aby]\$'; then
  echo "Invalid AgentScope Basic Auth bcrypt hash" >&2
  exit 1
fi
sed \
  -e "s/__CADDY_HOST_GATEWAY__/${gateway}/g" \
  -e "s/__AGENTSCOPE_BASIC_AUTH_USER__/${auth_user}/g" \
  -e "s|__AGENTSCOPE_BASIC_AUTH_HASH__|${auth_hash}|g" \
  "${snippet_template}" >"${snippet}"

root_status_before="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' \
  -H "Host: ${public_ip}" http://127.0.0.1/ || true)"

python3 - "${caddyfile}" "${snippet}" "${candidate}" <<'PY'
from pathlib import Path
import sys
import textwrap

source_path, snippet_path, candidate_path = map(Path, sys.argv[1:])
source = source_path.read_text()
snippet = snippet_path.read_text().strip()
begin = "# BEGIN AGENTSCOPE LAB IP PATH INGRESS"
end = "# END AGENTSCOPE LAB IP PATH INGRESS"
anchor = "{$LUMI_DOMAIN} {"

if source.count(begin) != source.count(end) or source.count(begin) > 1:
    raise SystemExit("Refusing inconsistent AgentScope Lab IP path markers")
if begin in source:
    prefix, remainder = source.split(begin, 1)
    _, suffix = remainder.split(end, 1)
    source = prefix.rstrip() + "\n" + suffix.lstrip("\n")
if source.count(anchor) != 1:
    raise SystemExit("Expected exactly one Lumi Caddy site anchor")

rendered = textwrap.indent(snippet, "\t")
source = source.replace(anchor, f"{anchor}\n\n{rendered}", 1)
candidate_path.write_text(source.rstrip() + "\n")
PY

docker cp "${candidate}" "${container}:${container_candidate}"
docker exec "${container}" caddy validate --config "${container_candidate}" --adapter caddyfile

changed=true
if cmp -s "${candidate}" "${caddyfile}"; then
  changed=false
fi

if [ "${changed}" = true ]; then
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${compose_root}/deploy/backups/Caddyfile.before-agentscope-lab-ip-path-${timestamp}.bak"
  install -d -m 0755 "${compose_root}/deploy/backups"
  cp -p "${caddyfile}" "${backup}"

  rollback() {
    rc=$?
    trap - ERR
    set +e
    echo "Caddy IP path deployment failed; restoring ${backup}" >&2
    cp -p "${backup}" "${caddyfile}"
    cd "${compose_root}"
    docker compose up -d --force-recreate --no-deps caddy
    exit "${rc}"
  }
  trap rollback ERR

  cp "${candidate}" "${caddyfile}"
  cd "${compose_root}"
  docker compose up -d --force-recreate --no-deps caddy
  printf 'Caddy IP path ingress updated; backup=%s\n' "${backup}"
else
  echo "Caddy IP path ingress already matches the repository snippet."
fi

for _ in $(seq 1 30); do
  ui_code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' -H "Host: ${public_ip}" http://127.0.0.1/agentscope/ || true)"
  api_code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' -H "Host: ${public_ip}" http://127.0.0.1/agentscope-api/openapi.json || true)"
  lab_code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' -H "Host: ${public_ip}" http://127.0.0.1/lab/health || true)"
  [ "${ui_code}" = 401 ] && [ "${api_code}" = 401 ] && [ "${lab_code}" = 200 ] && break
  sleep 1
done
test "${ui_code}" = 401
test "${api_code}" = 401
test "${lab_code}" = 200

root_status_after="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' \
  -H "Host: ${public_ip}" http://127.0.0.1/ || true)"
test "${root_status_after}" = "${root_status_before}"
docker exec "${container}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

if [ "${changed}" = true ]; then
  trap - ERR
fi

printf 'AgentScope UI:  http://%s/agentscope/\n' "${public_ip}"
printf 'AgentScope API: http://%s/agentscope-api/\n' "${public_ip}"
printf 'Lab:            http://%s/lab/\n' "${public_ip}"
REMOTE

trap - EXIT
cleanup
