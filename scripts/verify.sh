#!/usr/bin/env bash
set -euo pipefail

host_alias="${AGENTSCOPE_HOST_ALIAS:-k1-openclaw}"

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" 'bash -s' <<'REMOTE'
set -euo pipefail

remote_root="/opt/agentscope-2.0.6dev"
source_dir="${remote_root}/source"
venv_python="${remote_root}/venv/bin/python"

backend_state="$(systemctl is-active agentscope-test-backend.service)"
frontend_state="$(systemctl is-active agentscope-test-frontend.service)"
backend_bind_host="$(systemctl show -p Environment --value agentscope-test-backend.service \
  | tr ' ' '\n' | sed -n 's/^BIND_HOST=//p' | tail -n1)"
frontend_bind_host="$(systemctl show -p Environment --value agentscope-test-frontend.service \
  | tr ' ' '\n' | sed -n 's/^BIND_HOST=//p' | tail -n1)"
redis_ping="$(docker exec agentscope-206dev-redis redis-cli ping)"
source_commit="$(git -C "${source_dir}" rev-parse HEAD)"
source_origin="$(git -C "${source_dir}" remote get-url origin)"
overlay_files="$(git -C "${source_dir}" diff --name-only | sort | paste -sd, -)"
package_version="$(${venv_python} -c 'import agentscope; print(agentscope.__version__)')"
python_version="$(${venv_python} -c 'import platform; print(platform.python_version())')"
redis_digest="$(docker inspect --format '{{ index .RepoDigests 0 }}' redis:7.4-alpine 2>/dev/null || true)"

backend_status="$(curl -sS -o /tmp/agentscope-openapi.json -w '%{http_code}' http://127.0.0.1:18080/openapi.json)"
frontend_status="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:15173/agentscope/)"

route_report="$(${venv_python} - <<'PY'
import json

with open('/tmp/agentscope-openapi.json', encoding='utf-8') as handle:
    schema = json.load(handle)

paths = set(schema.get('paths', {}))
groups = {
    'agents': any(path.startswith('/agent/') for path in paths),
    'sessions': any('/sessions' in path for path in paths),
    'credentials': any(path.startswith('/credential/') for path in paths),
    'models': any(path.startswith('/model/') for path in paths),
    'schedules': any(path.startswith('/schedule/') for path in paths),
    'workspaces': any('/workspace' in path for path in paths),
    'knowledge_bases': any('/knowledge' in path for path in paths),
    'hubs': any('/hub' in path for path in paths),
}
print(json.dumps(groups, sort_keys=True))
if not all(groups.values()):
    raise SystemExit(1)
PY
)"

sdk_report="$(${venv_python} - <<'PY'
import json
from agentscope.agent import Agent
from agentscope.message import UserMsg
from agentscope.permission import PermissionContext, PermissionMode
from agentscope.tool import Toolkit, Bash, Read, Write, Edit
from agentscope.workspace import LocalWorkspace

message = UserMsg(name='verifier', content='installation smoke')
toolkit = Toolkit(tools=[Bash(), Read(), Write(), Edit()])
report = {
    'agent': Agent.__name__,
    'message_role': message.role,
    'permission_mode': PermissionContext(mode=PermissionMode.EXPLORE).mode.value,
    'toolkit': type(toolkit).__name__,
    'workspace': LocalWorkspace.__name__,
}
print(json.dumps(report, sort_keys=True))
PY
)"

printf '{\n'
printf '  "backend_state": "%s",\n' "${backend_state}"
printf '  "backend_http": %s,\n' "${backend_status}"
printf '  "frontend_state": "%s",\n' "${frontend_state}"
printf '  "frontend_http": %s,\n' "${frontend_status}"
printf '  "backend_bind_host": "%s",\n' "${backend_bind_host}"
printf '  "frontend_bind_host": "%s",\n' "${frontend_bind_host}"
printf '  "redis_ping": "%s",\n' "${redis_ping}"
printf '  "redis_image_digest": "%s",\n' "${redis_digest}"
printf '  "source_origin": "%s",\n' "${source_origin}"
printf '  "source_commit": "%s",\n' "${source_commit}"
printf '  "web_ui_overlay_files": "%s",\n' "${overlay_files}"
printf '  "docs_channel": "2.0.6dev",\n'
printf '  "package_version": "%s",\n' "${package_version}"
printf '  "python_version": "%s",\n' "${python_version}"
printf '  "routes": %s,\n' "${route_report}"
printf '  "sdk": %s\n' "${sdk_report}"
printf '}\n'

test "${backend_state}" = active
test "${frontend_state}" = active
test "${redis_ping}" = PONG
test "${source_origin}" = https://github.com/agentscope-ai/agentscope.git
test "${source_commit}" = 9edf84602c3af9399808afa448cd222f8fe1f7f9
test "${overlay_files}" = examples/agent_service/main.py,examples/web_ui/frontend/src/App.tsx,examples/web_ui/frontend/src/api/client.ts,examples/web_ui/frontend/src/api/knowledgeBase.ts,examples/web_ui/frontend/src/api/model.ts,examples/web_ui/frontend/src/api/workspace.ts,examples/web_ui/frontend/src/components/chat/TextInput.tsx,examples/web_ui/frontend/src/hooks/useAvailableModels.ts,examples/web_ui/frontend/src/hooks/useAvailableTTSModels.ts,examples/web_ui/frontend/src/hooks/useMessages.ts,examples/web_ui/frontend/src/pages/chat/ChatViewport.tsx,examples/web_ui/frontend/src/pages/credential/index.tsx,examples/web_ui/frontend/src/utils/common.ts,examples/web_ui/frontend/vite.config.ts,src/agentscope/app/_router/_credential.py,src/agentscope/app/_router/_embedding_model.py,src/agentscope/app/_router/_knowledge_base.py,src/agentscope/app/_router/_model.py,src/agentscope/app/_router/_schema/_embedding_model.py,src/agentscope/app/_router/_schema/_model.py,src/agentscope/app/_router/_schema/_tts_model.py,src/agentscope/app/_router/_session.py,src/agentscope/app/_router/_tts_model.py,src/agentscope/app/_service/_access.py,src/agentscope/app/_service/_knowledge_base.py
git -C "${source_dir}" diff --check
grep -Fq 'AGENTSCOPE_REDIS_HOST' "${source_dir}/examples/agent_service/main.py"
grep -Fq 'AGENTSCOPE_WORKSPACE_DIR' "${source_dir}/examples/agent_service/main.py"
grep -Fq "base: '/agentscope/'" "${source_dir}/examples/web_ui/frontend/vite.config.ts"
grep -Fq 'createHashRouter' "${source_dir}/examples/web_ui/frontend/src/App.tsx"
grep -Fq 'buildApiUrl(path)' "${source_dir}/examples/web_ui/frontend/src/api/client.ts"
grep -Fq 'id: createClientId()' "${source_dir}/examples/web_ui/frontend/src/components/chat/TextInput.tsx"
grep -Fq 'getRandomValues(bytes)' "${source_dir}/examples/web_ui/frontend/src/utils/common.ts"
! grep -Fq 'crypto.randomUUID()' "${source_dir}/examples/web_ui/frontend/src/components/chat/TextInput.tsx"
grep -Fq 'Credential ``data`` is always masked' "${source_dir}/src/agentscope/app/_service/_access.py"
grep -Fq 'Volcengine Ark (Keychain)' "${source_dir}/src/agentscope/app/_router/_model.py"
grep -Fq '.list(type, credential.id)' "${source_dir}/examples/web_ui/frontend/src/pages/credential/index.tsx"
grep -Fq 'environment validation gate' "${source_dir}/src/agentscope/app/_router/_session.py"
grep -Fq 'no validated embedding model' "${source_dir}/src/agentscope/app/_service/_knowledge_base.py"
test "${backend_status}" = 200
test "${frontend_status}" = 200
ss -ltnH | awk '{print $4}' | grep -Fxq "${backend_bind_host}:18080"
ss -ltnH | awk '{print $4}' | grep -Fxq "${frontend_bind_host}:15173"
REMOTE
