# Menu Sources

Each `.mmd` file is the canonical source for one toolkit or standalone component
menu. `targets.json` maps those graphs to Bash targets and generated entry
points. See [`../MENU-GRAPH.md`](../MENU-GRAPH.md) for the supported syntax,
generation commands, and validation policy.

Generated Bash is committed inline in each target so packaged runtimes do not
need Python, Mermaid, or an additional sourced file.
