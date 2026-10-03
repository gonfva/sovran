"""OpenAI-compatible chat client (stdlib only — no AWS SDK)."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Any


class ModelError(RuntimeError):
    pass


class ModelClient:
    def __init__(self, base_url: str, model: str = "sovran-stub", timeout_s: float = 30.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout_s = timeout_s

    def chat(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        tool_choice: str | dict[str, Any] | None = "auto",
    ) -> tuple[dict[str, Any], int]:
        """Return (assistant message dict, latency_ms)."""
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
        }
        if tools:
            payload["tools"] = tools
            if tool_choice is not None:
                payload["tool_choice"] = tool_choice

        url = f"{self.base_url}/v1/chat/completions"
        body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_s) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:200]
            raise ModelError(f"HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise ModelError(f"URL error: {exc.reason}") from exc
        latency_ms = int((time.time() - t0) * 1000)

        try:
            data = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ModelError("invalid JSON from model") from exc

        choices = data.get("choices") or []
        if not choices:
            raise ModelError("model returned no choices")
        message = choices[0].get("message") or {}
        # Normalize usage if present (metadata only for logs)
        usage = data.get("usage") or {}
        message["_usage"] = {
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
        }
        return message, latency_ms
