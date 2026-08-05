from __future__ import annotations

from enum import StrEnum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class MemoryStatus(StrEnum):
    DRAFT = "draft"
    REVIEW = "review"
    PUBLISHED = "published"
    WITHDRAWN = "withdrawn"
    TRASHED = "trashed"
    PURGED = "purged"


ALLOWED_TRANSITIONS: dict[MemoryStatus, frozenset[MemoryStatus]] = {
    MemoryStatus.DRAFT: frozenset({MemoryStatus.REVIEW, MemoryStatus.TRASHED}),
    MemoryStatus.REVIEW: frozenset({MemoryStatus.DRAFT, MemoryStatus.PUBLISHED}),
    MemoryStatus.PUBLISHED: frozenset({MemoryStatus.WITHDRAWN}),
    MemoryStatus.WITHDRAWN: frozenset({MemoryStatus.PUBLISHED, MemoryStatus.TRASHED}),
    MemoryStatus.TRASHED: frozenset({MemoryStatus.WITHDRAWN, MemoryStatus.PURGED}),
    MemoryStatus.PURGED: frozenset(),
}


class MemoryCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=200)
    content: str = Field(min_length=1, max_length=1_000_000)
    metadata: dict[str, Any] = Field(default_factory=dict)
    source_session_id: str | None = Field(default=None, max_length=128)
    source_turn_id: str | None = Field(default=None, max_length=128)
    reme_uri: str | None = Field(default=None, max_length=1000)


class MemoryUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str | None = Field(default=None, min_length=1, max_length=200)
    content: str | None = Field(default=None, min_length=1, max_length=1_000_000)
    metadata: dict[str, Any] | None = None
    expected_version: int = Field(ge=1)


class MemoryTransition(BaseModel):
    model_config = ConfigDict(extra="forbid")

    target_status: MemoryStatus
    expected_version: int = Field(ge=1)
    reason: str | None = Field(default=None, max_length=500)


class MemoryPurge(BaseModel):
    model_config = ConfigDict(extra="forbid")

    expected_version: int = Field(ge=1)
    confirm_memory_id: str = Field(min_length=1, max_length=128)
    confirm_irreversible: Literal[True]
    reason: str = Field(min_length=1, max_length=500)


class MemoryRecord(BaseModel):
    memory_space: str
    id: str
    title: str
    content: str
    status: MemoryStatus
    metadata: dict[str, Any]
    source_session_id: str | None
    source_turn_id: str | None
    reme_uri: str | None
    version: int
    created_at: str
    updated_at: str


class MemoryList(BaseModel):
    items: list[MemoryRecord]
    total: int


class CleanupLayer(BaseModel):
    state: Literal["complete", "retained", "pending", "not_configured"]
    detail: str


class MemoryPurgeReport(BaseModel):
    memory_space: str
    memory_id: str
    status: MemoryStatus
    version: int
    complete: bool
    layers: dict[str, CleanupLayer]


class SpeechTranscription(BaseModel):
    memory_space: str
    provider: Literal["volcengine_speech"]
    capability: Literal["asr"]
    transcript: str
    duration_ms: int | None
    request_id: str
