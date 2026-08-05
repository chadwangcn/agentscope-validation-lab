#!/usr/bin/env bash
set -Eeuo pipefail

host_alias="${LAB_HOST_ALIAS:-k1-openclaw}"
keychain_service="${VOLCENGINE_SPEECH_KEYCHAIN_SERVICE:-volcengine.speech}"
public_base="${LAB_PUBLIC_BASE:-http://14.103.221.4/lab}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="${script_dir}/internal/install-volcengine-speech-env.py"
temporary_dir="$(mktemp -d /tmp/agentscope-speech-validation.XXXXXX)"
remote_installer="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'mktemp /tmp/install-volcengine-speech-env.XXXXXX.py')"

cleanup() {
  unset speech_app_id speech_api_key validation_timestamp
  find "${temporary_dir}" -maxdepth 1 -type f -delete >/dev/null 2>&1 || true
  rmdir "${temporary_dir}" >/dev/null 2>&1 || true
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
    "find '${remote_installer}' -maxdepth 0 -type f -delete" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for account in appid api_key; do
  if ! security find-generic-password \
    -s "${keychain_service}" -a "${account}" >/dev/null 2>&1; then
    echo "Missing Keychain item: service=${keychain_service}, account=${account}" >&2
    exit 1
  fi
done
command -v say >/dev/null
command -v ffmpeg >/dev/null

speech_app_id="$(security find-generic-password -s "${keychain_service}" -a appid -w)"
speech_api_key="$(security find-generic-password -s "${keychain_service}" -a api_key -w)"
validation_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

say -v Tingting -o "${temporary_dir}/source.aiff" "你好，智能助手。"
ffmpeg -hide_banner -loglevel error -y \
  -i "${temporary_dir}/source.aiff" -ar 16000 -ac 1 -c:a pcm_s16le \
  "${temporary_dir}/source.wav"

SPEECH_APP_ID_VALUE="${speech_app_id}" \
SPEECH_API_KEY_VALUE="${speech_api_key}" \
TEST_AUDIO_PATH="${temporary_dir}/source.wav" \
python3 - <<'PY'
import base64
import json
import os
from pathlib import Path
import urllib.error
import urllib.request
import uuid

audio = Path(os.environ["TEST_AUDIO_PATH"]).read_bytes()
headers = {
    "X-Api-Key": os.environ["SPEECH_API_KEY_VALUE"],
    "X-Api-Resource-Id": "volc.bigasr.auc_turbo",
    "X-Api-Request-Id": str(uuid.uuid4()),
    "X-Api-Sequence": "-1",
    "Content-Type": "application/json",
}
payload = {
    "user": {"uid": os.environ["SPEECH_APP_ID_VALUE"]},
    "audio": {"data": base64.b64encode(audio).decode("ascii")},
    "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True},
}
request = urllib.request.Request(
    "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash",
    data=json.dumps(payload).encode(),
    method="POST",
    headers=headers,
)
report = {"audio_wav_valid": audio.startswith(b"RIFF") and audio[8:12] == b"WAVE"}
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        body = json.load(response)
        report["http_status"] = response.status
        report["provider_status_code"] = response.headers.get("X-Api-Status-Code")
except urllib.error.HTTPError as error:
    report["http_status"] = error.code
    report["provider_status_code"] = error.headers.get("X-Api-Status-Code")
    print(json.dumps(report, sort_keys=True))
    raise SystemExit(2)
transcript = str((body.get("result") or {}).get("text") or "")
report.update(
    {
        "provider_call_ok": report["http_status"] == 200
        and report["provider_status_code"] == "20000000",
        "transcript_nonempty": bool(transcript.strip()),
        "semantic_contains_hello": "你好" in transcript,
        "semantic_contains_assistant": "助手" in transcript,
        "duration_present": bool((body.get("audio_info") or {}).get("duration")),
    },
)
print(json.dumps(report, ensure_ascii=False, sort_keys=True))
if not all(
    report[key]
    for key in (
        "provider_call_ok",
        "transcript_nonempty",
        "semantic_contains_hello",
        "semantic_contains_assistant",
        "duration_present",
    )
):
    raise SystemExit(3)
PY

scp -q "${installer}" "${host_alias}:${remote_installer}"
SPEECH_APP_ID_VALUE="${speech_app_id}" \
SPEECH_API_KEY_VALUE="${speech_api_key}" \
VALIDATED_AT_VALUE="${validation_timestamp}" \
python3 - <<'PY' | ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  "python3 '${remote_installer}'"
import json
import os

print(
    json.dumps(
        {
            "app_id": os.environ["SPEECH_APP_ID_VALUE"],
            "api_key": os.environ["SPEECH_API_KEY_VALUE"],
            "validated_at": os.environ["VALIDATED_AT_VALUE"],
        },
    ),
)
PY

ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
  'systemctl restart talk-think-memory-lab.service'

for _ in $(seq 1 30); do
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "${host_alias}" \
    "curl -fsS http://127.0.0.1:18280/api/v1/capabilities" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

TEST_AUDIO_PATH="${temporary_dir}/source.wav" PUBLIC_LAB_BASE="${public_base}" python3 - <<'PY'
import json
import os
from pathlib import Path
import urllib.request

audio = Path(os.environ["TEST_AUDIO_PATH"]).read_bytes()
request = urllib.request.Request(
    os.environ["PUBLIC_LAB_BASE"].rstrip("/")
    + "/api/v1/spaces/synthetic_asr_validation/speech/asr",
    data=audio,
    method="POST",
    headers={"Content-Type": "audio/wav"},
)
with urllib.request.urlopen(request, timeout=75) as response:
    body = json.load(response)
transcript = str(body.get("transcript") or "")
report = {
    "public_lab_http": response.status,
    "capability": body.get("capability"),
    "provider": body.get("provider"),
    "transcript_nonempty": bool(transcript.strip()),
    "semantic_contains_hello": "你好" in transcript,
    "semantic_contains_assistant": "助手" in transcript,
    "duration_present": isinstance(body.get("duration_ms"), int),
}
print(json.dumps(report, ensure_ascii=False, sort_keys=True))
if not (
    report["public_lab_http"] == 200
    and report["capability"] == "asr"
    and report["provider"] == "volcengine_speech"
    and report["transcript_nonempty"]
    and report["semantic_contains_hello"]
    and report["semantic_contains_assistant"]
    and report["duration_present"]
):
    raise SystemExit(4)
PY
