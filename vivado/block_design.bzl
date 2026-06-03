"""Block-design rule: vivado_block_design.

Wraps a user-authored Tcl script (typically `create_bd_design "name"` →
add/connect cells → `save_bd_design`) into a Bazel target that produces a
consumable `.bd` file plus its generated synth/sim products. Downstream
`vivado_synthesize` / `vivado_create_project` targets reference it via their
`block_designs` attribute.
"""

load("//vivado:providers.bzl", "VivadoBlockDesignInfo", "VivadoIPBlockInfo")
load(
    "//vivado/private:common.bzl",
    "TOOLCHAIN_TYPE",
    "file_list",
    "ip_blocks_data",
    "run_tcl_template",
)

def _vivado_block_design_impl(ctx):
    bd_dir = ctx.actions.declare_directory(ctx.label.name)

    pre_hooks_list, pre_hook_files = file_list(ctx.attr.pre_hooks)
    post_hooks_list, post_hook_files = file_list(ctx.attr.post_hooks)
    ip = ip_blocks_data(ctx.attr.ip_blocks)

    substitutions = {
        "{{BD_DIR}}": bd_dir.path,
        "{{BD_SRC}}": ctx.file.src.path,
        "{{IP_CONFIGURED_INSTANCES}}": ip.ip_configured_instances,
        "{{IP_INSTANCES}}": ip.ip_instances,
        "{{IP_REPOS}}": ip.ip_repos,
        "{{MODULE_TOP}}": ctx.attr.module_top,
        "{{PART_NUMBER}}": ctx.attr.part_number,
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
    }

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.block_design_template,
        substitutions = substitutions,
        input_files = [ctx.file.src] + ip.input_files + pre_hook_files + post_hook_files,
        output_files = [bd_dir],
        mnemonic = "VivadoBlockDesign",
        jobs = ctx.attr.jobs,
    )

    return [
        DefaultInfo(
            files = depset(result.outputs),
        ),
        VivadoBlockDesignInfo(
            bd_dir = bd_dir,
            ip_block_repos = ip.input_files,
            module_top = ctx.attr.module_top,
        ),
        coverage_common.instrumented_files_info(
            ctx,
            dependency_attributes = ["ip_blocks"],
        ),
    ]

vivado_block_design = rule(
    doc = """Build a Vivado block design (.bd) from a user-authored Tcl script.

The `src` Tcl is sourced inside a fresh Vivado project; it must call
`create_bd_design "<module_top>"`, add/connect cells, and end with
`save_bd_design`. The resulting `.bd` is normalized to
`<bd_dir>/<module_top>.bd` so consumers can reference it predictably.

Use the `block_designs` attribute on `vivado_synthesize`,
`vivado_create_project`, or `vivado_flow` to fold this BD into a synth
project; the synth template's existing BD loop will pick it up and run
`generate_target all` + `create_ip_run` automatically.

Block designs may reference packaged IP via the `ip_blocks` attribute; those
IP repos are propagated to consumers so the synth project's IP catalog
resolves the same `create_ip` calls baked into the BD.
""",
    implementation = _vivado_block_design_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "block_design_template": attr.label(
            doc = "The create-bd tcl template.",
            default = Label("//vivado/private:create_bd.tcl.template"),
            allow_single_file = [".template"],
        ),
        "ip_blocks": attr.label_list(
            doc = "Packaged IP blocks referenced by the BD's `create_bd_cell` calls.",
            providers = [VivadoIPBlockInfo],
            default = [],
        ),
        "jobs": attr.int(
            doc = "Jobs to pass to vivado (resource hint to Bazel's scheduler).",
            default = 1,
        ),
        "module_top": attr.string(
            doc = "Name passed to `create_bd_design` in `src`. Used to locate the produced `.bd`.",
            mandatory = True,
        ),
        "part_number": attr.string(
            doc = "Xilinx part number the BD is generated for.",
            mandatory = True,
        ),
        "post_hooks": attr.label_list(
            doc = ("TCL files sourced after `generate_target all`, before " +
                   "the project closes. Sourced in list order. Useful for " +
                   "`make_wrapper` (auto-generated HDL wrapper) or " +
                   "`write_bd_tcl` round-tripping."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = ("TCL files sourced after project + IP-block setup, " +
                   "before sourcing the user's BD TCL. Sourced in list order."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "src": attr.label(
            doc = "Tcl script that calls `create_bd_design <module_top>` and `save_bd_design`.",
            mandatory = True,
            allow_single_file = [".tcl"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoBlockDesignInfo,
    ],
)
