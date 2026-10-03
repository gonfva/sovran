#!/usr/bin/env python3
"""Sovran agent (Phase 4): HTTP API + model client + filesystem tools + jail.

By design: no AWS SDK. Tools/session data stay under /workspace.
Platform logs are metadata-only (never full prompt/completion bodies).
Tenant transcripts live under /workspace/sessions/<id>/ for sync-up → S3.
"""

from __future__ import annotations

import json
import os
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from jail import WorkspaceJail
from loop import run_turn
from model_client import ModelClient
from tools import ToolRunner

HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
CLIENT_SLUG = os.environ.get("CLIENT_SLUG", "unknown")
MODEL_BASE_URL = os.environ.get("MODEL_BASE_URL", "http://127.0.0.1:8000").rstrip("/")
MODEL_NAME = os.environ.get("MODEL_NAME", "sovran-stub")
WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
READY_FILE = WORKSPACE / ".ready"
SESSIONS_DIR = WORKSPACE / "sessions"
DOCUMENTS_DIR = WORKSPACE / "documents"
CODE_DIR = WORKSPACE / "code"
OUT_DIR = WORKSPACE / "out"

jail = WorkspaceJail(WORKSPACE)
tools = ToolRunner(jail)
model = ModelClient(MODEL_BASE_URL, model=MODEL_NAME)


def log(msg: str) -> None:
    print(msg, flush=True)


def wait_ready(timeout_s: float = 120.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if READY_FILE.exists():
            return
        time.sleep(0.25)
    raise RuntimeError(f"workspace not ready after {timeout_s}s ({READY_FILE})")


def session_dir(session_id: str) -> Path:
    return SESSIONS_DIR / session_id


def append_transcript(session_id: str, record: dict) -> None:
    path = session_dir(session_id) / "transcript.jsonl"
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def run_chat_turn(session_id: str, message: str) -> dict:
    """Execute one agent turn and persist transcript under the session."""
    result = run_turn(model=model, tools=tools, user_text=message)
    ts = int(time.time())

    # Tenant transcript may include message bodies + tool results (client data).
    # Platform stdout logs must stay metadata-only.
    transcript_record = {
        "ts": ts,
        "type": "turn",
        "user": message,
        "ok": result.get("ok"),
        "reply": result.get("reply") if result.get("ok") else None,
        "error": result.get("error"),
        "tool_trace": result.get("tool_trace") or [],
        "latency_ms": result.get("latency_ms"),
        "rounds": result.get("rounds"),
        "local_tool_fallback": result.get("local_tool_fallback"),
    }
    append_transcript(session_id, transcript_record)

    # Metadata-only platform log
    n_tools = len(result.get("tool_trace") or [])
    tool_names = ",".join(
        sorted({t.get("name") or "?" for t in (result.get("tool_trace") or [])})
    ) or "-"
    log(
        f"client={CLIENT_SLUG} session_id={session_id} status="
        f"{'ok' if result.get('ok') else 'error'} latency_ms={result.get('latency_ms')} "
        f"rounds={result.get('rounds')} tools={n_tools} tool_names={tool_names} "
        f"user_chars={len(message)} reply_chars={len(str(result.get('reply') or ''))} "
        f"prompt_tokens={result.get('prompt_tokens')} completion_tokens={result.get('completion_tokens')}"
    )
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = "sovran-agent/0.4"

    def log_message(self, fmt: str, *args) -> None:
        log(f"client={CLIENT_SLUG} {self.command} {self.path} {fmt % args}")

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def _send(self, code: int, body: dict | list | str) -> None:
        if isinstance(body, (dict, list)):
            raw = json.dumps(body).encode("utf-8")
            ctype = "application/json"
        else:
            raw = str(body).encode("utf-8")
            ctype = "text/plain; charset=utf-8"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/health":
            self._send(
                200,
                {
                    "status": "ok",
                    "service": "sovran-agent",
                    "version": "0.4",
                    "client": CLIENT_SLUG,
                    "ready": READY_FILE.exists(),
                    "tools": ["read_file", "write_file", "list_dir"],
                },
            )
            return

        if path == "/v1/sessions":
            SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
            sessions = sorted(p.name for p in SESSIONS_DIR.iterdir() if p.is_dir())
            self._send(200, {"sessions": sessions})
            return

        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "v1" and parts[1] == "sessions" and parts[3] == "files":
            session_id = parts[2]
            sdir = session_dir(session_id)
            if not sdir.is_dir():
                self._send(404, {"error": "session not found"})
                return
            files = sorted(
                str(p.relative_to(sdir)) for p in sdir.rglob("*") if p.is_file()
            )
            self._send(200, {"session_id": session_id, "files": files})
            return

        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path.rstrip("/") or "/"
        try:
            payload = self._read_json()
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid json"})
            return

        if path == "/v1/sessions":
            session_id = payload.get("session_id") or uuid.uuid4().hex[:16]
            sdir = session_dir(session_id)
            sdir.mkdir(parents=True, exist_ok=True)
            meta = {
                "session_id": session_id,
                "client": CLIENT_SLUG,
                "created_at": int(time.time()),
            }
            (sdir / "meta.json").write_text(json.dumps(meta) + "\n", encoding="utf-8")
            log(f"client={CLIENT_SLUG} session_id={session_id} status=created")
            self._send(201, meta)
            return

        parts = path.strip("/").split("/")
        # POST /v1/sessions/{id}/chat  and  /v1/sessions/{id}/turn
        if (
            len(parts) == 4
            and parts[0] == "v1"
            and parts[1] == "sessions"
            and parts[3] in ("chat", "turn")
        ):
            session_id = parts[2]
            sdir = session_dir(session_id)
            if not sdir.is_dir():
                self._send(404, {"error": "session not found"})
                return
            message = str(payload.get("message") or payload.get("content") or "")
            if not message:
                self._send(400, {"error": "message required"})
                return

            result = run_chat_turn(session_id, message)
            if not result.get("ok"):
                self._send(
                    502,
                    {
                        "session_id": session_id,
                        "error": result.get("error") or "turn failed",
                        "tool_trace_count": len(result.get("tool_trace") or []),
                    },
                )
                return

            # Response includes tool names/ok flags but full tool results live in transcript
            safe_trace = [
                {
                    "name": t.get("name"),
                    "ok": (t.get("result") or {}).get("ok"),
                    "path": (t.get("result") or {}).get("path"),
                }
                for t in (result.get("tool_trace") or [])
            ]
            self._send(
                200,
                {
                    "session_id": session_id,
                    "reply": result.get("reply"),
                    "latency_ms": result.get("latency_ms"),
                    "rounds": result.get("rounds"),
                    "tools": safe_trace,
                    "local_tool_fallback": result.get("local_tool_fallback"),
                },
            )
            return

        # Phase 4 exit demo: create session, read a doc, write a session note, chat.
        if path == "/v1/demo":
            session_id = uuid.uuid4().hex[:16]
            sdir = session_dir(session_id)
            sdir.mkdir(parents=True, exist_ok=True)
            (sdir / "meta.json").write_text(
                json.dumps(
                    {
                        "session_id": session_id,
                        "client": CLIENT_SLUG,
                        "created_at": int(time.time()),
                        "kind": "phase4-demo",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            # Multi-step: list documents, read hello, write session artifact
            steps = [
                "list documents",
                "read documents/hello.txt",
                f"write sessions/{session_id}/agent_note.txt with Phase4 tool write by client {CLIENT_SLUG}",
            ]
            replies = []
            all_tools = []
            total_latency = 0
            for step in steps:
                result = run_chat_turn(session_id, step)
                total_latency += int(result.get("latency_ms") or 0)
                replies.append(
                    {
                        "message": step,
                        "ok": result.get("ok"),
                        "reply": result.get("reply"),
                        "tools": [
                            {
                                "name": t.get("name"),
                                "ok": (t.get("result") or {}).get("ok"),
                                "path": (t.get("result") or {}).get("path"),
                            }
                            for t in (result.get("tool_trace") or [])
                        ],
                    }
                )
                all_tools.extend(result.get("tool_trace") or [])
                if not result.get("ok"):
                    self._send(
                        502,
                        {
                            "session_id": session_id,
                            "error": result.get("error"),
                            "steps": replies,
                        },
                    )
                    return

            # Confirm tool wrote the note for S3 sync verification
            note_path = sdir / "agent_note.txt"
            self._send(
                200,
                {
                    "session_id": session_id,
                    "client": CLIENT_SLUG,
                    "latency_ms": total_latency,
                    "steps": replies,
                    "tool_count": len(all_tools),
                    "note_written": note_path.is_file(),
                    "files": sorted(str(p.relative_to(sdir)) for p in sdir.rglob("*") if p.is_file()),
                },
            )
            return

        self._send(404, {"error": "not found"})


def main() -> None:
    log(f"agent starting client={CLIENT_SLUG} port={PORT} model={MODEL_BASE_URL}")
    try:
        wait_ready()
    except Exception:
        log("ready wait failed:\n" + traceback.format_exc())
        raise
    for d in (SESSIONS_DIR, DOCUMENTS_DIR, CODE_DIR, OUT_DIR):
        d.mkdir(parents=True, exist_ok=True)
    log(
        f"agent ready client={CLIENT_SLUG} workspace={WORKSPACE} "
        f"version=0.4 tools=read_file,write_file,list_dir"
    )
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
