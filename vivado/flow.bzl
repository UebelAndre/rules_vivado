"""Starter recipe macro chaining the standard Vivado bitstream flow.

This macro covers the 80% case: synth → opt → place → place_opt → route →
write_bitstream against a single Verilog/VHDL library. Outgrow it as soon as
you need any of the following and you'll be happier composing the per-phase
rules directly:

- Versal device images (`.pdi`) instead of `.bit` — use `vivado_write_device_image`.
- Per-phase `pre_hooks` / `post_hooks` beyond the timing-gate (`post_route_hooks`)
  and bitstream-finalization (`post_bitstream_hooks`) hooks exposed here — every
  phase rule has its own full hook surface.
- Custom phase ordering, multi-strategy synthesis, fan-out for design-space
  exploration, signing pipelines, etc.

The per-phase rules — `vivado_synthesize`, `vivado_synthesis_optimize`,
`vivado_placement`, `vivado_place_optimize`, `vivado_routing`,
`vivado_write_bitstream`, `vivado_write_device_image` — are the real API; this
macro is sugar over the common case.
"""

load(":bitstream.bzl", "vivado_write_bitstream")
load(":implementation.bzl", "vivado_place_optimize", "vivado_placement", "vivado_routing")
load(":synthesis.bzl", "vivado_synthesis_optimize", "vivado_synthesize")

def vivado_flow(
        *,
        name,
        module,
        module_top,
        part_number,
        tags = [],
        ip_blocks = [],
        block_designs = [],
        with_xsa = False,
        post_route_hooks = [],
        post_bitstream_hooks = [],
        **kwargs):
    """Runs the standard Vivado bitstream flow as a convenience macro.

    The final phase always emits a legacy `.bit` via `vivado_write_bitstream`.
    For Versal device images (`.pdi`) compose `vivado_write_device_image`
    against the produced routing checkpoint directly — drop the macro at that
    point.

    Args:
        name: The name to use when calling the rules. The final `.bit` target
            is named `name`; intermediate phases are named `{name}_synth`,
            `{name}_synth_opt`, `{name}_placement`, `{name}_place_opt`,
            `{name}_route`.
        module: The verilog/vhdl library to use as the top level.
        module_top: The name of the top level module.
        part_number: The part number to target.
        tags: Optional tags to use for the rules.
        ip_blocks: Optional ip blocks to include in a design.
        block_designs: Optional `vivado_block_design` targets to fold into the synth project.
        with_xsa: Also generate the xsa file.
        post_route_hooks: TCL files sourced after route_design, before reports —
            the canonical place for timing/methodology gates that should fail
            the build. Forwarded to `vivado_routing`.
        post_bitstream_hooks: TCL files sourced after a successful
            `write_bitstream` — eFUSE, signing, BIF templating, etc. Forwarded
            to `vivado_write_bitstream`.
        **kwargs: Additional keyword arguments forwarded to every phase rule
            (e.g. `threads`, `jobs`, `vivado_version`). Avoid passing phase-
            specific knobs here — drop down to the phase rules instead.
    """
    vivado_synthesize(
        name = "{}_synth".format(name),
        module = module,
        module_top = module_top,
        part_number = part_number,
        tags = tags,
        ip_blocks = ip_blocks,
        block_designs = block_designs,
        **kwargs
    )

    vivado_synthesis_optimize(
        name = "{}_synth_opt".format(name),
        checkpoint = ":{}_synth".format(name),
        tags = tags,
        **kwargs
    )

    vivado_placement(
        name = "{}_placement".format(name),
        checkpoint = "{}_synth_opt".format(name),
        tags = tags,
        **kwargs
    )

    vivado_place_optimize(
        name = "{}_place_opt".format(name),
        checkpoint = "{}_placement".format(name),
        tags = tags,
        **kwargs
    )

    vivado_routing(
        name = "{}_route".format(name),
        checkpoint = "{}_place_opt".format(name),
        tags = tags,
        post_hooks = post_route_hooks,
        **kwargs
    )

    vivado_write_bitstream(
        name = name,
        checkpoint = "{}_route".format(name),
        tags = tags,
        with_xsa = with_xsa,
        post_hooks = post_bitstream_hooks,
        **kwargs
    )
