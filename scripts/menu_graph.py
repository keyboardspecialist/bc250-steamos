#!/usr/bin/env python3
"""Strict parser and validator for the toolkit's Mermaid menu-flow subset."""

from __future__ import annotations

import html
import re
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path


MARKER = "%% menu-flow-v1"
STYLES = {
    "root",
    "menu",
    "entry",
    "install",
    "read_only",
    "advanced",
    "cleanup",
    "experimental",
    "hardware_specific",
}
NODE_RE = re.compile(
    r'^([a-z][a-z0-9_]*)\["([^"\n]+)"\]:::'
    r'(root|menu|entry|install|read_only|advanced|cleanup|experimental|hardware_specific)$'
)
NAV_RE = re.compile(r"^([a-z][a-z0-9_]*)\s+-->\s+([a-z][a-z0-9_]*)$")
DEPENDENCY_RE = re.compile(r"^([a-z][a-z0-9_]*)\s+-\.->\s+([a-z][a-z0-9_]*)$")
ID_RE = re.compile(r"^(menu|action|child)__[a-z][a-z0-9_]*$")
CLASS_DEF_RE = re.compile(r"^classDef ([a-z_]+) (.+)$")
CLASS_PROPERTY_RE = re.compile(r"^[a-z][a-z-]*:[#a-zA-Z0-9]+(?: [#a-zA-Z0-9]+)*$")
MENU_TITLE_RE = re.compile(r'^%% menu-title ([a-z][a-z0-9_]*) "([^"\n]+)"$')


class MenuGraphError(ValueError):
    pass


@dataclass(frozen=True)
class Node:
    id: str
    title: str
    hint: str
    style: str
    line: int

    @property
    def kind(self) -> str:
        return self.id.split("__", 1)[0]


@dataclass(frozen=True)
class Edge:
    source: str
    target: str
    dependency: bool
    line: int


@dataclass(frozen=True)
class MenuGraph:
    path: Path
    nodes: dict[str, Node]
    edges: tuple[Edge, ...]
    menu_titles: dict[str, str]

    @property
    def root(self) -> Node:
        roots = [node for node in self.nodes.values() if node.style == "root"]
        return roots[0]

    def choices(self, menu_id: str) -> list[Node]:
        return [
            self.nodes[edge.target]
            for edge in self.edges
            if not edge.dependency and edge.source == menu_id
        ]

    def display_title(self, menu_id: str) -> str:
        return self.menu_titles.get(menu_id, self.nodes[menu_id].title)

    def navigation(self) -> dict[str, list[str]]:
        result = {node_id: [] for node_id in self.nodes}
        for edge in self.edges:
            if not edge.dependency:
                result[edge.source].append(edge.target)
        return result

    def dependencies(self) -> dict[str, list[str]]:
        result = {node_id: [] for node_id in self.nodes}
        for edge in self.edges:
            if edge.dependency:
                result[edge.source].append(edge.target)
        return result


def _cycles(graph: dict[str, list[str]]) -> list[list[str]]:
    cycles: list[list[str]] = []
    state = {node: 0 for node in graph}
    stack: list[str] = []

    def visit(node: str) -> None:
        state[node] = 1
        stack.append(node)
        for target in graph[node]:
            if state[target] == 0:
                visit(target)
            elif state[target] == 1:
                start = stack.index(target)
                cycles.append(stack[start:] + [target])
        stack.pop()
        state[node] = 2

    for node in graph:
        if state[node] == 0:
            visit(node)
    return cycles


def reachable(graph: MenuGraph) -> dict[str, int]:
    adjacency = graph.navigation()
    depths = {graph.root.id: 0}
    queue = deque([graph.root.id])
    while queue:
        node = queue.popleft()
        for target in adjacency[node]:
            if target not in depths:
                depths[target] = depths[node] + 1
                queue.append(target)
    return depths


def validate(graph: MenuGraph) -> None:
    roots = [node for node in graph.nodes.values() if node.style == "root"]
    if len(roots) != 1:
        raise MenuGraphError("the graph must define exactly one :::root node")
    if roots[0].kind != "menu":
        raise MenuGraphError("the root node must use a menu__ ID")
    for menu_id in graph.menu_titles:
        if menu_id not in graph.nodes or graph.nodes[menu_id].kind != "menu":
            raise MenuGraphError(f"menu title target is not a menu: {menu_id}")

    navigation = graph.navigation()
    dependencies = graph.dependencies()
    seen_edges: set[tuple[str, str, bool]] = set()
    for edge in graph.edges:
        key = (edge.source, edge.target, edge.dependency)
        if key in seen_edges:
            kind = "dependency" if edge.dependency else "navigation"
            raise MenuGraphError(
                f"duplicate {kind} edge at line {edge.line}: "
                f"{edge.source} -> {edge.target}"
            )
        seen_edges.add(key)

    for node in graph.nodes.values():
        if node.kind == "menu" and not navigation[node.id]:
            raise MenuGraphError(f"menu has no choices: {node.id}")
        if node.kind != "menu" and navigation[node.id]:
            raise MenuGraphError(f"only menu nodes may contain choices: {node.id}")
        if node.style == "entry" and node.kind != "menu":
            raise MenuGraphError(f"only menu nodes may use :::entry: {node.id}")
    if any(edge.target == roots[0].id for edge in graph.edges if not edge.dependency):
        raise MenuGraphError("navigation into the root menu is not allowed")

    nav_cycles = _cycles(navigation)
    if nav_cycles:
        raise MenuGraphError("navigation cycle: " + " -> ".join(nav_cycles[0]))
    dependency_cycles = _cycles(dependencies)
    if dependency_cycles:
        raise MenuGraphError("dependency cycle: " + " -> ".join(dependency_cycles[0]))

    covered = set(reachable(graph))
    for entry in (node for node in graph.nodes.values() if node.style == "entry"):
        queue = deque([entry.id])
        while queue:
            current = queue.popleft()
            if current in covered:
                continue
            covered.add(current)
            queue.extend(navigation[current])

    unreachable = [
        node.id
        for node in graph.nodes.values()
        if node.id not in covered
    ]
    if unreachable:
        raise MenuGraphError(
            "nodes are unreachable from root or an entry menu: " + ", ".join(unreachable)
        )


def parse(path: Path) -> MenuGraph:
    source = path.read_text(encoding="utf-8")
    nodes: dict[str, Node] = {}
    edges: list[Edge] = []
    class_defs: set[str] = set()
    menu_titles: dict[str, str] = {}
    saw_marker = False
    saw_header = False

    for line_number, raw_line in enumerate(source.splitlines(), 1):
        line = raw_line.strip()
        if not line:
            continue
        if line == MARKER:
            saw_marker = True
            continue
        if line == "flowchart TD":
            saw_header = True
            continue
        if line.startswith("%% menu-title"):
            title_match = MENU_TITLE_RE.fullmatch(line)
            if not title_match:
                raise MenuGraphError(
                    f"{path}:{line_number}: malformed menu-title directive"
                )
            menu_id, raw_title = title_match.groups()
            if menu_id in menu_titles:
                raise MenuGraphError(
                    f"{path}:{line_number}: duplicate menu-title: {menu_id}"
                )
            title = html.unescape(raw_title)
            if "|" in title or any(
                ord(character) < 32 or ord(character) == 127 for character in title
            ):
                raise MenuGraphError(
                    f"{path}:{line_number}: menu titles cannot contain delimiters or control characters"
                )
            if any(token in title for token in ("$(", "${", "`", "\x1b")):
                raise MenuGraphError(f"{path}:{line_number}: shell syntax is not allowed")
            menu_titles[menu_id] = title
            continue
        if line.startswith("%%"):
            continue
        if line.startswith("classDef "):
            class_match = CLASS_DEF_RE.fullmatch(line)
            if not class_match:
                raise MenuGraphError(
                    f"{path}:{line_number}: malformed classDef declaration"
                )
            style, raw_properties = class_match.groups()
            properties = raw_properties.split(",")
            if style not in STYLES or not all(
                CLASS_PROPERTY_RE.fullmatch(item) for item in properties
            ):
                raise MenuGraphError(
                    f"{path}:{line_number}: unsupported classDef declaration"
                )
            if style in class_defs:
                raise MenuGraphError(
                    f"{path}:{line_number}: duplicate classDef: {style}"
                )
            class_defs.add(style)
            continue

        node_match = NODE_RE.fullmatch(line)
        if node_match:
            node_id, raw_label, style = node_match.groups()
            if not ID_RE.fullmatch(node_id):
                raise MenuGraphError(f"{path}:{line_number}: invalid node ID: {node_id}")
            if node_id in nodes:
                raise MenuGraphError(f"{path}:{line_number}: duplicate node ID: {node_id}")
            parts = raw_label.split("<br/>")
            if len(parts) != 2 or not all(parts):
                raise MenuGraphError(
                    f"{path}:{line_number}: node labels must be Title<br/>Hint"
                )
            title, hint = (html.unescape(part) for part in parts)
            if any(
                "|" in value
                or any(
                    ord(character) < 32 or ord(character) == 127
                    for character in value
                )
                for value in (title, hint)
            ):
                raise MenuGraphError(
                    f"{path}:{line_number}: labels cannot contain menu delimiters or control characters"
                )
            if any(token in title + hint for token in ("$(", "${", "`", "\x1b")):
                raise MenuGraphError(f"{path}:{line_number}: shell syntax is not allowed")
            nodes[node_id] = Node(node_id, title, hint, style, line_number)
            continue

        edge_match = NAV_RE.fullmatch(line)
        dependency = False
        if not edge_match:
            edge_match = DEPENDENCY_RE.fullmatch(line)
            dependency = edge_match is not None
        if edge_match:
            edges.append(
                Edge(edge_match.group(1), edge_match.group(2), dependency, line_number)
            )
            continue
        raise MenuGraphError(f"{path}:{line_number}: unsupported Mermaid syntax: {line}")

    if not saw_marker:
        raise MenuGraphError(f"{path}: missing {MARKER}")
    if not saw_header:
        raise MenuGraphError(f"{path}: expected 'flowchart TD'")
    for edge in edges:
        if edge.source not in nodes or edge.target not in nodes:
            raise MenuGraphError(
                f"{path}:{edge.line}: unresolved edge: {edge.source} -> {edge.target}"
            )
    graph = MenuGraph(path, nodes, tuple(edges), menu_titles)
    validate(graph)
    return graph


def grouped_incoming(graph: MenuGraph) -> dict[str, list[str]]:
    incoming: dict[str, list[str]] = defaultdict(list)
    for edge in graph.edges:
        if not edge.dependency:
            incoming[edge.target].append(edge.source)
    return incoming
