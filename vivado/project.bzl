"""# vivado_create_project rule: build a Vivado project without synthesizing."""

load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load("//vivado:providers.bzl", "VivadoBlockDesignInfo", "VivadoIPBlockInfo")
load(
    "//vivado/private:common.bzl",
    "TOOLCHAIN_TYPE",
    "create_and_synth",
)

def _vivado_create_project_impl(ctx):
    result = create_and_synth(ctx = ctx, with_synth = 0)
    return [DefaultInfo(files = depset(result.outputs))]

vivado_create_project = rule(
    implementation = _vivado_create_project_impl,
    doc = "Create a Vivado project from a verilog_library without running synthesis.",
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "block_designs": attr.label_list(
            doc = ("Block designs (`vivado_block_design` targets) to fold " +
                   "into the project. The synth template's BD loop runs " +
                   "`generate_target all` + `create_ip_run` on each."),
            providers = [VivadoBlockDesignInfo],
            default = [],
        ),
        "create_project_tcl_template": attr.label(
            doc = "The create project tcl template",
            default = Label("//vivado/private:create_project.tcl.template"),
            allow_single_file = [".template"],
        ),
        "ip_blocks": attr.label_list(
            doc = "Ip blocks to include in this design.",
            providers = [VivadoIPBlockInfo],
            default = [],
        ),
        "jobs": attr.int(
            doc = "Jobs to pass to vivado which defines the amount of parallelism.",
            default = 4,
        ),
        "module": attr.label(
            doc = "The top level build.",
            providers = [[VerilogInfo], [VhdlInfo]],
            mandatory = True,
        ),
        "module_top": attr.string(
            doc = "The name of the top level verilog module.",
            mandatory = True,
        ),
        "part_number": attr.string(
            doc = "The targeted xilinx part.",
            mandatory = True,
        ),
        # NOTE: post_hooks are wired into the same `create_project.tcl.template`
        # but live inside `if WITH_SYNTH { ... }`, so they don't fire for the
        # no-synth path this rule takes. Use `pre_hooks` for customizations
        # you want before the project is saved.
        "pre_hooks": attr.label_list(
            doc = ("TCL files sourced after project setup (HDL/IP/BD load " +
                   "and constraints), before the project closes. Sourced " +
                   "in list order."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
    },
)
