# Rules

Every public rule in `rules_vivado`, grouped by the build phase it
belongs to. All of them resolve their Xilinx install through a
registered [`vivado_toolchain`](./toolchains.md).

## Project setup

- [`vivado_create_project`](./vivado_project.md) — emit a Vivado
  project without running synthesis (useful for IDE handoff).

## Synthesis

- [`vivado_synthesize`](./vivado_synthesis.md) — run synthesis from an
  HDL library and produce a synthesis checkpoint (`.dcp`).
- [`vivado_synthesis_optimize`](./vivado_synthesis.md) — post-synthesis
  optimization pass on a synthesis checkpoint.

## Implementation

- [`vivado_placement`](./vivado_implementation.md) — placement on a
  synthesis checkpoint.
- [`vivado_place_optimize`](./vivado_implementation.md) —
  post-placement optimization on a placement checkpoint.
- [`vivado_routing`](./vivado_implementation.md) — routing on a
  placement checkpoint.

## Bitstream

- [`vivado_write_bitstream`](./vivado_bitstream.md) — emit the final
  `.bit` (and optionally `.xsa`) from a routing checkpoint.

## End-to-end flow

- `vivado_flow` — convenience macro (loaded from
  `@rules_vivado//vivado:defs.bzl`) that chains synthesis → opt →
  placement → place-opt → routing → bitstream into one target name.
  See the [Quick start](./index.md#quick-start) for a worked example.

## IP packaging

- [`vivado_create_ip`](./vivado_ip.md) — package an HDL module as a
  Vivado IP core.
- [`vivado_interface_definition`](./vivado_ip.md) — generate IP-XACT
  bus + abstraction definitions from a SystemVerilog interface.
- [`vivado_create_interface_ip`](./vivado_ip.md) — register an
  interface definition as an IP catalog entry so block designs can
  use it.

## Simulation

- [`xsim_test`](./vivado_simulation.md) — run a Vivado XSim
  simulation as a Bazel `test` target.

## Toolchain

- [`vivado_toolchain`](./vivado_toolchain.md) — declare a Vivado
  install for toolchain resolution. See
  [Toolchains](./toolchains.md) for the full workflow.

## Providers

- [`VivadoToolchainInfo` and friends](./vivado_providers.md) — the
  providers passed between phases (`VivadoSynthCheckpointInfo`,
  `VivadoPlacementCheckpointInfo`, `VivadoRoutingCheckpointInfo`,
  `VivadoIPBlockInfo`, `VivadoInterfaceInfo`).
