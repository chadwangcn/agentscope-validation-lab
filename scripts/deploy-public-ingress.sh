#!/usr/bin/env bash
set -euo pipefail

host_alias="${PUBLIC_ACCESS_HOST_ALIAS:-k1-openclaw}"
public_ui_host="${PUBLIC_ACCESS_UI_HOST:?Set PUBLIC_ACCESS_UI_HOST to an approved domain}"
public_api_host="${PUBLIC_ACCESS_API_HOST:?Set PUBLIC_ACCESS_API_HOST to an approved domain}"
public_lab_host="${PUBLIC_ACCESS_LAB_HOST:?Set PUBLIC_ACCESS_LAB_HOST to an approved domain}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
snippet_template="${project_root}/deploy/caddy/agentscope-lab-public.caddy"
snippet="$(mktemp)"
remote_snippet="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'mktemp /tmp/agentscope-lab-public.XXXXXX.caddy')"

cleanup() {
  find "${snippet}" -maxdepth 0 -type f -delete >/dev/null 2>&1 || true
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
    "find '${remote_snippet}' -maxdepth 0 -type f -delete" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for public_host in "${public_ui_host}" "${public_api_host}" "${public_lab_host}"; do
  if ! printf '%s' "${public_host}" | grep -Eq '^[a-z0-9.-]+$'; then
    echo "Invalid public host: ${public_host}" >&2
    exit 2
  fi
done

sed \
  -e "s/__AGENTSCOPE_UI_HOST__/${public_ui_host}/g" \
  -e "s/__AGENTSCOPE_API_HOST__/${public_api_host}/g" \
  -e "s/__LAB_HOST__/${public_lab_host}/g" \
  "${snippet_template}" >"${snippet}"

scp -q "${snippet}" "${host_alias}:${remote_snippet}"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  "bash -s -- '${remote_snippet}' '${public_ui_host}' '${public_api_host}' '${public_lab_host}'" <<'REMOTE'
set -Eeuo pipefail

snippet="$1"
public_ui_host="$2"
public_api_host="$3"
public_lab_host="$4"
compose_root="/opt/lumi-backend-service"
caddyfile="${compose_root}/deploy/Caddyfile"
container="lumi-backend-service-caddy-1"
candidate="$(mktemp /tmp/Caddyfile.agentscope-lab.XXXXXX)"
container_candidate="/tmp/Caddyfile.agentscope-lab.candidate"

cleanup_remote() {
  find "${candidate}" -maxdepth 0 -type f -delete >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT

python3 - "${caddyfile}" "${snippet}" "${candidate}" <<'PY'
from pathlib import Path
import sys

source_path, snippet_path, candidate_path = map(Path, sys.argv[1:])
source = source_path.read_text()
snippet = snippet_path.read_text().strip()
begin = "# BEGIN AGENTSCOPE LAB PUBLIC INGRESS"
end = "# END AGENTSCOPE LAB PUBLIC INGRESS"

if source.count(begin) != source.count(end) or source.count(begin) > 1:
    raise SystemExit("Refusing inconsistent AgentScope Lab ingress markers")
if begin in source:
    prefix, remainder = source.split(begin, 1)
    _, suffix = remainder.split(end, 1)
    source = prefix.rstrip() + "\n\n" + suffix.lstrip()

Path(candidate_path).write_text(source.rstrip() + "\n\n" + snippet + "\n")
PY

docker cp "${candidate}" "${container}:${container_candidate}"
docker exec "${container}" caddy validate --config "${container_candidate}" --adapter caddyfile

changed=true
if cmp -s "${candidate}" "${caddyfile}"; then
  changed=false
fi

if [ "${changed}" = true ]; then
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${compose_root}/deploy/backups/Caddyfile.before-agentscope-lab-${timestamp}.bak"
  install -d -m 0755 "${compose_root}/deploy/backups"
  cp -p "${caddyfile}" "${backup}"

  rollback() {
    rc=$?
    trap - ERR
    set +e
    echo "Caddy ingress deployment failed; restoring ${backup}" >&2
    cp -p "${backup}" "${caddyfile}"
    cd "${compose_root}"
    docker compose up -d --force-recreate --no-deps caddy
    exit "${rc}"
  }
  trap rollback ERR

  cp "${candidate}" "${caddyfile}"
  cd "${compose_root}"
  docker compose up -d --force-recreate --no-deps caddy
  printf 'Caddy ingress updated; backup=%s\n' "${backup}"
else
  echo "Caddy ingress already matches the repository snippet."
fi

docker exec "${container}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
gateway="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "${container}")"
test "${gateway}" = "172.19.0.1"

if ss -ltnH | awk '{print $4}' | grep -Fxq '0.0.0.0:15173'; then
  for target in \
    "${public_ui_host} /" \
    "${public_api_host} /openapi.json" \
    "${public_lab_host} /health"; do
    host="${target%% *}"
    path="${target#* }"
    for _ in $(seq 1 30); do
      code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://127.0.0.1${path}" || true)"
      [ "${code}" = 200 ] && break
      sleep 1
    done
    test "${code}" = 200
  done
fi

if [ "${changed}" = true ]; then
  trap - ERR
fi
REMOTE

trap - EXIT
cleanup
