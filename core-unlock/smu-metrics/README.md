# BC-250 Eight-Core Metrics Injector

This production-only payload widens the Robin 1/3 SMU metrics table after boot
and enables the matching `amdgpu` decoder. It targets SMU firmware `0.58.6.0`.
The service refuses other firmware revisions, non-BC-250 hardware, systems
without eight active physical cores, and driver builds without revision
`smu-8core-metrics-r1`.

`metrics-8core.hex` contains only the metrics changes. The paired
`metrics-8core-original.hex` records the expected original bytes at every patch
site, allowing fail-closed live validation without shipping a firmware image.
The research RPC payload is not included.

The injector is installed and enabled by `bc250-power.sh cpu-unlock
metrics-enable`. It leaves the stock decoder selected until every SMU write and
readback check succeeds.
