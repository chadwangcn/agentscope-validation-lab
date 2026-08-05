from __future__ import annotations

import grp
import json
import os
from pathlib import Path
import re
import sys
import tempfile


TARGET = Path("/etc/talk-think-memory-lab/speech.env")


def main() -> None:
    incoming = json.load(sys.stdin)
    app_id = incoming.get("app_id")
    api_key = incoming.get("api_key")
    validated_at = incoming.get("validated_at")
    if not isinstance(app_id, str) or not re.fullmatch(r"[A-Za-z0-9._-]{2,128}", app_id):
        raise SystemExit("invalid speech app id")
    if not isinstance(api_key, str) or not re.fullmatch(r"[A-Za-z0-9._:/+=-]{8,512}", api_key):
        raise SystemExit("invalid speech API key")
    if not isinstance(validated_at, str) or not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z",
        validated_at,
    ):
        raise SystemExit("invalid validation timestamp")

    TARGET.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix="speech.env.",
        dir=TARGET.parent,
        text=True,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(f"VOLCENGINE_SPEECH_APP_ID={app_id}\n")
            handle.write(f"VOLCENGINE_SPEECH_API_KEY={api_key}\n")
            handle.write(f"VOLCENGINE_ASR_VALIDATED_AT={validated_at}\n")
        os.chown(temporary, 0, grp.getgrnam("talkthinklab").gr_gid)
        os.chmod(temporary, 0o640)
        os.replace(temporary, TARGET)
    finally:
        if temporary.exists():
            temporary.unlink()

    print(json.dumps({"installed": True, "validated_at": validated_at}, sort_keys=True))


if __name__ == "__main__":
    main()
