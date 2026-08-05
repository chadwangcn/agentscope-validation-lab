from __future__ import annotations

import asyncio
import json
import threading
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


class EventRecorder:
    def __init__(self, trace_dir: Path) -> None:
        self.trace_dir = trace_dir
        self._write_lock = threading.Lock()
        self._subscribers: dict[str, set[asyncio.Queue[dict[str, Any]]]] = defaultdict(set)

    async def record(self, memory_space: str, event_type: str, payload: dict[str, Any]) -> dict[str, Any]:
        event = {
            "schema_version": 1,
            "occurred_at": datetime.now(UTC).isoformat(),
            "memory_space": memory_space,
            "event_type": event_type,
            "payload": payload,
        }
        await asyncio.to_thread(self._append, memory_space, event)
        for queue in tuple(self._subscribers[memory_space]):
            try:
                queue.put_nowait(event)
            except asyncio.QueueFull:
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
                queue.put_nowait(event)
        return event

    def _append(self, memory_space: str, event: dict[str, Any]) -> None:
        self.trace_dir.mkdir(parents=True, exist_ok=True)
        path = self.trace_dir / f"{memory_space}.jsonl"
        line = json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n"
        with self._write_lock, path.open("a", encoding="utf-8") as handle:
            handle.write(line)

    def subscribe(self, memory_space: str) -> asyncio.Queue[dict[str, Any]]:
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=100)
        self._subscribers[memory_space].add(queue)
        return queue

    def unsubscribe(self, memory_space: str, queue: asyncio.Queue[dict[str, Any]]) -> None:
        self._subscribers[memory_space].discard(queue)
        if not self._subscribers[memory_space]:
            del self._subscribers[memory_space]
