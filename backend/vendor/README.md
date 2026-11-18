# Vendored Python fallback

`tomli` **2.5.0** comes from the upstream pure-Python wheel; source files are unchanged.
It supports Python >=3.8; newer Python normally uses the standard `tomllib`.
The Decky and desktop-service packagers include its metadata and MIT license.

- Source: <https://pypi.org/project/tomli/2.5.0/>
- Artifact: `tomli-2.5.0-py3-none-any.whl`
- SHA-256: `32a7b79ac57a2e83670ce329ccf675798bc5a2094783a63676866b70503f2e2b`

Only the five `tomli/` source/type-marker files and the wheel's `METADATA` and
`licenses/LICENSE` are vendored. Wheel installation bookkeeping is omitted.
The extra final blank line in `METADATA` is removed for repository whitespace checks.
