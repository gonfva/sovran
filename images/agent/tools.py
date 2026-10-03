"""Agent tools: read_file / write_file / list_dir under the workspace jail."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from jail import JailError, WorkspaceJail

# OpenAI-style tool schemas (function calling).
TOOL_SPECS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": (
                "Read a UTF-8 text file under the workspace jail "
                "(documents/, sessions/, code/, out/)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path relative to /workspace, e.g. documents/hello.txt",
                    },
                    "max_bytes": {
                        "type": "integer",
                        "description": "Optional max bytes to read (default 65536).",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": (
                "Write UTF-8 text to a file under documents/, sessions/, or out/ "
                "(code/ is read-only)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path relative to /workspace",
                    },
                    "content": {
                        "type": "string",
                        "description": "Full file contents to write",
                    },
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_dir",
            "description": "List files under a directory in the workspace jail.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Directory path relative to /workspace",
                    },
                },
                "required": ["path"],
            },
        },
    },
]


class ToolRunner:
    def __init__(self, jail: WorkspaceJail) -> None:
        self.jail = jail

    def run(self, name: str, arguments: dict[str, Any] | str) -> dict[str, Any]:
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments or "{}")
            except json.JSONDecodeError:
                return {"ok": False, "error": "invalid tool arguments json"}

        try:
            if name == "read_file":
                return self._read_file(arguments)
            if name == "write_file":
                return self._write_file(arguments)
            if name == "list_dir":
                return self._list_dir(arguments)
            return {"ok": False, "error": f"unknown tool: {name}"}
        except JailError as exc:
            return {"ok": False, "error": f"jail: {exc}"}
        except OSError as exc:
            return {"ok": False, "error": f"os: {exc}"}

    def _read_file(self, args: dict[str, Any]) -> dict[str, Any]:
        path = self.jail.resolve_read(str(args.get("path") or ""))
        max_bytes = int(args.get("max_bytes") or 65536)
        if max_bytes < 1 or max_bytes > 1_000_000:
            max_bytes = 65536
        if not path.is_file():
            return {"ok": False, "error": "not a file", "path": self.jail.to_workspace_rel(path)}
        data = path.read_bytes()[:max_bytes]
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            return {
                "ok": False,
                "error": "file is not valid utf-8 text",
                "path": self.jail.to_workspace_rel(path),
                "bytes": len(data),
            }
        return {
            "ok": True,
            "path": self.jail.to_workspace_rel(path),
            "content": text,
            "bytes": len(data),
            "truncated": path.stat().st_size > max_bytes,
        }

    def _write_file(self, args: dict[str, Any]) -> dict[str, Any]:
        path = self.jail.resolve_write(str(args.get("path") or ""))
        content = str(args.get("content") if args.get("content") is not None else "")
        path.parent.mkdir(parents=True, exist_ok=True)
        raw = content.encode("utf-8")
        path.write_bytes(raw)
        return {
            "ok": True,
            "path": self.jail.to_workspace_rel(path),
            "bytes": len(raw),
        }

    def _list_dir(self, args: dict[str, Any]) -> dict[str, Any]:
        path = self.jail.resolve_read(str(args.get("path") or ""))
        if not path.exists():
            return {"ok": False, "error": "not found", "path": self.jail.to_workspace_rel(path)}
        if not path.is_dir():
            return {"ok": False, "error": "not a directory", "path": self.jail.to_workspace_rel(path)}
        entries = []
        for child in sorted(path.iterdir(), key=lambda p: p.name):
            # Do not follow into jail-escaping symlinks for listing names only
            kind = "dir" if child.is_dir() else "file"
            entries.append({"name": child.name, "kind": kind})
        return {
            "ok": True,
            "path": self.jail.to_workspace_rel(path),
            "entries": entries,
        }
