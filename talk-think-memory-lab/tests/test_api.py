from __future__ import annotations

from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.speech import ASRResult, SpeechInputError, validate_audio


def make_client(tmp_path, frontend_dist=None, speech=False):
    settings = Settings(
        data_dir=tmp_path,
        sqlite_path=tmp_path / "lab.sqlite3",
        trace_dir=tmp_path / "traces",
        reme_base_url="http://127.0.0.1:1",
        neo4j_uri="bolt://127.0.0.1:1",
        neo4j_user="neo4j",
        neo4j_password=None,
        frontend_dist=frontend_dist,
        volcengine_speech_app_id="test-app" if speech else None,
        volcengine_speech_api_key="test-key" if speech else None,
        asr_validated_at="2026-08-05T00:00:00Z" if speech else None,
    )
    return TestClient(create_app(settings))


def test_health_and_memory_lifecycle(tmp_path):
    with make_client(tmp_path) as client:
        assert client.get("/health").json()["status"] == "ok"
        created = client.post(
            "/api/v1/spaces/child_alpha/memories",
            json={"title": "Zoo visit", "content": "A synthetic child saw a giraffe."},
        )
        assert created.status_code == 201
        memory = created.json()
        assert memory["status"] == "draft"
        assert memory["version"] == 1

        review = client.post(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}/transitions",
            json={"target_status": "review", "expected_version": 1},
        )
        assert review.json()["version"] == 2
        published = client.post(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}/transitions",
            json={"target_status": "published", "expected_version": 2},
        )
        assert published.json()["status"] == "published"

        direct_trash = client.delete(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}?expected_version=3",
        )
        assert direct_trash.status_code == 409

        withdrawn = client.post(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}/transitions",
            json={"target_status": "withdrawn", "expected_version": 3},
        )
        trashed = client.delete(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}?expected_version={withdrawn.json()['version']}",
        )
        assert trashed.json()["status"] == "trashed"
        assert client.get("/api/v1/spaces/child_alpha/memories").json()["total"] == 0

        mismatch = client.post(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}/purge",
            json={
                "expected_version": trashed.json()["version"],
                "confirm_memory_id": "wrong-id",
                "confirm_irreversible": True,
                "reason": "synthetic test cleanup",
            },
        )
        assert mismatch.status_code == 409

        bypass = client.post(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}/transitions",
            json={"target_status": "purged", "expected_version": trashed.json()["version"]},
        )
        assert bypass.status_code == 409

        restored = client.post(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}/transitions",
            json={"target_status": "withdrawn", "expected_version": trashed.json()["version"]},
        )
        retrash = client.delete(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}?expected_version={restored.json()['version']}",
        ).json()
        purged = client.post(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}/purge",
            json={
                "expected_version": retrash["version"],
                "confirm_memory_id": memory["id"],
                "confirm_irreversible": True,
                "reason": "synthetic test cleanup",
            },
        )
        assert purged.status_code == 200
        assert purged.json()["status"] == "purged"
        assert purged.json()["complete"] is False
        tombstone = client.get(
            f"/api/v1/spaces/child_alpha/memories/{memory['id']}",
        ).json()
        assert tombstone["content"] == "[purged]"


def test_memory_space_is_mandatory_and_isolated(tmp_path):
    with make_client(tmp_path) as client:
        created = client.post(
            "/api/v1/spaces/child_alpha/memories",
            json={"title": "Favorite", "content": "Likes blue today."},
        ).json()
        assert client.get("/api/v1/spaces/child_beta/memories").json()["total"] == 0
        assert (
            client.get(f"/api/v1/spaces/child_beta/memories/{created['id']}").status_code
            == 404
        )
        assert client.get("/api/v1/spaces/XX/memories").status_code == 422
        assert client.get("/api/v1/memories").status_code == 404


def test_version_conflict_and_websocket_event(tmp_path):
    with make_client(tmp_path) as client:
        with client.websocket_connect("/ws/v1/spaces/child_alpha/events") as websocket:
            assert websocket.receive_json()["event_type"] == "stream.connected"
            created = client.post(
                "/api/v1/spaces/child_alpha/memories",
                json={"title": "Synthetic", "content": "No personal data."},
            ).json()
            event = websocket.receive_json()
            assert event["event_type"] == "memory.created"
            assert event["payload"]["memory_id"] == created["id"]

        conflict = client.patch(
            f"/api/v1/spaces/child_alpha/memories/{created['id']}",
            json={"title": "Stale", "expected_version": 99},
        )
        assert conflict.status_code == 409
        assert conflict.json()["error"]["code"] == "version_conflict"

    trace = (tmp_path / "traces" / "child_alpha.jsonl").read_text(encoding="utf-8")
    assert '"memory_space": "child_alpha"' in trace
    assert '"event_type": "memory.created"' in trace


def test_same_origin_frontend_does_not_shadow_api_status(tmp_path):
    frontend_dist = tmp_path / "dist"
    (frontend_dist / "assets").mkdir(parents=True)
    (frontend_dist / "index.html").write_text("<html>memory lab</html>", encoding="utf-8")
    with make_client(tmp_path, frontend_dist=frontend_dist) as client:
        chat = client.get("/chat")
        assert chat.status_code == 200
        assert "memory lab" in chat.text
        api_status = client.get("/status")
        assert api_status.status_code == 200
        assert api_status.headers["content-type"].startswith("application/json")


def test_capability_catalog_hides_unvalidated_models(tmp_path):
    with make_client(tmp_path) as client:
        capabilities = client.get("/api/v1/capabilities").json()
        assert capabilities["chat"]["status"] == "not_configured"
        assert capabilities["asr"]["status"] == "not_configured"
        assert capabilities["tts"]["status"] == "not_configured"
        assert capabilities["embedding"]["status"] == "not_configured"
        response = client.post(
            "/api/v1/spaces/child_alpha/speech/asr",
            content=b"RIFF" + b"\x00" * 4 + b"WAVE" + b"\x00" * 64,
            headers={"Content-Type": "audio/wav"},
        )
        assert response.status_code == 503


def test_validated_asr_route_returns_transcript_without_persisting_it(tmp_path):
    audio = b"RIFF" + b"\x00" * 4 + b"WAVE" + b"\x00" * 64
    result = ASRResult(
        transcript="你好，智能助手。",
        duration_ms=1800,
        request_id="synthetic-request-id",
    )
    with patch("app.main.transcribe_volcengine", new=AsyncMock(return_value=result)):
        with make_client(tmp_path, speech=True) as client:
            capabilities = client.get("/api/v1/capabilities").json()
            assert capabilities["asr"]["status"] == "validated"
            response = client.post(
                "/api/v1/spaces/child_alpha/speech/asr",
                content=audio,
                headers={"Content-Type": "audio/wav"},
            )
            assert response.status_code == 200
            assert response.json()["transcript"] == "你好，智能助手。"
            assert response.json()["duration_ms"] == 1800

    trace = (tmp_path / "traces" / "child_alpha.jsonl").read_text(encoding="utf-8")
    assert '"event_type": "speech.asr.completed"' in trace
    assert "你好，智能助手。" not in trace


def test_audio_validation_contract():
    assert validate_audio(b"RIFF" + b"\x00" * 4 + b"WAVE") == "wav"
    assert validate_audio(b"ID3" + b"\x00" * 32) == "mp3"
    assert validate_audio(b"OggS" + b"\x00" * 32) == "ogg_opus"
    try:
        validate_audio(b"not audio")
    except SpeechInputError:
        pass
    else:
        raise AssertionError("invalid audio must be rejected")
