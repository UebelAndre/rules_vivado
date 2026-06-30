# Toolchains

`rules_vivado` resolves the Xilinx Vivado install through Bazel
toolchain resolution. You declare a
[`vivado_toolchain`](./vivado_toolchain.md) that wraps a shell script
sourcing your install, wrap it in `toolchain(...)`, and register it
from `MODULE.bazel`. Every `vivado_*` rule then picks it up
automatically — there is no per-target `xilinx_env` to thread through.

Registering a toolchain is **required**: the per-rule `xilinx_env`
attribute is deprecated and emits an analysis-time warning if set.

## Implementing a toolchain

### 1. Write a Xilinx environment script

By convention this lives at `tools/vivado/xilinx_env.sh`, but anywhere
in the workspace works:

```bash
#!/usr/bin/env bash
set -e
export HOME=/tmp
source /opt/Xilinx/Vivado/2024.2/settings64.sh
export XILINXD_LICENSE_FILE=2100@license.example.com
```

For a node-locked `.lic` file on disk, replace
`XILINXD_LICENSE_FILE` with the file path and set
`requires_network = False` on the toolchain (see below).

### 2. Declare the toolchain

```python
load("@rules_vivado//vivado:toolchain.bzl", "vivado_toolchain")

vivado_toolchain(
    name = "vivado_local",
    xilinx_env = "xilinx_env.sh",
)

toolchain(
    name = "vivado_toolchain",
    toolchain = ":vivado_local",
    toolchain_type = "@rules_vivado//vivado:toolchain_type",
)
```

### 3. Register it

```python
register_toolchains("//tools/vivado:vivado_toolchain")
```

That's it — every `vivado_*` rule now resolves this toolchain.

## Network vs. node-locked licenses

`vivado_toolchain.requires_network` defaults to `True`, which is
correct for a floating/network license server
(`XILINXD_LICENSE_FILE=PORT@HOST`). It sets the `requires-network`
execution requirement on every `vivado_*` action.

Set it to `False` for license-free editions (Vivado ML Standard /
WebPACK) or for node-locked `.lic` files read from disk. Sandboxed and
remote-execution builds need network disabled to be reproducible
without the license server, so be deliberate here.

## Constraining toolchains

Register multiple `vivado_toolchain` instances side-by-side and let
Bazel pick one per action via `exec_compatible_with` against the
per-version `constraint_value`s in
[`//vivado/constraints/BUILD.bazel`](https://github.com/hw-bzl/rules_vivado/blob/main/vivado/constraints/BUILD.bazel).
Each constraint corresponds to one entry in `VIVADO_VERSIONS` (defined
in
[`//vivado/private:versions.bzl`](https://github.com/hw-bzl/rules_vivado/blob/main/vivado/private/versions.bzl)).

```python
load("@rules_vivado//vivado:toolchain.bzl", "vivado_toolchain")

vivado_toolchain(
    name = "vivado_2024_2",
    xilinx_env = "xilinx_env_2024_2.sh",
    version = "2024.2",
)

toolchain(
    name = "vivado_toolchain_2024_2",
    exec_compatible_with = ["@rules_vivado//vivado/constraints/version:2024.2"],
    toolchain = ":vivado_2024_2",
    toolchain_type = "@rules_vivado//vivado:toolchain_type",
)

platform(
    name = "vivado_2024_2_platform",
    constraint_values = ["@rules_vivado//vivado/constraints/version:2024.2"],
    exec_properties = {
        "container-image": "docker://your.registry/vivado:2024.2",
    },
    parents = ["@platforms//host"],
)
```

Register both from `MODULE.bazel`:

```python
register_toolchains("//tools/vivado:vivado_toolchain_2024_2")
register_execution_platforms("//tools/vivado:vivado_2024_2_platform")
```

The first registered exec platform is the default. Switch versions per
build with `--platforms=//tools/vivado:vivado_2024_2_platform`, which
also lets
`target_compatible_with = ["@rules_vivado//vivado/constraints/version:2024.2"]`
on a target evaluate against the right constraint
(incompatible-at-default, compatible-when-platform-pinned).

For per-target switching without a global flag, use a wrapper rule
with `cfg = transition(...)`; see
[`tests/transition.bzl`](https://github.com/hw-bzl/rules_vivado/blob/main/tests/transition.bzl)
for a `with_vivado_version` wrapper that takes a list of targets and
pins the version for the whole group.

Constraints are the only mechanism — there is no parallel build-setting
/ flag-driven path. This keeps per-version metadata (constraints,
`exec_properties` like `container-image`) all on the platform object
where it belongs and avoids the two-sources-of-truth problem.

## Reference

See [`vivado_toolchain`](./vivado_toolchain.md) for the full attribute
set and [`VivadoToolchainInfo`](./vivado_providers.md) for the
resolved provider that downstream rules consume.
