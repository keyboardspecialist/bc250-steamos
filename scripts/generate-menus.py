#!/usr/bin/env python3
"""Generate the toolkit's Bash menu loops from menus/toolkit.mmd."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from menu_graph import MenuGraph, MenuGraphError, parse


ROOT = Path(__file__).resolve().parents[1]
GRAPH_PATH = ROOT / "menus/toolkit.mmd"
TOOLKIT_PATH = ROOT / "bc250-toolkit.sh"
BEGIN = "# BEGIN GENERATED TOOLKIT MENUS"
END = "# END GENERATED TOOLKIT MENUS"
TEMPLATE_RE = re.compile(r"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}")
FUNCTION_RE = re.compile(
    r"^[ \t]*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*\{",
    re.MULTILINE,
)
BASH_RESERVED = {
    "case",
    "coproc",
    "do",
    "done",
    "elif",
    "else",
    "esac",
    "fi",
    "for",
    "function",
    "if",
    "in",
    "select",
    "then",
    "time",
    "until",
    "while",
}


def bash_double(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("`", "\\`")
        .replace("$", "\\$")
    )
    variables = set(TEMPLATE_RE.findall(value))
    unknown = variables - {"TOOLKIT_VERSION"}
    if unknown:
        raise MenuGraphError("unknown title template: " + ", ".join(sorted(unknown)))
    escaped = TEMPLATE_RE.sub(lambda match: "${" + match.group(1) + "}", escaped)
    return escaped


def generated_wrapper_names(graph: MenuGraph) -> dict[str, str]:
    return {
        node.id: node.id.split("__", 1)[1]
        for node in graph.nodes.values()
        if node.kind == "menu"
    }


def source_without_generated_region(source: str) -> str:
    if BEGIN in source or END in source:
        if source.count(BEGIN) != 1 or source.count(END) != 1:
            raise MenuGraphError("generated menu markers are incomplete or duplicated")
        start = source.index(BEGIN)
        end = source.index(END, start) + len(END)
        return source[:start] + source[end:]
    start_marker = "cmd_guided_setup_menu() {"
    end_marker = "cmd_help() {"
    if start_marker in source or end_marker in source:
        if source.count(start_marker) != 1 or source.count(end_marker) != 1:
            raise MenuGraphError("original menu function markers are incomplete or duplicated")
        start = source.index(start_marker)
        end = source.index(end_marker, start)
        return source[:start] + source[end:]
    return source


def validate_wrapper_names(graph: MenuGraph, toolkit_source: str) -> None:
    invalid = sorted(
        function
        for function in generated_wrapper_names(graph).values()
        if not function.startswith("cmd_")
    )
    if invalid:
        raise MenuGraphError(
            "generated menu functions must use cmd_ names: " + ", ".join(invalid)
        )
    reserved = set(FUNCTION_RE.findall(source_without_generated_region(toolkit_source)))
    reserved.add("menu_graph_render")
    reserved.update(BASH_RESERVED)
    collisions = sorted(
        function
        for function in generated_wrapper_names(graph).values()
        if function in reserved
    )
    if collisions:
        raise MenuGraphError(
            "generated menu function collides with existing Bash: "
            + ", ".join(collisions)
        )


def generate_region(graph: MenuGraph) -> str:
    menus = [node for node in graph.nodes.values() if node.kind == "menu"]
    lines = [
        BEGIN,
        "# Generated from menus/toolkit.mmd by scripts/generate-menus.py.",
        "# Do not edit this region directly.",
        "menu_graph_render() {",
        '    local menu_id="$1" title target',
        "    while true; do",
        "        local items=() targets=()",
        '        case "$menu_id" in',
    ]
    for menu in menus:
        lines.extend(
            [
                f"            {menu.id})",
                f'                title="{bash_double(menu.title)}"',
            ]
        )
        for choice in graph.choices(menu.id):
            lines.append(
                '                items+=("{}|$(menu_graph_badge {} {})|{}")'.format(
                    bash_double(choice.title), choice.id, choice.style, bash_double(choice.hint)
                )
            )
            lines.append(f'                targets+=("{choice.id}")')
        lines.append("                ;;")
    lines.extend(
        [
            '            *) die "Unknown generated menu ID: $menu_id" ;;',
            "        esac",
            '        menu_select "$title" "${items[@]}" || { echo; return 0; }',
            '        target=${targets[$MENU_CHOICE]}',
            '        if [[ "$target" == menu__* ]]; then',
            '            menu_graph_render "$target"',
            "        else",
            '            menu_graph_activate "$target"',
            "        fi",
            "    done",
            "}",
            "",
        ]
    )
    for menu in menus:
        function = menu.id.split("__", 1)[1]
        lines.extend(
            [
                f"{function}() {{",
                "    require_terminal",
                "    require_normal_user",
            ]
        )
        if menu.style == "root":
            lines.append("    start_sudo_session")
        lines.extend([f"    menu_graph_render {menu.id}", "}", ""])
    lines.append(END)
    return "\n".join(lines)


def replace_region(source: str, region: str) -> str:
    if BEGIN in source or END in source:
        if source.count(BEGIN) != 1 or source.count(END) != 1:
            raise MenuGraphError("generated menu markers are incomplete or duplicated")
        start = source.index(BEGIN)
        end = source.index(END, start) + len(END)
        return source[:start] + region + source[end:]

    start_marker = "cmd_guided_setup_menu() {"
    end_marker = "cmd_help() {"
    if start_marker not in source or end_marker not in source:
        raise MenuGraphError("could not locate the original toolkit menu functions")
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[:start] + region + "\n\n" + source[end:]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="rewrite the generated region")
    mode.add_argument("--check", action="store_true", help="fail if generated code is stale")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source = TOOLKIT_PATH.read_text(encoding="utf-8")
    graph = parse(GRAPH_PATH)
    validate_wrapper_names(graph, source)
    expected = replace_region(source, generate_region(graph))
    if args.write:
        TOOLKIT_PATH.write_text(expected, encoding="utf-8")
        return 0
    if source != expected:
        print(
            "Generated toolkit menus are stale; run "
            "'python3 scripts/generate-menus.py --write'.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MenuGraphError as error:
        print(f"menu generation failed: {error}", file=sys.stderr)
        raise SystemExit(2)
