#!/usr/bin/env python3
"""Generate committed Bash menu renderers from canonical Mermaid graphs."""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

from menu_graph import MenuGraph, MenuGraphError, parse
from menu_targets import ROOT, MenuTarget, load_targets


TEMPLATE_RE = re.compile(r"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}")
FUNCTION_RE = re.compile(
    r"^[ \t]*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*\{",
    re.MULTILINE,
)


def bash_double(value: str, templates: frozenset[str]) -> str:
    variables = set(TEMPLATE_RE.findall(value))
    unknown = variables - templates
    if unknown:
        raise MenuGraphError("unknown title template: " + ", ".join(sorted(unknown)))
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("`", "\\`")
        .replace("$", "\\$")
    )
    return TEMPLATE_RE.sub(lambda match: "${" + match.group(1) + "}", escaped)


def _marker_bounds(source: str, target: MenuTarget) -> tuple[int, int]:
    begin_matches = list(re.finditer(rf"(?m)^{re.escape(target.begin)}\n", source))
    end_matches = list(re.finditer(rf"(?m)^{re.escape(target.end)}\n", source))
    if len(begin_matches) != 1 or len(end_matches) != 1:
        raise MenuGraphError(
            f"{target.bash_path}: generated {target.name} markers are incomplete or duplicated"
        )
    start = begin_matches[0].start()
    end_start = end_matches[0].start()
    if end_start <= start:
        raise MenuGraphError(f"{target.bash_path}: generated menu markers are reversed")
    return start, end_start + len(target.end)


def source_without_region(source: str, target: MenuTarget) -> str:
    start, end = _marker_bounds(source, target)
    return source[:start] + source[end:]


def validate_target(target: MenuTarget, graph: MenuGraph, source: str) -> None:
    menu_ids = {node.id for node in graph.nodes.values() if node.kind == "menu"}
    entry_ids = {menu_id for _, menu_id in target.entries}
    for entry_name, menu_id in target.entries:
        if menu_id not in menu_ids:
            raise MenuGraphError(
                f"menu target {target.name} entry {entry_name} is not a menu: {menu_id}"
            )
    if dict(target.entries).get("root") != graph.root.id:
        raise MenuGraphError(
            f"menu target {target.name} must map the root entry to {graph.root.id}"
        )
    declared_entries = {
        node.id for node in graph.nodes.values() if node.style == "entry"
    }
    missing_entries = declared_entries - entry_ids
    if missing_entries:
        raise MenuGraphError(
            f"menu target {target.name} has unexposed entry menus: "
            + ", ".join(sorted(missing_entries))
        )
    for node in graph.nodes.values():
        node_templates = set(TEMPLATE_RE.findall(node.title + node.hint))
        if node_templates and (node.kind != "menu" or TEMPLATE_RE.search(node.hint)):
            raise MenuGraphError(
                f"menu target {target.name} templates are only allowed in menu titles: {node.id}"
            )

    functions = set(FUNCTION_RE.findall(source_without_region(source, target)))
    required = {f"{target.symbol}_badge", f"{target.symbol}_activate"}
    missing = required - functions
    if missing:
        raise MenuGraphError(
            f"menu target {target.name} is missing Bash adapters: "
            + ", ".join(sorted(missing))
        )
    collisions = {f"{target.symbol}_render", f"{target.symbol}_open"} & functions
    if collisions:
        raise MenuGraphError(
            f"menu target {target.name} generated functions collide with Bash: "
            + ", ".join(sorted(collisions))
        )


def generate_region(target: MenuTarget, graph: MenuGraph) -> str:
    symbol = target.symbol
    lines = [
        target.begin,
        f"# Generated from {graph.path.relative_to(ROOT)} by scripts/generate-menus.py.",
        "# Do not edit this region directly.",
        f"{symbol}_render() {{",
        '    local menu_id="$1" title target badge',
        f'    if declare -F {symbol}_prepare >/dev/null; then {symbol}_prepare "$menu_id"; fi',
        "    while true; do",
        "        local items=() targets=() badges=()",
        '        case "$menu_id" in',
    ]
    for menu in (node for node in graph.nodes.values() if node.kind == "menu"):
        lines.extend(
            [
                f"            {menu.id})",
                f'                title="{bash_double(graph.display_title(menu.id), target.templates)}"',
            ]
        )
        for choice in graph.choices(menu.id):
            lines.extend(
                [
                    f"                if ! badge=$({symbol}_badge {choice.id} {choice.style}); then badge=; fi",
                    "                if [[ \"$badge\" == *\"|\"* || \"$badge\" == *$'\\n'* ]]; then",
                    f'                    die "Invalid generated menu badge: {choice.id}"',
                    "                fi",
                    '                items+=("{}|${{badge}}|{}")'.format(
                        bash_double(choice.title, target.templates),
                        bash_double(choice.hint, target.templates),
                    ),
                    f'                targets+=("{choice.id}")',
                    '                badges+=("$badge")',
                ]
            )
        lines.append("                ;;")
    lines.extend(
        [
            f'            *) die "Unknown generated {target.name} menu ID: $menu_id" ;;',
            "        esac",
            '        if [[ "$title" == *"|"* || "$title" == *[[:cntrl:]]* ]]; then',
            f'            die "Invalid generated {target.name} menu title"',
            "        fi",
            '        menu_select "$title" "${items[@]}" || { echo; return 0; }',
            '        target=${targets[$MENU_CHOICE]}',
            '        if [[ "$target" == menu__* ]]; then',
            f'            {symbol}_render "$target"',
            "        else",
            f'            {symbol}_activate "$target" "${{badges[$MENU_CHOICE]}}"',
            "        fi",
            "    done",
            "}",
            "",
            f"{symbol}_open() {{",
            '    case "${1:-root}" in',
        ]
    )
    for entry_name, menu_id in target.entries:
        lines.append(f"        {entry_name}) {symbol}_render {menu_id} ;;")
    lines.extend(["        *) return 2 ;;", "    esac", "}", "", target.end])
    return "\n".join(lines)


def replace_region(source: str, target: MenuTarget, region: str) -> str:
    start, end = _marker_bounds(source, target)
    return source[:start] + region + source[end:]


def _atomic_write(path: Path, content: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="rewrite generated regions")
    mode.add_argument("--check", action="store_true", help="fail if generated code is stale")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    outputs = []
    for target in sorted(load_targets(), key=lambda item: item.name):
        source = target.bash_path.read_text(encoding="utf-8")
        graph = parse(target.graph_path)
        validate_target(target, graph, source)
        expected = replace_region(source, target, generate_region(target, graph))
        outputs.append((target, source, expected))

    stale = [target.name for target, source, expected in outputs if source != expected]
    if args.check:
        if stale:
            print(
                "Generated menus are stale for: " + ", ".join(stale) + ". Run "
                "'python3 scripts/generate-menus.py --write'.",
                file=sys.stderr,
            )
            return 1
        return 0
    for target, source, expected in outputs:
        if source != expected:
            _atomic_write(target.bash_path, expected)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MenuGraphError as error:
        print(f"menu generation failed: {error}", file=sys.stderr)
        raise SystemExit(2)
