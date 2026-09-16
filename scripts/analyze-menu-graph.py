#!/usr/bin/env python3
"""Analyze canonical Mermaid menu graphs."""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict, deque
from dataclasses import asdict

from menu_graph import MenuGraph, MenuGraphError, grouped_incoming, parse, reachable
from menu_targets import MenuTarget, load_targets


def cycles(adjacency: dict[str, list[str]]) -> list[list[str]]:
    result: list[list[str]] = []
    state = {node: 0 for node in adjacency}
    stack: list[str] = []

    def visit(node: str) -> None:
        state[node] = 1
        stack.append(node)
        for target in adjacency[node]:
            if state[target] == 0:
                visit(target)
            elif state[target] == 1:
                start = stack.index(target)
                result.append(stack[start:] + [target])
        stack.pop()
        state[node] = 2

    for node in adjacency:
        if state[node] == 0:
            visit(node)
    return result


def shortest_paths_from(
    graph: MenuGraph, start: str
) -> tuple[dict[str, int], dict[str, str | None]]:
    adjacency = graph.navigation()
    depths = {start: 0}
    parents: dict[str, str | None] = {start: None}
    queue = deque([start])
    while queue:
        node = queue.popleft()
        for target in adjacency[node]:
            if target not in depths:
                depths[target] = depths[node] + 1
                parents[target] = node
                queue.append(target)
    return depths, parents


def shortest_paths(graph: MenuGraph) -> tuple[dict[str, int], dict[str, str | None]]:
    return shortest_paths_from(graph, graph.root.id)


def supported_entry_paths(
    graph: MenuGraph,
) -> list[tuple[str, dict[str, int], dict[str, str | None]]]:
    starts = [graph.root.id]
    starts.extend(node.id for node in graph.nodes.values() if node.style == "entry")
    return [(start, *shortest_paths_from(graph, start)) for start in starts]


def longest_path(graph: MenuGraph) -> list[str]:
    adjacency = graph.navigation()
    memo: dict[str, list[str]] = {}

    def walk(node: str) -> list[str]:
        if node not in memo:
            tails = [walk(target) for target in adjacency[node]]
            memo[node] = [node] + (max(tails, key=len) if tails else [])
        return memo[node]

    return max((walk(node) for node in graph.nodes), key=len)


def detour_edges(graph: MenuGraph, depths: dict[str, int]):
    return sorted(
        (
            edge
            for edge in graph.edges
            if not edge.dependency
            and edge.source in depths
            and edge.target in depths
            and depths[edge.target] < depths[edge.source] + 1
        ),
        key=lambda edge: (graph.nodes[edge.source].title, graph.nodes[edge.target].title),
    )


def supported_detour_edges(
    graph: MenuGraph,
    entry_paths: list[tuple[str, dict[str, int], dict[str, str | None]]],
):
    detours = {
        (edge.source, edge.target): edge
        for _, depths, _ in entry_paths
        for edge in detour_edges(graph, depths)
    }
    return sorted(
        detours.values(),
        key=lambda edge: (graph.nodes[edge.source].title, graph.nodes[edge.target].title),
    )


def path_to(node: str, parents: dict[str, str | None]) -> list[str]:
    path = []
    current: str | None = node
    while current is not None:
        path.append(current)
        current = parents[current]
    return list(reversed(path))


def display_path(graph: MenuGraph, path: list[str]) -> str:
    return " -> ".join(
        graph.nodes[node].title.replace("{{TOOLKIT_VERSION}}", "version")
        for node in path
    )


def report(graph: MenuGraph, depth_budget: int, name: str = "Toolkit") -> str:
    navigation = graph.navigation()
    depths, _ = shortest_paths(graph)
    entry_paths = supported_entry_paths(graph)
    _, deepest_depths, deepest_parents = max(
        entry_paths, key=lambda item: max(item[1].values())
    )
    longest = longest_path(graph)
    deepest = max(deepest_depths, key=deepest_depths.get)
    incoming = grouped_incoming(graph)
    shared = sorted(
        (node for node, sources in incoming.items() if len(set(sources)) > 1),
        key=lambda node: (-len(set(incoming[node])), graph.nodes[node].title),
    )
    edge_groups: dict[tuple[str, str], list[str]] = defaultdict(list)
    for edge in graph.edges:
        if not edge.dependency:
            edge_groups[(edge.source, edge.target)].append(graph.nodes[edge.target].title)
    parallel = [item for item, labels in edge_groups.items() if len(labels) > 1]
    detours = supported_detour_edges(graph, entry_paths)
    unreachable = sorted(
        (node for node in graph.nodes if node not in depths),
        key=lambda node: graph.nodes[node].title,
    )
    over_budget = sorted(
        (
            (start, node, depth)
            for start, entry_depths, _ in entry_paths
            for node, depth in entry_depths.items()
            if depth > depth_budget
        ),
        key=lambda item: (item[2], graph.nodes[item[0]].title, graph.nodes[item[1]].title),
    )
    navigation_edges = [edge for edge in graph.edges if not edge.dependency]
    dependency_edges = [edge for edge in graph.edges if edge.dependency]
    selectable_nodes = {edge.target for edge in navigation_edges}

    lines = [
        f"{name} menu graph analysis",
        "=" * (len(name) + 20),
        f"Menus: {sum(node.kind == 'menu' for node in graph.nodes.values())}",
        f"Selectable nodes: {len(selectable_nodes)}",
        f"Navigation links: {len(navigation_edges)}",
        f"Dependency links: {len(dependency_edges)}",
        f"Reachable from main menu: {len(depths)}",
        f"Cycles: {len(cycles(navigation))}",
        f"Deepest shortest route: {deepest_depths[deepest]} links",
        f"Longest DAG route: {len(longest) - 1} links",
        "",
        "Cycles: none (Back/Q navigation is intentionally excluded).",
        "",
        "Deepest shortest route:",
        f"  {display_path(graph, path_to(deepest, deepest_parents))}",
        "",
        "Longest route:",
        f"  {display_path(graph, longest)}",
        "",
        f"Beyond depth budget ({depth_budget} links): {len(over_budget)}",
    ]
    for start, node, depth in over_budget:
        lines.append(
            f"  - from {graph.nodes[start].title}, depth {depth}: {graph.nodes[node].title}"
        )
    lines.extend(["", f"Shared destinations (multiple parents): {len(shared)}"])
    for node in shared:
        parent_titles = ", ".join(
            sorted({graph.nodes[parent].title for parent in incoming[node]})
        )
        lines.append(f"  - {graph.nodes[node].title} <- {parent_titles}")
    lines.extend(["", f"Parallel choices to the same destination: {len(parallel)}"])
    lines.extend(
        ["", f"Detour links (a shorter supported-entry route exists): {len(detours)}"]
    )
    for edge in detours:
        lines.append(
            f"  - {graph.nodes[edge.source].title} --> {graph.nodes[edge.target].title}"
        )
    lines.extend(["", f"Not reachable from main menu: {len(unreachable)}"])
    for node in unreachable:
        menu = graph.nodes[node]
        lines.append(f"  - {menu.title} ({menu.style}, line {menu.line})")
    return "\n".join(lines) + "\n"


def dot(graph: MenuGraph) -> str:
    def quote(value: str) -> str:
        return json.dumps(value)

    lines = ["digraph toolkit_menus {", "  rankdir=LR;"]
    for node in graph.nodes.values():
        lines.append(f"  {quote(node.id)} [label={quote(node.title)}];")
    for edge in graph.edges:
        attributes = " [style=dashed]" if edge.dependency else ""
        lines.append(f"  {quote(edge.source)} -> {quote(edge.target)}{attributes};")
    lines.append("}")
    return "\n".join(lines) + "\n"


def json_output(graph: MenuGraph) -> str:
    depths = reachable(graph)
    nodes = []
    for node in graph.nodes.values():
        serialized = asdict(node)
        serialized["kind"] = node.kind
        serialized["depth"] = depths.get(node.id)
        nodes.append(serialized)
    payload = {
        "root": graph.root.id,
        "nodes": nodes,
        "edges": [asdict(edge) for edge in graph.edges],
        "cycles": cycles(graph.navigation()),
    }
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--format", choices=("report", "mermaid", "dot", "json"), default="report"
    )
    parser.add_argument(
        "--depth-budget",
        type=int,
        default=4,
        help="fail/report routes exceeding this many links (default: 4)",
    )
    parser.add_argument("--target", help="analyze one configured menu target")
    parser.add_argument("--check", action="store_true", help="enforce graph policy")
    return parser.parse_args()


def graph_violates_policy(graph: MenuGraph, depth_budget: int) -> bool:
    entry_paths = supported_entry_paths(graph)
    violates_depth = any(
        depth > depth_budget
        for _, entry_depths, _ in entry_paths
        for depth in entry_depths.values()
    )
    return violates_depth or bool(supported_detour_edges(graph, entry_paths))


def render_target(target: MenuTarget, graph: MenuGraph, args: argparse.Namespace) -> str:
    if args.format == "report":
        return report(graph, args.depth_budget, target.name)
    if args.format == "mermaid":
        return target.graph_path.read_text(encoding="utf-8")
    if args.format == "dot":
        return dot(graph)
    return json_output(graph)


def main() -> int:
    args = parse_args()
    targets = load_targets()
    if args.target:
        targets = tuple(target for target in targets if target.name == args.target)
        if not targets:
            raise MenuGraphError(f"unknown menu target: {args.target}")
    elif args.format != "report":
        raise MenuGraphError("--target is required for non-report output")

    failed = False
    outputs = []
    for target in sorted(targets, key=lambda item: item.name):
        graph = parse(target.graph_path)
        outputs.append(render_target(target, graph, args))
        failed = failed or graph_violates_policy(graph, args.depth_budget)
    sys.stdout.write("\n".join(output.rstrip("\n") for output in outputs) + "\n")
    return 1 if args.check and failed else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MenuGraphError as error:
        print(f"menu graph invalid: {error}", file=sys.stderr)
        raise SystemExit(2)
