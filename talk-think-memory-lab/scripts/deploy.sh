#!/usr/bin/env bash
set -euo pipefail

host_alias="${LAB_HOST_ALIAS:-k1-openclaw}"
remote_root="/opt/talk-think-memory-lab"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" 'bash -s' <<'REMOTE'
set -euo pipefail

remote_root="/opt/talk-think-memory-lab"
config_dir="/etc/talk-think-memory-lab"
data_dir="/var/lib/talk-think-memory-lab"

if ! id talkthinklab >/dev/null 2>&1; then
  useradd --system --home-dir "${data_dir}" --shell /usr/sbin/nologin talkthinklab
fi
install -d -m 0755 "${remote_root}" "${remote_root}/source"
install -d -o talkthinklab -g talkthinklab -m 0750 "${data_dir}" "${data_dir}/traces" "${data_dir}/reme"
install -d -o root -g talkthinklab -m 0750 "${config_dir}"

auth_file="${config_dir}/neo4j_auth.txt"
env_file="${config_dir}/lab.env"
if [ ! -s "${auth_file}" ] && [ ! -s "${env_file}" ]; then
  neo4j_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(36))')"
  umask 077
  printf 'neo4j/%s\n' "${neo4j_password}" >"${auth_file}"
  {
    printf 'LAB_DATA_DIR=%s\n' "${data_dir}"
    printf 'LAB_SQLITE_PATH=%s\n' "${data_dir}/lab.sqlite3"
    printf 'LAB_TRACE_DIR=%s\n' "${data_dir}/traces"
    printf 'REME_BASE_URL=http://127.0.0.1:12333\n'
    printf 'NEO4J_URI=bolt://127.0.0.1:17687\n'
    printf 'NEO4J_USER=neo4j\n'
    printf 'NEO4J_PASSWORD=%s\n' "${neo4j_password}"
  } >"${env_file}"
  unset neo4j_password
  umask 022
elif [ ! -s "${auth_file}" ] || [ ! -s "${env_file}" ]; then
  echo "Refusing incomplete credential state in ${config_dir}" >&2
  exit 1
fi
chown 7474:7474 "${auth_file}"
chmod 0400 "${auth_file}"
chown root:talkthinklab "${env_file}"
chmod 0640 "${env_file}"

if [ ! -x "${remote_root}/venv/bin/python" ]; then
  python3 -m venv "${remote_root}/venv"
fi
REMOTE

rsync -az \
  --exclude '__pycache__/' \
  --exclude '.pytest_cache/' \
  --exclude 'node_modules/' \
  "${project_root}/app" \
  "${project_root}/deploy" \
  "${project_root}/docs" \
  "${project_root}/frontend" \
  "${project_root}/tests" \
  "${project_root}/pyproject.toml" \
  "${project_root}/README.md" \
  "${host_alias}:${remote_root}/source/"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" 'bash -s' <<'REMOTE'
set -euo pipefail

remote_root="/opt/talk-think-memory-lab"
config_dir="/etc/talk-think-memory-lab"

"${remote_root}/venv/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null
cd "${remote_root}/source/frontend"
npm ci
npm run build
install -d -m 0755 "${remote_root}/wheels"
"${remote_root}/venv/bin/python" -m pip download \
  --no-deps \
  --only-binary=:all: \
  --index-url https://pypi.org/simple \
  --dest "${remote_root}/wheels" \
  reme-ai==0.4.1.3 \
  fastmcp==3.4.5 \
  fastmcp-slim==3.4.5 \
  griffelib==2.1.0 \
  uncalled-for==0.3.2
"${remote_root}/venv/bin/python" -m pip install \
  --find-links "${remote_root}/wheels" \
  "${remote_root}/source[test]"
chown -R root:talkthinklab "${remote_root}"
chmod -R g+rX "${remote_root}"

container="talk-think-memory-lab-neo4j"
image="neo4j:2026.06.0"
if docker inspect "${container}" >/dev/null 2>&1; then
  owner_label="$(docker inspect --format '{{ index .Config.Labels "io.talkthinkmemory.lab" }}' "${container}")"
  if [ "${owner_label}" != "true" ]; then
    echo "Refusing container without talk-think-memory-lab ownership label" >&2
    exit 1
  fi
else
  for port in 17474 17687; do
    if ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
      echo "TCP port ${port} is already in use" >&2
      exit 1
    fi
  done
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    docker pull "${image}"
  fi
  docker run -d \
    --name "${container}" \
    --label io.talkthinkmemory.lab=true \
    --restart unless-stopped \
    --cpus 0.75 \
    --memory 1536m \
    -p 127.0.0.1:17474:7474 \
    -p 127.0.0.1:17687:7687 \
    -e NEO4J_AUTH_FILE=/run/secrets/neo4j_auth_file \
    -e NEO4J_server_memory_heap_initial__size=256m \
    -e NEO4J_server_memory_heap_max__size=512m \
    -e NEO4J_server_memory_pagecache_size=256m \
    --mount type=bind,src="${config_dir}/neo4j_auth.txt",dst=/run/secrets/neo4j_auth_file,readonly \
    -v talk_think_memory_lab_neo4j_data:/data \
    -v talk_think_memory_lab_neo4j_logs:/logs \
    "${image}"
fi
docker start "${container}" >/dev/null

install -m 0644 \
  "${remote_root}/source/deploy/systemd/talk-think-memory-lab.service" \
  /etc/systemd/system/talk-think-memory-lab.service
install -m 0644 \
  "${remote_root}/source/deploy/systemd/talk-think-memory-reme.service" \
  /etc/systemd/system/talk-think-memory-reme.service
systemctl daemon-reload
systemctl enable talk-think-memory-reme.service talk-think-memory-lab.service >/dev/null
systemctl restart talk-think-memory-reme.service
systemctl restart talk-think-memory-lab.service

for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:18280/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:18280/health >/dev/null

set -a
. "${config_dir}/lab.env"
set +a
for _ in $(seq 1 90); do
  if "${remote_root}/venv/bin/python" - <<'PY' >/dev/null 2>&1
import os
from neo4j import GraphDatabase
with GraphDatabase.driver(os.environ["NEO4J_URI"], auth=(os.environ["NEO4J_USER"], os.environ["NEO4J_PASSWORD"])) as driver:
    driver.verify_connectivity()
PY
  then
    break
  fi
  sleep 1
done
"${remote_root}/venv/bin/python" - <<'PY'
import os
from pathlib import Path
from neo4j import GraphDatabase

statements = [part.strip() for part in Path('/opt/talk-think-memory-lab/source/deploy/neo4j/schema.cypher').read_text().split(';') if part.strip()]
with GraphDatabase.driver(os.environ['NEO4J_URI'], auth=(os.environ['NEO4J_USER'], os.environ['NEO4J_PASSWORD'])) as driver:
    driver.verify_connectivity()
    with driver.session(database='neo4j') as session:
        for statement in statements:
            session.run(statement).consume()
PY
unset NEO4J_PASSWORD
REMOTE

echo "Talk Think Memory Lab deployed on ${host_alias}."
