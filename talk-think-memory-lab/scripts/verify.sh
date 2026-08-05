#!/usr/bin/env bash
set -euo pipefail

host_alias="${LAB_HOST_ALIAS:-k1-openclaw}"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" 'bash -s' <<'REMOTE'
set -euo pipefail

remote_root="/opt/talk-think-memory-lab"
config_dir="/etc/talk-think-memory-lab"
venv_python="${remote_root}/venv/bin/python"

api_state="$(systemctl is-active talk-think-memory-lab.service)"
reme_state="$(systemctl is-active talk-think-memory-reme.service)"
neo4j_state="$(docker inspect --format '{{.State.Status}}' talk-think-memory-lab-neo4j)"
lab_bind_host="$(systemctl show -p Environment --value talk-think-memory-lab.service \
  | tr ' ' '\n' | sed -n 's/^BIND_HOST=//p' | tail -n1)"
health="$(curl -fsS http://127.0.0.1:18280/health)"
status="$(curl -fsS http://127.0.0.1:18280/status)"
capabilities="$(curl -fsS http://127.0.0.1:18280/api/v1/capabilities)"
reme_version="$(${venv_python} -c 'import reme; print(reme.__version__)')"
reme_internal_agentscope_version="$(${venv_python} -c 'import agentscope; print(agentscope.__version__)')"
neo4j_driver_version="$(${venv_python} -c 'import importlib.metadata; print(importlib.metadata.version("neo4j"))')"
neo4j_image="$(docker inspect --format '{{.Config.Image}}' talk-think-memory-lab-neo4j)"
neo4j_digests="$(docker image inspect --format '{{json .RepoDigests}}' neo4j:2026.06.0)"
listen_report="$(ss -ltnH | awk '$4 ~ /:(12333|17474|17687|18280)$/ {print $4}' | sort | paste -sd, -)"

set -a
. "${config_dir}/lab.env"
set +a
graph_report="$(${venv_python} - <<'PY'
import json, os
from neo4j import GraphDatabase
with GraphDatabase.driver(os.environ['NEO4J_URI'], auth=(os.environ['NEO4J_USER'], os.environ['NEO4J_PASSWORD'])) as driver:
    driver.verify_connectivity()
    with driver.session(database='neo4j') as session:
        names = sorted(record['name'] for record in session.run('SHOW CONSTRAINTS YIELD name RETURN name'))
print(json.dumps({'reachable': True, 'constraints': names}, sort_keys=True))
PY
)"
unset NEO4J_PASSWORD

api_flow="$(${venv_python} - <<'PY'
import json, uuid, urllib.error, urllib.request
base='http://127.0.0.1:18280'
space='verify_' + uuid.uuid4().hex[:10]
def request(path, method='GET', body=None):
    data=None if body is None else json.dumps(body).encode()
    req=urllib.request.Request(base+path, data=data, method=method, headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req) as r: return r.status, json.load(r)
def error_status(path, method='GET', body=None):
    try:
        request(path, method, body)
    except urllib.error.HTTPError as error:
        return error.code
    raise RuntimeError('expected an HTTP error')
_, created=request(f'/api/v1/spaces/{space}/memories', 'POST', {'title':'Synthetic verification','content':'No personal data.'})
_, review=request(f"/api/v1/spaces/{space}/memories/{created['id']}/transitions", 'POST', {'target_status':'review','expected_version':1})
_, published=request(f"/api/v1/spaces/{space}/memories/{created['id']}/transitions", 'POST', {'target_status':'published','expected_version':review['version']})
published_trash_status=error_status(f"/api/v1/spaces/{space}/memories/{created['id']}?expected_version={published['version']}", 'DELETE')
_, withdrawn=request(f"/api/v1/spaces/{space}/memories/{created['id']}/transitions", 'POST', {'target_status':'withdrawn','expected_version':published['version']})
_, trashed=request(f"/api/v1/spaces/{space}/memories/{created['id']}?expected_version={withdrawn['version']}", 'DELETE')
_, restored=request(f"/api/v1/spaces/{space}/memories/{created['id']}/transitions", 'POST', {'target_status':'withdrawn','expected_version':trashed['version']})
_, retrash=request(f"/api/v1/spaces/{space}/memories/{created['id']}?expected_version={restored['version']}", 'DELETE')
purge_bypass_status=error_status(f"/api/v1/spaces/{space}/memories/{created['id']}/transitions", 'POST', {'target_status':'purged','expected_version':retrash['version']})
_, purge=request(f"/api/v1/spaces/{space}/memories/{created['id']}/purge", 'POST', {
    'expected_version':retrash['version'], 'confirm_memory_id':created['id'],
    'confirm_irreversible':True, 'reason':'synthetic deployment verification',
})
_, tombstone=request(f"/api/v1/spaces/{space}/memories/{created['id']}")
_, isolated=request('/api/v1/spaces/verify_other/memories')
print(json.dumps({
    'created':created['status'], 'published':published['status'],
    'published_trash_http':published_trash_status, 'restored':restored['status'],
    'purge_bypass_http':purge_bypass_status, 'purged':purge['status'],
    'purge_complete':purge['complete'], 'tombstone_content':tombstone['content'],
    'isolated_total':isolated['total'],
}, sort_keys=True))
PY
)"

ui_report="$(${venv_python} - <<'PY'
import json, urllib.request
base='http://127.0.0.1:18280'
report={}
for path in ('/chat','/memories','/evaluations','/ui/status'):
    with urllib.request.urlopen(base+path) as response:
        body=response.read().decode()
        report[path]={'http':response.status,'html':response.headers.get_content_type()=='text/html','root': '<div id="root">' in body}
print(json.dumps(report, sort_keys=True))
PY
)"

capability_report="$(${venv_python} - <<'PY'
import json
from pathlib import Path
import urllib.request

with urllib.request.urlopen('http://127.0.0.1:18280/api/v1/capabilities') as response:
    capabilities = json.load(response)
expected_asr = 'validated' if Path('/etc/talk-think-memory-lab/speech.env').is_file() else 'not_configured'
report = {name: value['status'] for name, value in capabilities.items()}
assert report == {
    'chat': 'not_configured',
    'asr': expected_asr,
    'tts': 'not_configured',
    'embedding': 'not_configured',
}
serialized = json.dumps(capabilities)
assert all(token not in serialized for token in ('app_id', 'api_key', 'model_id'))
print(json.dumps(report, sort_keys=True))
PY
)"

printf '{\n'
printf '  "api_state": "%s",\n' "${api_state}"
printf '  "reme_state": "%s",\n' "${reme_state}"
printf '  "neo4j_state": "%s",\n' "${neo4j_state}"
printf '  "lab_bind_host": "%s",\n' "${lab_bind_host}"
printf '  "health": %s,\n' "${health}"
printf '  "status": %s,\n' "${status}"
printf '  "capabilities": %s,\n' "${capabilities}"
printf '  "reme_version": "%s",\n' "${reme_version}"
printf '  "reme_internal_agentscope_version": "%s",\n' "${reme_internal_agentscope_version}"
printf '  "neo4j_driver_version": "%s",\n' "${neo4j_driver_version}"
printf '  "neo4j_image": "%s",\n' "${neo4j_image}"
printf '  "neo4j_image_digests": %s,\n' "${neo4j_digests}"
printf '  "listen": "%s",\n' "${listen_report}"
printf '  "graph": %s,\n' "${graph_report}"
printf '  "api_flow": %s,\n' "${api_flow}"
printf '  "ui": %s,\n' "${ui_report}"
printf '  "capability_gate": %s\n' "${capability_report}"
printf '}\n'

test "${api_state}" = active
test "${reme_state}" = active
test "${neo4j_state}" = running
ss -ltnH | awk '{print $4}' | grep -Fxq "${lab_bind_host}:18280"
ss -ltnH | awk '{print $4}' | grep -Fxq '127.0.0.1:12333'
ss -ltnH | awk '{print $4}' | grep -Fxq '127.0.0.1:17474'
ss -ltnH | awk '{print $4}' | grep -Fxq '127.0.0.1:17687'
test "${reme_version}" = 0.4.1.3
test "${reme_internal_agentscope_version}" = 2.0.5
test "${neo4j_image}" = neo4j:2026.06.0
printf '%s' "${neo4j_digests}" | grep -q 'neo4j@sha256:efd853c5bb12b5109012527a9003eda89c0d1159b586ccc14616ff86ef085cab'
REMOTE
