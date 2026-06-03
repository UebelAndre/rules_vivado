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

# Short phase-name slugs used as keys in `VivadoLogInfo.{logs,journals}`.
# Each rule's impl uses its own slug; downstream consumers can look up
# `target[VivadoLogInfo].logs["route"]` etc.
_PHASE_SYNTH = "synth"
_PHASE_SYNTH_OPT = "synth_opt"

# Default `reports` for vivado_synthesize. Mirrors the report set that
# used to be hardcoded into create_project.tcl.template (timing summary
# + utilization). Callers can override with their own list, or pass
# `reports = []` to disable reports entirely.
_SYNTH_DEFAULT_REPORTS = ["timing_summary", "utilization"]

# Default `reports` for vivado_synthesis_optimize. Mirrors the prior
# baked-in set (timing summary + utilization + DRC).
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

    # No upstream phase — vivado_synthesize starts from HDL sources.
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
            doc = ("Block designs (`vivado_block_design` targets) to fold " +
                   "into the synth project. Each BD's normalized `.bd` is " +
                   "added to the project's `sources_1` fileset; the synth " +
                   "template's `foreach bd [get_files -quiet \"*.bd\"]` loop " +
                   "then runs `generate_target all` + `create_ip_run` on it."),
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
                   "`open_run \"synth_1\"`), before checkpoint write and " +
                   "reports. Sourced in list order. Ideal for custom check " +
                   "procs that should fail the build on synth-time issues."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = ("TCL files sourced after project setup but before synth " +
                   "runs are launched. Sourced in list order. Use for " +
                   "run-strategy overrides or custom IP catalog paths."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "project_mode": attr.string(
            doc = ("How Vivado stores project state. `project` (default) " +
                   "creates a named on-disk project at the action's " +
                   "declared output directory — file metadata persists " +
                   "across the action and Vivado's managed-run " +
                   "infrastructure (`launch_runs`, `synth_1`, etc.) is " +
                   "available. `in_memory` calls `create_project " +
                   "-in_memory`, sets `design_mode RTL` on the current " +
                   "fileset, and skips the on-disk project directory " +
                   "output — file metadata exists only for the current " +
                   "process, and managed runs are unavailable. " +
                   "`synth_invocation = launch_runs` requires `project`; " +
                   "the combination fails at analysis time. The two " +
                   "modes can produce different netlist hierarchies for " +
                   "block-design-instantiated IPs, so the choice affects " +
                   "downstream physical constraints that target IP-" +
                   "internal cells/nets."),
            default = "project",
            values = [
                "in_memory",
                "project",
            ],
        ),
        "reports": attr.string_list(
            doc = ("List of report types to run after `synth_design`, " +
                   "before checkpoint write. Each entry must be a key in " +
                   "`REPORT_TYPES` (`vivado/private/common.bzl`); each " +
                   "report's canonical filename is fixed per type (e.g. " +
                   "`cdc` → `cdc.rpt`, `power_xpe` → `power.xpe`) and " +
                   "lives at `<target>.reports/<filename>`. Each report's " +
                   "Tcl command is wrapped in `catch { ... }` so a single " +
                   "failure (common with `report_methodology` on " +
                   "under-constrained designs) writes an empty file rather " +
                   "than aborting the action. Unknown report types fail at " +
                   "analysis time. Pass `reports = []` to disable reports " +
                   "entirely. The declared output files are exposed via " +
                   "DefaultInfo, the `reports` output group, and the " +
                   "`VivadoReportsInfo` provider (which maps each report " +
                   "type to its declared File)."),
            default = _SYNTH_DEFAULT_REPORTS,
        ),
        "synth_args": attr.string_list(
            doc = ("Extra flags passed through to `synth_design` in the " +
                   "`synth_invocation = \"synth_design\"` path, e.g. " +
                   "`[\"-assert\", \"-flatten_hierarchy\", \"none\"]`. " +
                   "Empty by default — Vivado's own `synth_design` " +
                   "defaults apply when nothing is set. Each list item " +
                   "becomes one Tcl word; items with embedded " +
                   "whitespace are auto brace-wrapped to stay a single " +
                   "token. Cannot contain `-top` — the rule emits that " +
                   "from `module_top` and analysis-fails if the user " +
                   "tries to pass it. " +
                   "Not consulted on the `synth_invocation = " +
                   "\"launch_runs\"` path: managed runs take synth " +
                   "flags via `STEPS.SYNTH_DESIGN.ARGS.*` run " +
                   "properties; set those in a `pre_hooks` script."),
            default = [],
        ),
        "synth_invocation": attr.string(
            doc = ("How `synth_design` is invoked inside the synth " +
                   "project. `launch_runs` (default) wraps it in a " +
                   "managed `synth_1` design-run — Vivado spawns a " +
                   "fresh process that re-loads project state from " +
                   "disk and executes the run there. `synth_design` " +
                   "invokes it directly in the same Vivado process " +
                   "that ran project setup. " +
                   "Multi-config XCI consumer instantiations require " +
                   "`synth_design`: in the managed-run path the " +
                   "re-loading Vivado process binds the consumer's " +
                   "wrapper to the IP's project-managed synth wrapper " +
                   "(which doesn't propagate consumer-side generics), " +
                   "so wrappers passing distinct generic combinations " +
                   "surface as `__parameterized<N>` black boxes that " +
                   "fail `opt_design`. Direct in-process synth binds " +
                   "to the IP's actual entity instead."),
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

    # Merge upstream's logs with this phase's. Every checkpoint-input
    # rule advertises VivadoLogInfo (vivado_synthesize is the chain root).
    upstream = ctx.attr.checkpoint[VivadoLogInfo]
    logs = dict(upstream.logs)
    journals = dict(upstream.journals)
    logs[_PHASE_SYNTH_OPT] = result.log
    journals[_PHASE_SYNTH_OPT] = result.journal

    return [
        DefaultInfo(files = depset(result.outputs)),
        # `impl_xdc = None`: the bundle (if any) was re-read above and
        # `opt_design` baked the constraints into `synth_checkpoint`, so
        # the downstream phase doesn't need to re-read it. `module_top`
        # is forwarded so the placement phase can also `link_design -top`
        # if it needs to.
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
            doc = ("Extra flags passed through to `opt_design`, e.g. " +
                   "`[\"-directive\", \"Explore\"]` or `[\"-retarget\", " +
                   "\"-propconst\"]`. Empty by default — Vivado's own " +
                   "`opt_design` defaults apply when nothing is set. " +
                   "Each list item becomes one Tcl word; items with " +
                   "embedded whitespace are auto brace-wrapped to stay a " +
                   "single token. No flags are rule-controlled — " +
                   "`opt_design` takes no positional inputs."),
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
            doc = ("List of report types to run after `opt_design`. Same " +
                   "semantics as `reports` on `vivado_synthesize` — see " +
                   "that rule's doc."),
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
