"""Legacy convenience macro chaining synth → opt → place → place_opt → route → write_bitstream.

Compose the per-phase rules directly for anything beyond this default flow.
"""

load(":bitstream.bzl", "vivado_write_bitstream")
load(":implementation.bzl", "vivado_place_optimize", "vivado_placement", "vivado_routing")
load(":synthesis.bzl", "vivado_synthesis_optimize", "vivado_synthesize")

_UNSET = struct()

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
        jobs = _UNSET,
        threads = _UNSET,
        **kwargs):
    """Runs the standard Vivado bitstream flow as a convenience macro.

    The final phase emits a legacy `.bit` via `vivado_write_bitstream`. For
    Versal `.pdi` output, compose `vivado_write_device_image` directly.

    Args:
        name: Final `.bit` target name; intermediate phases are `{name}_synth`,
            `{name}_synth_opt`, `{name}_placement`, `{name}_place_opt`,
            `{name}_route`.
        module: The verilog/vhdl library to use as the top level.
        module_top: The name of the top level module.
        part_number: The part number to target.
        tags: Optional tags to use for the rules.
        ip_blocks: Optional ip blocks to include in a design.
        block_designs: Optional `vivado_block_design` targets to fold into the synth project.
        with_xsa: Also generate the xsa file.
        post_route_hooks: TCL files sourced after route_design; forwarded to `vivado_routing`.
        post_bitstream_hooks: TCL files sourced after `write_bitstream`; forwarded to `vivado_write_bitstream`.
        jobs: Forwarded only to `vivado_synthesize` (its `-jobs` for OOC IP runs);
            other phase rules have no `jobs` attr.
        threads: `general.maxThreads` for every non-synthesize phase; not forwarded
            to `vivado_synthesize`.
        **kwargs: Forwarded to every phase rule. Do NOT put `threads` / `jobs` here
            — they'd break load-time on rules that don't expose them.
    """
    synth_kwargs = dict(kwargs)
    if jobs != _UNSET:
        synth_kwargs["jobs"] = jobs
    post_synth_kwargs = dict(kwargs)
    if threads != _UNSET:
        post_synth_kwargs["threads"] = threads

    vivado_synthesize(
        name = "{}_synth".format(name),
        module = module,
        module_top = module_top,
        part_number = part_number,
        tags = tags,
        ip_blocks = ip_blocks,
        block_designs = block_designs,
        **synth_kwargs
    )

    vivado_synthesis_optimize(
        name = "{}_synth_opt".format(name),
        checkpoint = ":{}_synth".format(name),
        tags = tags,
        **post_synth_kwargs
    )

    vivado_placement(
        name = "{}_placement".format(name),
        checkpoint = "{}_synth_opt".format(name),
        tags = tags,
        **post_synth_kwargs
    )

    vivado_place_optimize(
        name = "{}_place_opt".format(name),
        checkpoint = "{}_placement".format(name),
        tags = tags,
        **post_synth_kwargs
    )

    vivado_routing(
        name = "{}_route".format(name),
        checkpoint = "{}_place_opt".format(name),
        tags = tags,
        post_hooks = post_route_hooks,
        **post_synth_kwargs
    )

    vivado_write_bitstream(
        name = name,
        checkpoint = "{}_route".format(name),
        tags = tags,
        with_xsa = with_xsa,
        post_hooks = post_bitstream_hooks,
        **post_synth_kwargs
    )
