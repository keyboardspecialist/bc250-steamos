#!/usr/bin/env python3
"""Load and validate generated menu targets."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from menu_graph import MenuGraphError


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "menus/targets.json"
NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
SYMBOL_RE = re.compile(r"^[a-z][a-z0-9_]*$")
ENTRY_RE = re.compile(r"^[a-z][a-z0-9-]*$")
EXPECTED_TARGETS = {
    "cec",
    "compute",
    "maintenance",
    "mesh-shader",
    "power",
    "ram-split",
    "storage",
    "swap",
    "toolkit",
    "update-persistence",
}


@dataclass(frozen=True)
class MenuTarget:
    name: str
    graph_path: Path
    bash_path: Path
    symbol: str
    entries: tuple[tuple[str, str], ...]
    templates: frozenset[str]

    @property
    def marker_name(self) -> str:
        return self.name.upper().replace("-", "_")

    @property
    def begin(self) -> str:
        return f"# BEGIN GENERATED {self.marker_name} MENUS"

    @property
    def end(self) -> str:
        return f"# END GENERATED {self.marker_name} MENUS"


def _repo_path(value: object, field: str) -> Path:
    if not isinstance(value, str) or not value:
        raise MenuGraphError(f"menu target {field} must be a non-empty string")
    path = (ROOT / value).resolve()
    try:
        path.relative_to(ROOT)
    except ValueError:
        raise MenuGraphError(f"menu target {field} escapes the repository: {value}")
    return path


def load_targets(path: Path = MANIFEST_PATH) -> tuple[MenuTarget, ...]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MenuGraphError(f"cannot load menu target manifest: {error}")
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise MenuGraphError("menu target manifest must use schemaVersion 1")
    raw_targets = payload.get("targets")
    if not isinstance(raw_targets, list) or not raw_targets:
        raise MenuGraphError("menu target manifest must define a non-empty targets list")

    targets = []
    names: set[str] = set()
    graph_paths: set[Path] = set()
    bash_paths: set[Path] = set()
    symbols: set[str] = set()
    for raw in raw_targets:
        if not isinstance(raw, dict):
            raise MenuGraphError("each menu target must be an object")
        name = raw.get("name")
        symbol = raw.get("symbol")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise MenuGraphError(f"invalid menu target name: {name!r}")
        if not isinstance(symbol, str) or not SYMBOL_RE.fullmatch(symbol):
            raise MenuGraphError(f"invalid menu target symbol: {symbol!r}")
        graph_path = _repo_path(raw.get("graph"), "graph")
        bash_path = _repo_path(raw.get("bash"), "bash")

        raw_entries = raw.get("entries")
        if not isinstance(raw_entries, list) or not raw_entries:
            raise MenuGraphError(f"menu target {name} must define entries")
        entries = []
        entry_names: set[str] = set()
        for raw_entry in raw_entries:
            if (
                not isinstance(raw_entry, list)
                or len(raw_entry) != 2
                or not all(isinstance(item, str) for item in raw_entry)
            ):
                raise MenuGraphError(f"menu target {name} has an invalid entry")
            entry_name, menu_id = raw_entry
            if not ENTRY_RE.fullmatch(entry_name) or entry_name in entry_names:
                raise MenuGraphError(
                    f"menu target {name} has an invalid or duplicate entry: {entry_name}"
                )
            entry_names.add(entry_name)
            entries.append((entry_name, menu_id))

        raw_templates = raw.get("templates", [])
        if not isinstance(raw_templates, list) or not all(
            isinstance(item, str) and re.fullmatch(r"[A-Z][A-Z0-9_]*", item)
            for item in raw_templates
        ):
            raise MenuGraphError(f"menu target {name} has invalid templates")

        for value, seen, label in (
            (name, names, "name"),
            (graph_path, graph_paths, "graph"),
            (bash_path, bash_paths, "bash target"),
            (symbol, symbols, "symbol"),
        ):
            if value in seen:
                raise MenuGraphError(f"duplicate menu target {label}: {value}")
            seen.add(value)

        targets.append(
            MenuTarget(
                name,
                graph_path,
                bash_path,
                symbol,
                tuple(entries),
                frozenset(raw_templates),
            )
        )
    if names != EXPECTED_TARGETS:
        missing = sorted(EXPECTED_TARGETS - names)
        extra = sorted(names - EXPECTED_TARGETS)
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unexpected " + ", ".join(extra))
        raise MenuGraphError("menu target set is incomplete: " + "; ".join(details))
    expected_graph_paths = set((ROOT / "menus").glob("*.mmd"))
    if graph_paths != expected_graph_paths:
        missing = sorted(path.name for path in expected_graph_paths - graph_paths)
        extra = sorted(path.name for path in graph_paths - expected_graph_paths)
        details = []
        if missing:
            details.append("unconfigured " + ", ".join(missing))
        if extra:
            details.append("unexpected " + ", ".join(extra))
        raise MenuGraphError("menu graph set is incomplete: " + "; ".join(details))
    return tuple(targets)
