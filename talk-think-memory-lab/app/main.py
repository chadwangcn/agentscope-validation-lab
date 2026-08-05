from __future__ import annotations

import asyncio
import importlib.metadata
import platform
import re
from contextlib import asynccontextmanager
from typing import Annotated, Any

import httpx
from fastapi import FastAPI, HTTPException, Path, Query, Request, WebSocket, WebSocketDisconnect, status
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from neo4j import GraphDatabase

from . import __version__
from .config import Settings
from .contracts import (
    CleanupLayer,
    MemoryCreate,
    MemoryList,
    MemoryPurge,
    MemoryPurgeReport,
    MemoryRecord,
    MemoryStatus,
    MemoryTransition,
    MemoryUpdate,
    SpeechTranscription,
)
from .events import EventRecorder
from .repository import ConflictError, InvalidTransitionError, MemoryRepository, NotFoundError
from .speech import MAX_AUDIO_BYTES, SpeechInputError, SpeechProviderError, transcribe_volcengine

MEMORY_SPACE_PATTERN = r"[a-z0-9][a-z0-9_-]{2,63}"
MEMORY_SPACE_RE = re.compile(rf"^{MEMORY_SPACE_PATTERN}$")
MemorySpace = Annotated[str, Path(pattern=rf"^{MEMORY_SPACE_PATTERN}$")]


def _package_version(name: str) -> str | None:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def create_app(settings: Settings | None = None) -> FastAPI:
    resolved = settings or Settings.from_env()
    repository = MemoryRepository(resolved.sqlite_path)
    events = EventRecorder(resolved.trace_dir)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        await asyncio.to_thread(repository.initialize)
        yield

    app = FastAPI(
        title="Talk Think Memory Lab",
        version=__version__,
        description="Isolated experimental backend. memory_space is mandatory on every stateful route.",
        lifespan=lifespan,
    )
    app.state.settings = resolved
    app.state.repository = repository
    app.state.events = events

    @app.exception_handler(NotFoundError)
    async def not_found_handler(_request, exc: NotFoundError):
        return _problem(status.HTTP_404_NOT_FOUND, "memory_not_found", str(exc))

    @app.exception_handler(ConflictError)
    async def conflict_handler(_request, exc: ConflictError):
        return _problem(status.HTTP_409_CONFLICT, "version_conflict", str(exc))

    @app.exception_handler(InvalidTransitionError)
    async def transition_handler(_request, exc: InvalidTransitionError):
        return _problem(status.HTTP_409_CONFLICT, "invalid_lifecycle_transition", str(exc))

    @app.get("/health")
    async def health() -> dict[str, Any]:
        sqlite_ok = await asyncio.to_thread(repository.ping)
        return {"status": "ok" if sqlite_ok else "degraded", "service": "talk-think-memory-lab", "sqlite": sqlite_ok}

    @app.get("/status")
    async def service_status() -> dict[str, Any]:
        reme = await _reme_status(resolved.reme_base_url)
        neo4j = await asyncio.to_thread(_neo4j_status, resolved)
        return {
            "status": "ok" if reme["reachable"] and neo4j["reachable"] else "degraded",
            "service_version": __version__,
            "python_version": platform.python_version(),
            "packages": {
                "reme-ai": _package_version("reme-ai"),
                "agentscope_reme_internal": _package_version("agentscope"),
                "neo4j": _package_version("neo4j"),
                "fastapi": _package_version("fastapi"),
                "fastmcp": _package_version("fastmcp"),
            },
            "reme": reme,
            "neo4j": neo4j,
            "capabilities": _capability_status(resolved),
        }

    @app.get("/api/v1/capabilities")
    async def capabilities() -> dict[str, Any]:
        return _capability_status(resolved)

    @app.post(
        "/api/v1/spaces/{memory_space}/speech/asr",
        response_model=SpeechTranscription,
    )
    async def speech_asr(
        memory_space: MemorySpace,
        request: Request,
    ) -> SpeechTranscription:
        if not (
            resolved.volcengine_speech_app_id
            and resolved.volcengine_speech_api_key
            and resolved.asr_validated_at
        ):
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail={
                    "code": "asr_not_configured",
                    "detail": "No validated ASR capability is configured.",
                },
            )
        content_length = request.headers.get("content-length")
        if content_length and content_length.isdigit() and int(content_length) > MAX_AUDIO_BYTES:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail={"code": "audio_too_large", "detail": "Audio exceeds 20 MiB."},
            )
        audio = await request.body()
        try:
            result = await transcribe_volcengine(
                audio,
                app_id=resolved.volcengine_speech_app_id,
                api_key=resolved.volcengine_speech_api_key,
            )
        except SpeechInputError as exc:
            raise HTTPException(
                status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                detail={"code": "unsupported_audio", "detail": str(exc)},
            ) from exc
        except SpeechProviderError as exc:
            await events.record(
                memory_space,
                "speech.asr.failed",
                {"provider": "volcengine_speech", "error_type": type(exc).__name__},
            )
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail={"code": "asr_provider_failed", "detail": "ASR provider call failed."},
            ) from exc
        await events.record(
            memory_space,
            "speech.asr.completed",
            {
                "provider": "volcengine_speech",
                "audio_bytes": len(audio),
                "duration_ms": result.duration_ms,
            },
        )
        return SpeechTranscription(
            memory_space=memory_space,
            provider="volcengine_speech",
            capability="asr",
            transcript=result.transcript,
            duration_ms=result.duration_ms,
            request_id=result.request_id,
        )

    @app.post(
        "/api/v1/spaces/{memory_space}/memories",
        response_model=MemoryRecord,
        status_code=status.HTTP_201_CREATED,
    )
    async def create_memory(memory_space: MemorySpace, payload: MemoryCreate) -> MemoryRecord:
        record = await asyncio.to_thread(repository.create, memory_space, payload)
        await events.record(memory_space, "memory.created", _event_payload(record))
        return record

    @app.get("/api/v1/spaces/{memory_space}/memories", response_model=MemoryList)
    async def list_memories(
        memory_space: MemorySpace,
        include_removed: bool = Query(default=False),
    ) -> MemoryList:
        items = await asyncio.to_thread(repository.list, memory_space, include_removed)
        return MemoryList(items=items, total=len(items))

    @app.get("/api/v1/spaces/{memory_space}/memories/{memory_id}", response_model=MemoryRecord)
    async def get_memory(memory_space: MemorySpace, memory_id: str) -> MemoryRecord:
        return await asyncio.to_thread(repository.get, memory_space, memory_id)

    @app.patch("/api/v1/spaces/{memory_space}/memories/{memory_id}", response_model=MemoryRecord)
    async def update_memory(
        memory_space: MemorySpace,
        memory_id: str,
        payload: MemoryUpdate,
    ) -> MemoryRecord:
        record = await asyncio.to_thread(repository.update, memory_space, memory_id, payload)
        await events.record(memory_space, "memory.updated", _event_payload(record))
        return record

    @app.post(
        "/api/v1/spaces/{memory_space}/memories/{memory_id}/transitions",
        response_model=MemoryRecord,
    )
    async def transition_memory(
        memory_space: MemorySpace,
        memory_id: str,
        payload: MemoryTransition,
    ) -> MemoryRecord:
        if payload.target_status is MemoryStatus.PURGED:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={"code": "purge_confirmation_required", "detail": "use the explicit purge endpoint"},
            )
        record, previous = await asyncio.to_thread(
            repository.transition,
            memory_space,
            memory_id,
            payload.target_status,
            payload.expected_version,
        )
        await events.record(
            memory_space,
            "memory.transitioned",
            {**_event_payload(record), "from": previous.value, "reason": payload.reason},
        )
        return record

    @app.delete(
        "/api/v1/spaces/{memory_space}/memories/{memory_id}",
        response_model=MemoryRecord,
    )
    async def delete_memory(
        memory_space: MemorySpace,
        memory_id: str,
        expected_version: int = Query(ge=1),
    ) -> MemoryRecord:
        record, previous = await asyncio.to_thread(
            repository.transition,
            memory_space,
            memory_id,
            MemoryStatus.TRASHED,
            expected_version,
        )
        await events.record(
            memory_space,
            "memory.trashed",
            {**_event_payload(record), "from": previous.value},
        )
        return record

    @app.post(
        "/api/v1/spaces/{memory_space}/memories/{memory_id}/purge",
        response_model=MemoryPurgeReport,
    )
    async def purge_memory(
        memory_space: MemorySpace,
        memory_id: str,
        payload: MemoryPurge,
    ) -> MemoryPurgeReport:
        if payload.confirm_memory_id != memory_id:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={"code": "purge_confirmation_mismatch", "detail": "confirm_memory_id must match path"},
            )
        record = await asyncio.to_thread(
            repository.purge,
            memory_space,
            memory_id,
            payload.expected_version,
        )
        await events.record(
            memory_space,
            "memory.purged",
            {**_event_payload(record), "reason": payload.reason},
        )
        layers = {
            "sqlite": CleanupLayer(state="complete", detail="content and source fields removed; tombstone retained"),
            "jsonl": CleanupLayer(state="retained", detail="immutable redacted lifecycle evidence retained"),
            "reme": CleanupLayer(state="not_configured", detail="ReME deletion adapter not implemented"),
            "neo4j": CleanupLayer(state="not_configured", detail="graph deletion adapter not implemented"),
            "indexes": CleanupLayer(state="not_configured", detail="cross-store index cleanup not implemented"),
        }
        return MemoryPurgeReport(
            memory_space=memory_space,
            memory_id=memory_id,
            status=record.status,
            version=record.version,
            complete=all(layer.state == "complete" for layer in layers.values()),
            layers=layers,
        )

    @app.websocket("/ws/v1/spaces/{memory_space}/events")
    async def memory_events(websocket: WebSocket, memory_space: str) -> None:
        if not MEMORY_SPACE_RE.fullmatch(memory_space):
            await websocket.close(code=1008, reason="invalid memory_space")
            return
        await websocket.accept()
        queue = events.subscribe(memory_space)
        try:
            await websocket.send_json(
                {"event_type": "stream.connected", "memory_space": memory_space, "schema_version": 1},
            )
            while True:
                event = await queue.get()
                await websocket.send_json(event)
        except WebSocketDisconnect:
            pass
        finally:
            events.unsubscribe(memory_space, queue)

    if resolved.frontend_dist is not None and (resolved.frontend_dist / "index.html").is_file():
        assets_dir = resolved.frontend_dist / "assets"
        if assets_dir.is_dir():
            app.mount("/assets", StaticFiles(directory=assets_dir), name="frontend-assets")

        async def frontend_index() -> FileResponse:
            return FileResponse(resolved.frontend_dist / "index.html")

        for route in ("/", "/chat", "/memories", "/evaluations", "/ui/status"):
            app.add_api_route(route, frontend_index, methods=["GET"], include_in_schema=False)

    return app


def _problem(status_code: int, code: str, detail: str):
    from fastapi.responses import JSONResponse

    return JSONResponse(status_code=status_code, content={"error": {"code": code, "detail": detail}})


def _event_payload(record: MemoryRecord) -> dict[str, Any]:
    return {
        "memory_id": record.id,
        "status": record.status.value,
        "version": record.version,
        "source_session_id": record.source_session_id,
        "source_turn_id": record.source_turn_id,
        "reme_uri": record.reme_uri,
    }


def _capability_status(settings: Settings) -> dict[str, Any]:
    asr_ready = bool(
        settings.volcengine_speech_app_id
        and settings.volcengine_speech_api_key
        and settings.asr_validated_at
    )
    return {
        "chat": {"status": "not_configured"},
        "asr": {
            "status": "validated" if asr_ready else "not_configured",
            "provider": "Volcengine Speech" if asr_ready else None,
            "transport": "recording-file flash recognition" if asr_ready else None,
            "validated_at": settings.asr_validated_at if asr_ready else None,
        },
        "tts": {"status": "not_configured"},
        "embedding": {"status": "not_configured"},
    }


async def _reme_status(base_url: str) -> dict[str, Any]:
    try:
        async with httpx.AsyncClient(timeout=2) as client:
            response = await client.post(f"{base_url}/version", json={})
            response.raise_for_status()
            body = response.json()
        return {"reachable": True, "base_url": base_url, "response": body}
    except Exception as exc:  # network state is reported, not raised
        return {"reachable": False, "base_url": base_url, "error_type": type(exc).__name__}


def _neo4j_status(settings: Settings) -> dict[str, Any]:
    if not settings.neo4j_password:
        return {"reachable": False, "uri": settings.neo4j_uri, "error_type": "CredentialUnavailable"}
    try:
        with GraphDatabase.driver(
            settings.neo4j_uri,
            auth=(settings.neo4j_user, settings.neo4j_password),
            connection_timeout=2,
        ) as driver:
            driver.verify_connectivity()
            info = driver.get_server_info()
        return {"reachable": True, "uri": settings.neo4j_uri, "agent": info.agent}
    except Exception as exc:  # network state is reported, not raised
        return {"reachable": False, "uri": settings.neo4j_uri, "error_type": type(exc).__name__}


app = create_app()
