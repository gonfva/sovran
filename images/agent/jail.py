"""Filesystem jail: only allow paths under /workspace (with role rules)."""

from __future__ import annotations

from pathlib import Path


class JailError(ValueError):
    """Raised when a path escapes the jail or violates role rules."""


class WorkspaceJail:
    """Resolve and validate paths under a workspace root.

    - All paths must resolve inside workspace (no `..` escape, no symlink escape).
    - Reads allowed under: documents/, sessions/, code/, out/
    - Writes allowed under: documents/, sessions/, out/  (code/ is read-only)
    """

    READ_PREFIXES = ("documents", "sessions", "code", "out")
    WRITE_PREFIXES = ("documents", "sessions", "out")

    def __init__(self, workspace: Path) -> None:
        self.workspace = workspace.resolve()

    def _resolve(self, user_path: str) -> Path:
        if not user_path or not str(user_path).strip():
            raise JailError("empty path")
        raw = str(user_path).strip()
        # Absolute paths must still be under workspace
        if raw.startswith("/"):
            candidate = Path(raw)
        else:
            # Strip leading workspace/ if present
            if raw.startswith("workspace/"):
                raw = raw[len("workspace/") :]
            candidate = self.workspace / raw

        # Resolve without requiring existence (for writes of new files)
        try:
            resolved = candidate.resolve(strict=False)
        except (OSError, RuntimeError) as exc:
            raise JailError(f"cannot resolve path: {exc}") from exc

        try:
            resolved.relative_to(self.workspace)
        except ValueError as exc:
            raise JailError("path escapes workspace jail") from exc

        # Symlink parent escape check: if any parent is a symlink outside workspace
        for parent in [resolved, *resolved.parents]:
            if not parent.exists():
                continue
            if parent.is_symlink():
                target = parent.resolve()
                try:
                    target.relative_to(self.workspace)
                except ValueError as exc:
                    raise JailError("symlink escapes workspace jail") from exc
            if parent == self.workspace:
                break

        return resolved

    def _relative_parts(self, resolved: Path) -> tuple[str, ...]:
        rel = resolved.relative_to(self.workspace)
        parts = rel.parts
        if not parts or parts == (".",):
            raise JailError("path must be under a workspace subdirectory")
        return parts

    def resolve_read(self, user_path: str) -> Path:
        resolved = self._resolve(user_path)
        parts = self._relative_parts(resolved)
        if parts[0] not in self.READ_PREFIXES:
            raise JailError(
                f"read not allowed under '{parts[0]}/' "
                f"(allowed: {', '.join(self.READ_PREFIXES)})"
            )
        return resolved

    def resolve_write(self, user_path: str) -> Path:
        resolved = self._resolve(user_path)
        parts = self._relative_parts(resolved)
        if parts[0] not in self.WRITE_PREFIXES:
            raise JailError(
                f"write not allowed under '{parts[0]}/' "
                f"(allowed: {', '.join(self.WRITE_PREFIXES)}; code/ is read-only)"
            )
        return resolved

    def to_workspace_rel(self, resolved: Path) -> str:
        return resolved.relative_to(self.workspace).as_posix()
