from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterator

from .contracts import (
    ALLOWED_TRANSITIONS,
    MemoryCreate,
    MemoryRecord,
    MemoryStatus,
    MemoryUpdate,
)


class RepositoryError(Exception):
    pass


class NotFoundError(RepositoryError):
    pass


class ConflictError(RepositoryError):
    pass


class InvalidTransitionError(RepositoryError):
    pass


class MemoryRepository:
    def __init__(self, sqlite_path: Path) -> None:
        self.sqlite_path = sqlite_path

    def initialize(self) -> None:
        self.sqlite_path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.executescript(
                """
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS memories (
                    memory_space TEXT NOT NULL,
                    id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    status TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    source_session_id TEXT,
                    source_turn_id TEXT,
                    reme_uri TEXT,
                    version INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (memory_space, id)
                );
                CREATE INDEX IF NOT EXISTS memories_space_status_idx
                    ON memories(memory_space, status, updated_at DESC);
                """,
            )

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.sqlite_path, timeout=5)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    @staticmethod
    def _now() -> str:
        return datetime.now(UTC).isoformat()

    @staticmethod
    def _record(row: sqlite3.Row) -> MemoryRecord:
        return MemoryRecord(
            memory_space=row["memory_space"],
            id=row["id"],
            title=row["title"],
            content=row["content"],
            status=MemoryStatus(row["status"]),
            metadata=json.loads(row["metadata_json"]),
            source_session_id=row["source_session_id"],
            source_turn_id=row["source_turn_id"],
            reme_uri=row["reme_uri"],
            version=row["version"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )

    def create(self, memory_space: str, payload: MemoryCreate) -> MemoryRecord:
        memory_id = str(uuid.uuid4())
        now = self._now()
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO memories (
                    memory_space, id, title, content, status, metadata_json,
                    source_session_id, source_turn_id, reme_uri, version,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                (
                    memory_space,
                    memory_id,
                    payload.title,
                    payload.content,
                    MemoryStatus.DRAFT.value,
                    json.dumps(payload.metadata, ensure_ascii=False, sort_keys=True),
                    payload.source_session_id,
                    payload.source_turn_id,
                    payload.reme_uri,
                    now,
                    now,
                ),
            )
        return self.get(memory_space, memory_id)

    def get(self, memory_space: str, memory_id: str) -> MemoryRecord:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM memories WHERE memory_space = ? AND id = ?",
                (memory_space, memory_id),
            ).fetchone()
        if row is None:
            raise NotFoundError(memory_id)
        return self._record(row)

    def list(self, memory_space: str, include_removed: bool = False) -> list[MemoryRecord]:
        sql = "SELECT * FROM memories WHERE memory_space = ?"
        parameters: list[str] = [memory_space]
        if not include_removed:
            sql += " AND status NOT IN (?, ?)"
            parameters.extend([MemoryStatus.TRASHED.value, MemoryStatus.PURGED.value])
        sql += " ORDER BY updated_at DESC"
        with self._connect() as connection:
            rows = connection.execute(sql, parameters).fetchall()
        return [self._record(row) for row in rows]

    def update(self, memory_space: str, memory_id: str, payload: MemoryUpdate) -> MemoryRecord:
        current = self.get(memory_space, memory_id)
        if current.status not in {MemoryStatus.DRAFT, MemoryStatus.WITHDRAWN}:
            raise InvalidTransitionError("only draft or withdrawn memories may be edited")
        title = payload.title if payload.title is not None else current.title
        content = payload.content if payload.content is not None else current.content
        metadata = payload.metadata if payload.metadata is not None else current.metadata
        with self._connect() as connection:
            result = connection.execute(
                """
                UPDATE memories
                SET title = ?, content = ?, metadata_json = ?,
                    version = version + 1, updated_at = ?
                WHERE memory_space = ? AND id = ? AND version = ?
                """,
                (
                    title,
                    content,
                    json.dumps(metadata, ensure_ascii=False, sort_keys=True),
                    self._now(),
                    memory_space,
                    memory_id,
                    payload.expected_version,
                ),
            )
            if result.rowcount != 1:
                raise ConflictError("version conflict")
        return self.get(memory_space, memory_id)

    def transition(
        self,
        memory_space: str,
        memory_id: str,
        target: MemoryStatus,
        expected_version: int,
    ) -> tuple[MemoryRecord, MemoryStatus]:
        current = self.get(memory_space, memory_id)
        if target not in ALLOWED_TRANSITIONS[current.status]:
            raise InvalidTransitionError(f"{current.status.value} -> {target.value} is not allowed")
        with self._connect() as connection:
            result = connection.execute(
                """
                UPDATE memories
                SET status = ?, version = version + 1, updated_at = ?
                WHERE memory_space = ? AND id = ? AND version = ?
                """,
                (target.value, self._now(), memory_space, memory_id, expected_version),
            )
            if result.rowcount != 1:
                raise ConflictError("version conflict")
        return self.get(memory_space, memory_id), current.status

    def purge(
        self,
        memory_space: str,
        memory_id: str,
        expected_version: int,
    ) -> MemoryRecord:
        current = self.get(memory_space, memory_id)
        if current.status is not MemoryStatus.TRASHED:
            raise InvalidTransitionError("only trashed memories may be purged")
        with self._connect() as connection:
            result = connection.execute(
                """
                UPDATE memories
                SET title = '[purged]', content = '[purged]', metadata_json = '{}',
                    source_session_id = NULL, source_turn_id = NULL, reme_uri = NULL,
                    status = ?, version = version + 1, updated_at = ?
                WHERE memory_space = ? AND id = ? AND version = ?
                """,
                (
                    MemoryStatus.PURGED.value,
                    self._now(),
                    memory_space,
                    memory_id,
                    expected_version,
                ),
            )
            if result.rowcount != 1:
                raise ConflictError("version conflict")
        return self.get(memory_space, memory_id)

    def ping(self) -> bool:
        with self._connect() as connection:
            return connection.execute("SELECT 1").fetchone()[0] == 1
