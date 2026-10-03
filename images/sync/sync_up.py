#!/usr/bin/env python3
"""Sidecar: periodic + final upload of sessions/ and out/ to the data bucket."""

from __future__ import annotations

import os
import signal
import sys
import time
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
DATA_BUCKET = os.environ["DATA_BUCKET"]
AWS_REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "eu-west-1"
INTERVAL = int(os.environ.get("SYNC_INTERVAL_SECONDS", "30"))
SKIP_NAMES = {".ready", ".shutdown"}
SKIP_SUFFIXES = (".pyc", ".pyo", ".tmp", "~")
SKIP_DIR_NAMES = {"__pycache__", ".git"}

_shutdown = False


def log(msg: str) -> None:
    print(msg, flush=True)


def handle_signal(signum, _frame) -> None:
    global _shutdown
    log(f"sync-up signal={signum} shutting down")
    _shutdown = True


def upload_tree(s3, local_root: Path, key_prefix: str) -> int:
    if not local_root.is_dir():
        return 0
    count = 0
    for path in local_root.rglob("*"):
        if not path.is_file():
            continue
        if path.name in SKIP_NAMES:
            continue
        if path.suffix in SKIP_SUFFIXES or path.name.endswith(SKIP_SUFFIXES):
            continue
        if any(part in SKIP_DIR_NAMES for part in path.parts):
            continue
        rel = path.relative_to(local_root).as_posix()
        key = f"{key_prefix.rstrip('/')}/{rel}"
        s3.upload_file(str(path), DATA_BUCKET, key)
        count += 1
    return count


def sync_once(s3) -> int:
    n_sess = upload_tree(s3, WORKSPACE / "sessions", "sessions")
    n_out = upload_tree(s3, WORKSPACE / "out", "out")
    total = n_sess + n_out
    log(f"sync-up uploaded sessions={n_sess} out={n_out} total={total}")
    return total


def main() -> int:
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    log(f"sync-up start bucket={DATA_BUCKET} interval={INTERVAL}s workspace={WORKSPACE}")
    s3 = boto3.client("s3", region_name=AWS_REGION)

    # Wait briefly for workspace layout from sync-down
    for _ in range(120):
        if (WORKSPACE / ".ready").exists() or _shutdown:
            break
        time.sleep(0.5)

    while not _shutdown:
        try:
            sync_once(s3)
        except ClientError as exc:
            log(f"sync-up error: {exc}")
        for _ in range(INTERVAL * 2):
            if _shutdown:
                break
            time.sleep(0.5)

    try:
        sync_once(s3)
        log("sync-up final complete")
    except ClientError as exc:
        log(f"sync-up final error: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
