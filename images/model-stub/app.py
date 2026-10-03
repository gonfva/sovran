#!/usr/bin/env python3
"""OpenAI-compatible model stub for the Sovran PoC.

Supports basic chat + optional tool_calls so the Phase 4 agent loop can exercise
function-calling against a private model plane (no external APIs).
"""

from __future__ import annotations

import json
import os
import re
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = int(os.environ.get("PORT", "8000"))
HOST = os.environ.get("HOST", "0.0.0.0")


def _tool_call(name: str, arguments: dict) -> dict:
    return {
        "id": f"call_{uuid.uuid4().hex[:10]}",
        "type": "function",
        "function": {
            "name": name,
            "arguments": json.dumps(arguments),
        },
    }


def _plan_tools_from_user(text: str) -> list[dict]:
    """Emit tool_calls for simple file intents (mirrors agent fallback)."""
    t = text.strip()
    m = re.search(
        r"write\s+(?:file\s+)?(?P<path>[\w./-]+)\s*(?:with|:)\s*(?P<body>.+)$",
        t,
        re.IGNORECASE | re.DOTALL,
    )
    if m:
        return [
            _tool_call(
                "write_file",
                {"path": m.group("path").strip(), "content": m.group("body").strip()},
            )
        ]
    m = re.search(
        r"(?:read|show|cat|open)\s+(?:file\s+)?(?P<path>[\w./-]+)",
        t,
        re.IGNORECASE,
    )
    if m:
        return [_tool_call("read_file", {"path": m.group("path").strip()})]
    m = re.search(
        r"(?:list|ls)\s+(?:dir\s+|directory\s+)?(?P<path>[\w./-]+)",
        t,
        re.IGNORECASE,
    )
    if m:
        return [_tool_call("list_dir", {"path": m.group("path").strip()})]
    return []


def _chat_completion(payload: dict) -> dict:
    messages = payload.get("messages") or []
    model = payload.get("model") or "sovran-stub"
    tools = payload.get("tools") or []

    # If the last non-system message is a tool result, return a short summary.
    last = messages[-1] if messages else {}
    if last.get("role") == "tool":
        try:
            result = json.loads(last.get("content") or "{}")
        except json.JSONDecodeError:
            result = {"raw": last.get("content")}
        if result.get("ok") and "content" in result:
            content = f"[stub] read {result.get('path')}: {str(result.get('content'))[:400]}"
        elif result.get("ok") and result.get("path"):
            content = f"[stub] tool ok path={result.get('path')}"
        elif result.get("ok") and "entries" in result:
            names = [e.get("name") for e in (result.get("entries") or [])][:20]
            content = f"[stub] listed {result.get('path')}: {', '.join(names)}"
        else:
            content = f"[stub] tool result: {json.dumps(result)[:300]}"
        return {
            "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": content},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }

    last_user = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            last_user = str(m.get("content") or "")
            break

    # If tools were advertised, optionally emit tool_calls.
    if tools and last_user:
        planned = _plan_tools_from_user(last_user)
        if planned:
            return {
                "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": None,
                            "tool_calls": planned,
                        },
                        "finish_reason": "tool_calls",
                    }
                ],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            }

    content = f"[stub] echo: {last_user}" if last_user else "[stub] ok"
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "sovran-model-stub/0.2"

    def log_message(self, fmt: str, *args) -> None:
        # Metadata only — never log request/response bodies.
        print(f"{self.address_string()} {self.command} {self.path} {fmt % args}")

    def _send(self, code: int, body: dict | list | str, content_type: str = "application/json") -> None:
        if isinstance(body, (dict, list)):
            raw = json.dumps(body).encode("utf-8")
        else:
            raw = str(body).encode("utf-8")
            content_type = "text/plain; charset=utf-8"
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path in ("/health", "/healthz", "/v1/models"):
            if path == "/v1/models":
                self._send(
                    200,
                    {
                        "object": "list",
                        "data": [
                            {
                                "id": "sovran-stub",
                                "object": "model",
                                "created": int(time.time()),
                                "owned_by": "sovran",
                            }
                        ],
                    },
                )
                return
            self._send(200, {"status": "ok", "service": "sovran-model-stub", "version": "0.2"})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid json"})
            return

        if path in ("/v1/chat/completions", "/chat/completions"):
            self._send(200, _chat_completion(payload))
            return

        if path in ("/v1/completions", "/completions"):
            prompt = str(payload.get("prompt") or "")
            model = payload.get("model") or "sovran-stub"
            self._send(
                200,
                {
                    "id": f"cmpl-{uuid.uuid4().hex[:12]}",
                    "object": "text_completion",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [
                        {
                            "text": f"[stub] echo: {prompt}",
                            "index": 0,
                            "finish_reason": "stop",
                        }
                    ],
                },
            )
            return

        self._send(404, {"error": "not found"})


def main() -> None:
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"sovran-model-stub listening on {HOST}:{PORT}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
