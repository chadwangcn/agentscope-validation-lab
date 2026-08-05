from __future__ import annotations

import asyncio
import json
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml


BASE_URL = "http://127.0.0.1:18080"
CREDENTIAL_NAME = "Volcengine Ark"
SMOKE_AGENT_NAME = "Volcengine Ark Smoke Agent"
SMOKE_SESSION_NAME = "Volcengine Ark Smoke"
MODEL_CARD = Path(
    "/opt/agentscope-2.0.6dev/source/"
    "src/agentscope/model/_openai_chat/_models/volcengine-ark-keychain.yaml",
)


def request(user_id: str, path: str, method: str = "GET", body: dict | None = None) -> dict:
    encoded = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        BASE_URL + path,
        data=encoded,
        method=method,
        headers={"Content-Type": "application/json", "X-User-ID": user_id},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"AgentScope API {method} {path} returned HTTP {error.code}") from error


async def verify_agentscope_adapter(api_key: str, base_url: str, model: str) -> tuple[bool, bool]:
    """Exercise AgentScope's OpenAI-compatible model adapter without tools."""
    from agentscope.credential import OpenAICredential
    from agentscope.message import UserMsg
    from agentscope.model import OpenAIChatModel

    chat_model = OpenAIChatModel(
        credential=OpenAICredential(
            api_key=api_key,
            base_url=base_url.rstrip("/"),
        ),
        model=model,
        stream=False,
        max_retries=1,
        retry_delay=0.5,
        context_size=32768,
        client_kwargs={"timeout": 45.0},
    )
    try:
        response = await asyncio.wait_for(
            chat_model([UserMsg("validation-user", "Return only OK.")]),
            timeout=50,
        )
    finally:
        await chat_model.client.close()

    has_text = any(
        getattr(block, "type", None) == "text"
        and bool(getattr(block, "text", "").strip())
        for block in response.content
    )
    has_usage = response.usage is not None
    if not has_text:
        raise SystemExit("AgentScope Ark adapter returned no text")
    if not has_usage:
        raise SystemExit("AgentScope Ark adapter returned no usage")
    return has_text, has_usage


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: configure-volcengine-ark.py USER_ID")
    user_id = sys.argv[1]
    if not re.fullmatch(r"[A-Za-z0-9._-]{3,64}", user_id):
        raise SystemExit("invalid AgentScope user ID")

    incoming = json.load(sys.stdin)
    api_key = incoming.get("api_key")
    base_url = incoming.get("base_url")
    model = incoming.get("model")
    if not isinstance(api_key, str) or len(api_key) < 16 or "\n" in api_key:
        raise SystemExit("invalid Ark API key")
    if not isinstance(base_url, str) or not base_url.startswith("https://"):
        raise SystemExit("invalid Ark base URL")
    if not isinstance(model, str) or not re.fullmatch(r"[A-Za-z0-9._:/-]{2,200}", model):
        raise SystemExit("invalid Ark endpoint model")

    credential_data = {
        "type": "openai_credential",
        "name": CREDENTIAL_NAME,
        "api_key": api_key,
        "base_url": base_url.rstrip("/"),
    }
    listed = request(user_id, "/credential/")
    matches = [
        item
        for item in listed.get("credentials", [])
        if item.get("data", {}).get("type") == "openai_credential"
        and item.get("data", {}).get("name") == CREDENTIAL_NAME
    ]
    if len(matches) > 1:
        raise SystemExit("multiple Volcengine Ark credentials exist for this user")
    if matches:
        credential_id = matches[0]["id"]
        updated_view = request(
            user_id,
            f"/credential/{urllib.parse.quote(credential_id, safe='')}",
            "PATCH",
            {"data": credential_data},
        )
        if set(updated_view.get("data", {})) - {"type", "name"}:
            raise SystemExit("AgentScope credential update response exposed secret fields")
        action = "updated"
    else:
        created = request(user_id, "/credential/", "POST", {"data": credential_data})
        credential_id = created["credential_id"]
        action = "created"

    model_card = {
        "name": model,
        "label": "Volcengine Ark (Keychain)",
        "status": "active",
        "input_types": ["text/plain"],
        "output_types": ["text/plain"],
        "context_size": 32768,
        "output_size": 4096,
        "parameter_overrides": {
            "max_tokens": {"maximum": 4096},
            "thinking_enable": {"hidden": True},
            "reasoning_effort": {"hidden": True},
            "voice": {"hidden": True},
        },
    }
    MODEL_CARD.write_text(yaml.safe_dump(model_card, sort_keys=False), encoding="utf-8")

    credential_query = urllib.parse.urlencode(
        {
            "provider": "openai_credential",
            "credential_id": credential_id,
        },
    )
    models = request(user_id, f"/model/?{credential_query}")
    tts_models = request(user_id, f"/tts-model/?{credential_query}")
    embedding_models = request(user_id, f"/embedding-model/?{credential_query}")
    visible_chat_models = models.get("models", [])
    registered = (
        models.get("total") == 1
        and len(visible_chat_models) == 1
        and visible_chat_models[0].get("name") == model
        and visible_chat_models[0].get("label") == "Volcengine Ark (Keychain)"
    )
    tts_catalog_empty = tts_models.get("total") == 0 and not tts_models.get("models")
    embedding_catalog_empty = (
        embedding_models.get("total") == 0
        and not embedding_models.get("models")
    )
    confirmed = request(user_id, "/credential/")
    confirmed_entries = [
        item
        for item in confirmed.get("credentials", [])
        if item.get("data", {}).get("type") == "openai_credential"
        and item.get("data", {}).get("name") == CREDENTIAL_NAME
    ]
    confirmed_ids = {item.get("id") for item in confirmed_entries}
    credential_response_redacted = all(
        not (set(item.get("data", {})) - {"type", "name"})
        for item in confirmed_entries
    )
    if (
        credential_id not in confirmed_ids
        or not registered
        or not tts_catalog_empty
        or not embedding_catalog_empty
    ):
        raise SystemExit("AgentScope credential or model-card verification failed")
    if not credential_response_redacted:
        raise SystemExit("AgentScope credential list response exposed secret fields")

    adapter_reply_received, adapter_usage_recorded = asyncio.run(
        verify_agentscope_adapter(api_key, base_url, model),
    )

    agents = request(user_id, "/agent/").get("agents", [])
    smoke_agents = [
        item for item in agents if item.get("data", {}).get("name") == SMOKE_AGENT_NAME
    ]
    if len(smoke_agents) > 1:
        raise SystemExit("multiple Volcengine Ark smoke agents exist for this user")
    if smoke_agents:
        agent_id = smoke_agents[0]["id"]
    else:
        agent_id = request(
            user_id,
            "/agent/",
            "POST",
            {
                "name": SMOKE_AGENT_NAME,
                "system_prompt": (
                    "You are a concise model validation assistant. "
                    "Answer directly and never call tools."
                ),
            },
        )["agent_id"]

    model_config = {
        "type": "openai_credential",
        "credential_id": credential_id,
        "model": model,
        "parameters": {"max_tokens": 128},
    }
    sessions_path = f"/sessions/?agent_id={urllib.parse.quote(agent_id, safe='')}"
    sessions = request(user_id, sessions_path).get("sessions", [])
    smoke_sessions = [
        item
        for item in sessions
        if item.get("session", {}).get("config", {}).get("name") == SMOKE_SESSION_NAME
    ]
    if len(smoke_sessions) > 1:
        raise SystemExit("multiple Volcengine Ark smoke sessions exist for this user")
    if smoke_sessions:
        session_id = smoke_sessions[0]["session"]["id"]
        request(
            user_id,
            (
                f"/sessions/{urllib.parse.quote(session_id, safe='')}"
                f"?agent_id={urllib.parse.quote(agent_id, safe='')}"
            ),
            "PATCH",
            {"chat_model_config": model_config},
        )
    else:
        session_id = request(
            user_id,
            "/sessions/",
            "POST",
            {
                "agent_id": agent_id,
                "name": SMOKE_SESSION_NAME,
                "chat_model_config": model_config,
            },
        )["session_id"]

    configured_sessions = request(user_id, sessions_path).get("sessions", [])
    agent_session_ready = any(
        item.get("session", {}).get("id") == session_id
        and item.get("session", {}).get("config", {}).get("chat_model_config", {}).get(
            "credential_id",
        )
        == credential_id
        for item in configured_sessions
    )
    if not agent_session_ready:
        raise SystemExit("AgentScope Ark smoke session verification failed")

    messages_path = (
        f"/sessions/{urllib.parse.quote(session_id, safe='')}/messages"
        f"?agent_id={urllib.parse.quote(agent_id, safe='')}&limit=100"
    )
    existing_message_ids = {
        item.get("id")
        for item in request(user_id, messages_path).get("messages", [])
    }
    started = request(
        user_id,
        "/chat/",
        "POST",
        {
            "agent_id": agent_id,
            "session_id": session_id,
            "input": {
                "name": "user",
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "Reply only with the two letters OK.",
                    },
                ],
            },
        },
    )
    if started.get("status") != "started":
        raise SystemExit("AgentScope Ark agent chat did not start")

    agent_reply = None
    for _ in range(60):
        candidates = [
            item
            for item in request(user_id, messages_path).get("messages", [])
            if item.get("id") not in existing_message_ids
            and item.get("role") == "assistant"
            and item.get("finished_at")
        ]
        if candidates:
            agent_reply = candidates[-1]
            break
        time.sleep(1)
    if agent_reply is None:
        raise SystemExit("AgentScope Ark agent reply timed out")

    agent_reply_text = "".join(
        block.get("text", "")
        for block in agent_reply.get("content", [])
        if isinstance(block, dict) and block.get("type") == "text"
    ).strip()
    agent_semantic_ok = agent_reply_text.rstrip(".").strip().upper() == "OK"
    agent_usage_recorded = isinstance(agent_reply.get("usage"), dict)
    agent_finished_reason = agent_reply.get("finished_reason")
    if (
        agent_finished_reason != "completed"
        or not agent_semantic_ok
        or not agent_usage_recorded
        or agent_reply.get("error")
    ):
        raise SystemExit("AgentScope Ark agent semantic smoke failed")

    print(
        json.dumps(
            {
                "action": action,
                "credential_id": credential_id,
                "credential_name": CREDENTIAL_NAME,
                "credential_type": "openai_credential",
                "credential_response_redacted": credential_response_redacted,
                "agent_id": agent_id,
                "session_id": session_id,
                "model_registered": registered,
                "chat_catalog_verified": registered,
                "tts_catalog_empty": tts_catalog_empty,
                "embedding_catalog_empty": embedding_catalog_empty,
                "adapter_reply_received": adapter_reply_received,
                "adapter_usage_recorded": adapter_usage_recorded,
                "agent_session_ready": agent_session_ready,
                "agent_reply_received": True,
                "agent_semantic_ok": agent_semantic_ok,
                "agent_usage_recorded": agent_usage_recorded,
                "agent_finished_reason": agent_finished_reason,
                "user_id": user_id,
            },
            sort_keys=True,
        ),
    )


if __name__ == "__main__":
    main()
