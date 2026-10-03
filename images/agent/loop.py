"""Agent turn loop: model (+ optional tool calls) with jail tools."""

from __future__ import annotations

import json
import re
import uuid
from typing import Any

from model_client import ModelClient, ModelError
from tools import TOOL_SPECS, ToolRunner

SYSTEM_PROMPT = """You are a privacy-preserving workspace agent for client tenants.
You may use tools to read/write files under /workspace (documents, sessions, code read-only, out).
Never invent file contents when a tool can read them. Prefer short answers after tool use.
When the user asks to read or write a file, use the tools."""


def _parse_tool_args(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            return json.loads(raw or "{}")
        except json.JSONDecodeError:
            return {}
    return {}


def _local_tool_plan(user_text: str) -> list[dict[str, Any]]:
    """Deterministic fallback planner when the model returns no tool_calls.

    Recognizes simple intents so Phase 4 exit works with a basic stub model.
    """
    text = user_text.strip()
    plans: list[dict[str, Any]] = []

    # write path <<<
    # content
    # >>>
    m = re.search(
        r"write\s+(?:file\s+)?(?P<path>[\w./-]+)\s*(?:with|:)\s*(?P<body>.+)$",
        text,
        re.IGNORECASE | re.DOTALL,
    )
    if m:
        plans.append(
            {
                "id": f"local_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {
                    "name": "write_file",
                    "arguments": json.dumps(
                        {"path": m.group("path").strip(), "content": m.group("body").strip()}
                    ),
                },
            }
        )
        return plans

    m = re.search(
        r"(?:read|show|cat|open)\s+(?:file\s+)?(?P<path>[\w./-]+)",
        text,
        re.IGNORECASE,
    )
    if m:
        plans.append(
            {
                "id": f"local_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {
                    "name": "read_file",
                    "arguments": json.dumps({"path": m.group("path").strip()}),
                },
            }
        )
        return plans

    m = re.search(
        r"(?:list|ls)\s+(?:dir\s+|directory\s+)?(?P<path>[\w./-]+)",
        text,
        re.IGNORECASE,
    )
    if m:
        plans.append(
            {
                "id": f"local_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {
                    "name": "list_dir",
                    "arguments": json.dumps({"path": m.group("path").strip()}),
                },
            }
        )
        return plans

    return plans


def run_turn(
    *,
    model: ModelClient,
    tools: ToolRunner,
    user_text: str,
    history: list[dict[str, Any]] | None = None,
    max_tool_rounds: int = 4,
) -> dict[str, Any]:
    """Run one user turn; may execute multiple tool rounds.

    Returns a result dict with reply, tool_trace, latencies, usage metadata.
    Does not include full prompt bodies in a separate log channel — caller
    writes transcript under sessions/ and logs only metadata.
    """
    messages: list[dict[str, Any]] = [{"role": "system", "content": SYSTEM_PROMPT}]
    if history:
        messages.extend(history)
    messages.append({"role": "user", "content": user_text})

    tool_trace: list[dict[str, Any]] = []
    latencies: list[int] = []
    total_prompt_tokens = 0
    total_completion_tokens = 0
    local_tools_used = False

    for round_i in range(max_tool_rounds + 1):
        try:
            assistant, latency_ms = model.chat(messages, tools=TOOL_SPECS, tool_choice="auto")
        except ModelError as exc:
            return {
                "ok": False,
                "error": str(exc),
                "tool_trace": tool_trace,
                "latency_ms": sum(latencies),
                "rounds": round_i,
            }
        latencies.append(latency_ms)
        usage = assistant.pop("_usage", {}) or {}
        if usage.get("prompt_tokens"):
            total_prompt_tokens += int(usage["prompt_tokens"] or 0)
        if usage.get("completion_tokens"):
            total_completion_tokens += int(usage["completion_tokens"] or 0)

        tool_calls = assistant.get("tool_calls") or []

        # Fallback planner on first round if model returned no tools
        if not tool_calls and round_i == 0 and not local_tools_used:
            planned = _local_tool_plan(user_text)
            if planned:
                local_tools_used = True
                tool_calls = planned
                assistant = {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": planned,
                }

        if not tool_calls:
            content = assistant.get("content") or ""
            return {
                "ok": True,
                "reply": str(content),
                "tool_trace": tool_trace,
                "latency_ms": sum(latencies),
                "model_latencies_ms": latencies,
                "rounds": round_i + 1,
                "prompt_tokens": total_prompt_tokens or None,
                "completion_tokens": total_completion_tokens or None,
                "local_tool_fallback": local_tools_used,
            }

        # Append assistant message with tool_calls
        messages.append(
            {
                "role": "assistant",
                "content": assistant.get("content"),
                "tool_calls": tool_calls,
            }
        )

        for tc in tool_calls:
            fn = tc.get("function") or {}
            name = fn.get("name") or ""
            args = _parse_tool_args(fn.get("arguments"))
            result = tools.run(name, args)
            tool_trace.append(
                {
                    "tool_call_id": tc.get("id"),
                    "name": name,
                    "arguments": args,
                    # result may contain file content — stored in transcript only
                    "result": result,
                }
            )
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": tc.get("id") or f"call_{uuid.uuid4().hex[:8]}",
                    "name": name,
                    "content": json.dumps(result),
                }
            )

    # Exceeded rounds — synthesize from last tool results
    summary = "Tool rounds exhausted."
    if tool_trace:
        last = tool_trace[-1]["result"]
        summary = f"Last tool result: {json.dumps(last)[:500]}"
    return {
        "ok": True,
        "reply": summary,
        "tool_trace": tool_trace,
        "latency_ms": sum(latencies),
        "model_latencies_ms": latencies,
        "rounds": max_tool_rounds + 1,
        "prompt_tokens": total_prompt_tokens or None,
        "completion_tokens": total_completion_tokens or None,
        "local_tool_fallback": local_tools_used,
        "truncated_rounds": True,
    }
