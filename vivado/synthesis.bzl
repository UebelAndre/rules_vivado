"""# Synthesis-phase rules: vivado_synthesize and vivado_synthesis_optimize."""

load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load(
    "//vivado:providers.bzl",
    "VivadoBlockDesignInfo",
    "VivadoIPBlockInfo",
    "VivadoLogInfo",
    "VivadoReportsInfo",
    "VivadoSynthCheckpointInfo",
)
load(
    "//vivado/private:common.bzl",
    "TOOLCHAIN_TYPE",
    "create_and_synth",
    "file_list",
    "reports_data",
    "run_tcl_template",
    "tcl_args",
    "validate_args",
)

# Phase-name slugs keying `VivadoLogInfo.{logs,journals}`.
_PHASE_SYNTH = "synth"
_PHASE_SYNTH_OPT = "synth_opt"

_SYNTH_DEFAULT_REPORTS = ["timing_summary", "utilization"]
_SYNTH_OPT_DEFAULT_REPORTS = ["drc", "timing_summary", "utilization"]

def _vivado_synthesize_impl(ctx):
    if (ctx.attr.synth_invocation == "launch_runs" and
        ctx.attr.project_mode == "in_memory"):
        fail(("vivado_synthesize {}: `synth_invocation = \"launch_runs\"` " +
              "requires `project_mode = \"project\"` (Vivado's managed-run " +
              "infrastructure is unavailable in `create_project -in_memory` " +
              "mode). Use `synth_invocation = \"synth_design\"` for the " +
              "`in_memory` flow.").format(ctx.label))

    synth_checkpoint = ctx.actions.declare_file("{}.dcp".format(ctx.label.name))
    impl_xdc_bundle = ctx.actions.declare_file("{}.impl.xdc".format(ctx.label.name))

    reports = reports_data(ctx, ctx.attr.reports)

    result = create_and_synth(
        ctx = ctx,
        with_synth = 1,
        synth_checkpoint = synth_checkpoint,
        synth_strategy = ctx.attr.synth_strategy,
        reports = reports,
        impl_xdc_bundle = impl_xdc_bundle,
    )

    logs = {_PHASE_SYNTH: result.log}
    journals = {_PHASE_SYNTH: result.journal}

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoSynthCheckpointInfo(
            checkpoint = synth_checkpoint,
            impl_xdc = impl_xdc_bundle,
            module_top = ctx.attr.module_top,
        ),
        VivadoLogInfo(logs = logs, journals = journals),
        VivadoReportsInfo(reports = reports.file_dict),
        OutputGroupInfo(
            log = depset(logs.values()),
            reports = depset(reports.files),
        ),
    ]

vivado_synthesize = rule(
    doc = "Create a Vivado project and run synthesis on it.",
    implementation = _vivado_synthesize_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "block_designs": attr.label_list(
            doc = "Block designs to fold into the synth project.",
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
        "post_hooks": attr.label_list(
            doc = ("TCL files sourced on the open synthesized design (after " +
                   "`open_run \"synth_1\"`), before checkpoint write and reports. " +
                   "Sourced in list order."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = ("TCL files sourced after project setup but before synth runs " +
                   "are launched. Sourced in list order."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "project_mode": attr.string(
            doc = ("How Vivado stores project state. `project` creates a named " +
                   "on-disk project so managed-run infrastructure " +
                   "(`launch_runs`, `synth_1`) is available. `in_memory` calls " +
                   "`create_project -in_memory`; managed runs are unavailable, " +
                   "so `synth_invocation = launch_runs` requires `project`. " +
                   "The two modes can produce different netlist hierarchies for " +
                   "block-design-instantiated IPs, affecting downstream " +
                   "physical constraints that target IP-internal cells/nets."),
            default = "project",
            values = [
                "in_memory",
                "project",
            ],
        ),
        "reports": attr.string_list(
            doc = ("Report types to run after `synth_design`, before checkpoint " +
                   "write. Each entry must be a key in `REPORT_TYPES` " +
                   "(`vivado/private/common.bzl`). Reports live at " +
                   "`<target>.reports/<filename>` and are wrapped in `catch` so " +
                   "a single failure writes an empty file rather than aborting. " +
                   "Pass `reports = []` to disable."),
            default = _SYNTH_DEFAULT_REPORTS,
        ),
        "synth_args": attr.string_list(
            doc = ("Extra flags for `synth_design` in the `synth_design` " +
                   "invocation path. Cannot contain `-top` (the rule emits that " +
                   "from `module_top`). Not consulted on the `launch_runs` path; " +
                   "there, set `STEPS.SYNTH_DESIGN.ARGS.*` run properties from " +
                   "a `pre_hooks` script."),
            default = [],
        ),
        "synth_invocation": attr.string(
            doc = ("How `synth_design` is invoked. `launch_runs` wraps it in a " +
                   "managed `synth_1` design-run (fresh Vivado process re-loads " +
                   "project state from disk). `synth_design` invokes it in the " +
                   "same process. Multi-config XCI consumer instantiations " +
                   "require `synth_design`: in `launch_runs` the re-loading " +
                   "process binds consumer wrappers to the IP's project-managed " +
                   "synth wrapper (which doesn't propagate consumer-side " +
                   "generics), so wrappers passing distinct generic combinations " +
                   "surface as `__parameterized<N>` black boxes."),
            default = "launch_runs",
            values = [
                "launch_runs",
                "synth_design",
            ],
        ),
        "synth_strategy": attr.string(
            doc = "The synthesis strategy to use.",
            default = "Vivado Synthesis Defaults",
        ),
    },
    provides = [
        DefaultInfo,
        VivadoLogInfo,
        VivadoReportsInfo,
        VivadoSynthCheckpointInfo,
    ],
)

def _vivado_synthesis_optimize_impl(ctx):
    synth_checkpoint = ctx.actions.declare_file("{}.dcp".format(ctx.label.name))
    if ctx.attr.with_probes:
        probes_file = ctx.actions.declare_file("{}.ltx".format(ctx.label.name))
        probes_file_path = probes_file.path
    else:
        probes_file = None
        probes_file_path = ""

    upstream_synth = ctx.attr.checkpoint[VivadoSynthCheckpointInfo]
    checkpoint_in = upstream_synth.checkpoint
    impl_xdc_in = getattr(upstream_synth, "impl_xdc", None)
    module_top = getattr(upstream_synth, "module_top", "") or ""

    validate_args(ctx.label, "opt_args", ctx.attr.opt_args, [])

    pre_hooks_list, pre_hook_files = file_list(ctx.attr.pre_hooks)
    post_hooks_list, post_hook_files = file_list(ctx.attr.post_hooks)
    reports = reports_data(ctx, ctx.attr.reports)

    substitutions = {
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{CHECKPOINT_OUT}}": synth_checkpoint.path,
        "{{IMPL_XDC_BUNDLE}}": impl_xdc_in.path if impl_xdc_in else "",
        "{{MODULE_TOP}}": module_top,
        "{{OPT_ARGS}}": tcl_args(ctx.attr.opt_args),
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
        "{{PROBES_FILE}}": probes_file_path,
        "{{REPORT_COMMANDS}}": reports.commands_dict,
        "{{REQUESTED_REPORTS}}": reports.requested,
        "{{THREADS}}": "{}".format(ctx.attr.threads),
    }

    outputs = [synth_checkpoint] + reports.files
    if ctx.attr.with_probes:
        outputs.append(probes_file)

    input_files = [checkpoint_in] + pre_hook_files + post_hook_files
    if impl_xdc_in:
        input_files.append(impl_xdc_in)

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.synthesis_optimize_template,
        substitutions = substitutions,
        input_files = input_files,
        output_files = outputs,
        mnemonic = "VivadoSynthOpt",
        jobs = ctx.attr.threads,
    )

    upstream = ctx.attr.checkpoint[VivadoLogInfo]
    logs = dict(upstream.logs)
    journals = dict(upstream.journals)
    logs[_PHASE_SYNTH_OPT] = result.log
    journals[_PHASE_SYNTH_OPT] = result.journal

    return [
        DefaultInfo(files = depset(result.outputs)),
        # `opt_design` baked the impl-xdc bundle (if any) into the checkpoint,
        # so downstream phases don't need to re-read it.
        VivadoSynthCheckpointInfo(
            checkpoint = synth_checkpoint,
            impl_xdc = None,
            module_top = module_top,
        ),
        VivadoLogInfo(logs = logs, journals = journals),
        VivadoReportsInfo(reports = reports.file_dict),
        OutputGroupInfo(
            log = depset(logs.values()),
            reports = depset(reports.files),
        ),
    ]

vivado_synthesis_optimize = rule(
    doc = "Run post-synthesis optimization on a synthesis checkpoint.",
    implementation = _vivado_synthesis_optimize_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "checkpoint": attr.label(
            doc = "Synthesis checkpoint.",
            providers = [VivadoSynthCheckpointInfo],
            mandatory = True,
        ),
        "opt_args": attr.string_list(
            doc = "Extra flags passed through to `opt_design`.",
            default = [],
        ),
        "post_hooks": attr.label_list(
            doc = ("TCL files sourced after `opt_design`, before reports " +
                   "and checkpoint write. Sourced in list order."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = ("TCL files sourced on the opened synth checkpoint, " +
                   "before `opt_design`. Sourced in list order."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "reports": attr.string_list(
            doc = "Report types to run after `opt_design`; see `vivado_synthesize.reports`.",
            default = _SYNTH_OPT_DEFAULT_REPORTS,
        ),
        "synthesis_optimize_template": attr.label(
            doc = "The synthesis optimization tcl template",
            default = Label("//vivado/private:synth_optimize.tcl.template"),
            allow_single_file = [".template"],
        ),
        "threads": attr.int(
            doc = "Threads to pass to vivado which defines the amount of parallelism.",
            default = 8,
        ),
        "with_probes": attr.bool(
            doc = "Create debug probes.",
            default = False,
        ),
    },
    provides = [
        DefaultInfo,
        VivadoLogInfo,
        VivadoReportsInfo,
        VivadoSynthCheckpointInfo,
    ],
)
