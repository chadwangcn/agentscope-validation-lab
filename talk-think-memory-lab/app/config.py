from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    sqlite_path: Path
    trace_dir: Path
    reme_base_url: str
    neo4j_uri: str
    neo4j_user: str
    neo4j_password: str | None
    frontend_dist: Path | None = None
    volcengine_speech_app_id: str | None = None
    volcengine_speech_api_key: str | None = None
    asr_validated_at: str | None = None

    @classmethod
    def from_env(cls) -> "Settings":
        data_dir = Path(os.getenv("LAB_DATA_DIR", "./var")).resolve()
        return cls(
            data_dir=data_dir,
            sqlite_path=Path(os.getenv("LAB_SQLITE_PATH", data_dir / "lab.sqlite3")).resolve(),
            trace_dir=Path(os.getenv("LAB_TRACE_DIR", data_dir / "traces")).resolve(),
            reme_base_url=os.getenv("REME_BASE_URL", "http://127.0.0.1:12333").rstrip("/"),
            neo4j_uri=os.getenv("NEO4J_URI", "bolt://127.0.0.1:17687"),
            neo4j_user=os.getenv("NEO4J_USER", "neo4j"),
            neo4j_password=os.getenv("NEO4J_PASSWORD"),
            frontend_dist=Path(
                os.getenv(
                    "LAB_FRONTEND_DIST",
                    Path(__file__).resolve().parents[1] / "frontend" / "dist",
                ),
            ).resolve(),
            volcengine_speech_app_id=os.getenv("VOLCENGINE_SPEECH_APP_ID"),
            volcengine_speech_api_key=os.getenv("VOLCENGINE_SPEECH_API_KEY"),
            asr_validated_at=os.getenv("VOLCENGINE_ASR_VALIDATED_AT"),
        )
