#!/usr/bin/env python3
"""Init container: populate /workspace from code + data buckets, then write .ready."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
CODE_BUCKET = os.environ["CODE_BUCKET"]
DATA_BUCKET = os.environ["DATA_BUCKET"]
AWS_REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "eu-west-1"


def log(msg: str) -> None:
    print(msg, flush=True)


def download_prefix(s3, bucket: str, prefix: str, dest: Path) -> int:
    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents") or []:
            key = obj["Key"]
            if key.endswith("/"):
                continue
            rel = key[len(prefix) :] if key.startswith(prefix) else key
            if not rel:
                continue
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            s3.download_file(bucket, key, str(target))
            count += 1
    return count


def main() -> int:
    log(f"sync-down start workspace={WORKSPACE} code={CODE_BUCKET} data={DATA_BUCKET}")
    s3 = boto3.client("s3", region_name=AWS_REGION)

    WORKSPACE.mkdir(parents=True, exist_ok=True)
    for sub in ("sessions", "out", "code", "documents"):
        (WORKSPACE / sub).mkdir(parents=True, exist_ok=True)

    try:
        n_code = download_prefix(s3, CODE_BUCKET, "", WORKSPACE / "code")
        n_docs = download_prefix(s3, DATA_BUCKET, "documents/", WORKSPACE / "documents")
    except ClientError as exc:
        log(f"sync-down failed: {exc}")
        return 1

    # Shared volume: allow sibling containers to write sessions/out.
    for path in [WORKSPACE, WORKSPACE / "sessions", WORKSPACE / "out", WORKSPACE / "code", WORKSPACE / "documents"]:
        try:
            path.chmod(0o777)
        except OSError:
            pass

    ready = WORKSPACE / ".ready"
    ready.write_text("ok\n", encoding="utf-8")
    log(f"sync-down complete code_objects={n_code} document_objects={n_docs} ready={ready}")
    return 0



if __name__ == "__main__":
    sys.exit(main())
