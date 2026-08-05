from __future__ import annotations

import base64
from dataclasses import dataclass
import uuid

import httpx


ASR_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
ASR_RESOURCE_ID = "volc.bigasr.auc_turbo"
MAX_AUDIO_BYTES = 20 * 1024 * 1024


class SpeechInputError(ValueError):
    """The uploaded bytes are outside the validated ASR contract."""


class SpeechProviderError(RuntimeError):
    """The provider did not return a validated transcription response."""


@dataclass(frozen=True)
class ASRResult:
    transcript: str
    duration_ms: int | None
    request_id: str


def validate_audio(audio: bytes) -> str:
    if not audio:
        raise SpeechInputError("audio body is empty")
    if len(audio) > MAX_AUDIO_BYTES:
        raise SpeechInputError("audio exceeds the 20 MiB validation limit")
    if len(audio) >= 12 and audio.startswith(b"RIFF") and audio[8:12] == b"WAVE":
        return "wav"
    if audio.startswith(b"OggS"):
        return "ogg_opus"
    if audio.startswith(b"ID3") or (
        len(audio) >= 2
        and audio[0] == 0xFF
        and audio[1] & 0xE0 == 0xE0
    ):
        return "mp3"
    raise SpeechInputError("only WAV, MP3, and OGG Opus audio are accepted")


async def transcribe_volcengine(
    audio: bytes,
    *,
    app_id: str,
    api_key: str,
) -> ASRResult:
    validate_audio(audio)
    request_id = str(uuid.uuid4())
    headers = {
        "X-Api-Key": api_key,
        "X-Api-Resource-Id": ASR_RESOURCE_ID,
        "X-Api-Request-Id": request_id,
        "X-Api-Sequence": "-1",
    }
    payload = {
        "user": {"uid": app_id},
        "audio": {"data": base64.b64encode(audio).decode("ascii")},
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,
            "enable_punc": True,
        },
    }
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(ASR_URL, headers=headers, json=payload)
    except httpx.HTTPError as exc:
        raise SpeechProviderError(type(exc).__name__) from exc

    provider_status = response.headers.get("X-Api-Status-Code")
    if response.status_code != 200 or provider_status != "20000000":
        raise SpeechProviderError(
            f"provider rejected request with HTTP {response.status_code}"
        )
    try:
        body = response.json()
        transcript = body["result"]["text"].strip()
        raw_duration = body.get("audio_info", {}).get("duration")
        duration_ms = int(raw_duration) if raw_duration is not None else None
    except (KeyError, TypeError, ValueError) as exc:
        raise SpeechProviderError("provider response schema validation failed") from exc
    if not transcript:
        raise SpeechProviderError("provider returned an empty transcript")
    return ASRResult(
        transcript=transcript,
        duration_ms=duration_ms,
        request_id=request_id,
    )
