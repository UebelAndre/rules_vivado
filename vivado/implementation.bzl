"""# Implementation-phase rules: placement, physical optimization, routing."""

load(
    "//vivado:providers.bzl",
    "VivadoLogInfo",
    "VivadoPlacementCheckpointInfo",
    "VivadoReportsInfo",
    "VivadoRoutingCheckpointInfo",
    "VivadoSynthCheckpointInfo",
)
load(
    "//vivado/private:common.bzl",
    "TOOLCHAIN_TYPE",
    "file_list",
    "reports_data",
    "run_tcl_template",
    "tcl_args",
    "validate_args",
)

_REPORTS_ATTR_DOC = (
    "Report types to run after the phase's main transformation. See " +
    "`vivado_synthesize.reports` for the full API."
)

_PLACEMENT_DEFAULT_REPORTS = ["timing_summary", "utilization"]
_ROUTING_DEFAULT_REPORTS = ["io", "power", "route_status", "timing_summary", "utilization"]

def _vivado_placement_impl(ctx):
    placement_checkpoint = ctx.actions.declare_file("{}.dcp".format(ctx.label.name))

    upstream_synth = ctx.attr.checkpoint[VivadoSynthCheckpointInfo]
    checkpoint_in = upstream_synth.checkpoint
    impl_xdc_in = getattr(upstream_synth, "impl_xdc", None)

    pre_hooks_list, pre_hook_files = file_list(ctx.attr.pre_hooks)
    post_hooks_list, post_hook_files = file_list(ctx.attr.post_hooks)
    reports = reports_data(ctx, ctx.attr.reports)

    validate_args(ctx.label, "place_args", ctx.attr.place_args, [])

    substitutions = {
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{CHECKPOINT_OUT}}": placement_checkpoint.path,
        "{{IMPL_XDC_BUNDLE}}": impl_xdc_in.path if impl_xdc_in else "",
        "{{PLACE_ARGS}}": tcl_args(ctx.attr.place_args),
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
        "{{REPORT_COMMANDS}}": reports.commands_dict,
        "{{REQUESTED_REPORTS}}": reports.requested,
        "{{THREADS}}": "{}".format(ctx.attr.threads),
    }

    outputs = [placement_checkpoint] + reports.files

    input_files = [checkpoint_in] + pre_hook_files + post_hook_files
    if impl_xdc_in:
        input_files.append(impl_xdc_in)

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.placement_template,
        substitutions = substitutions,
        input_files = input_files,
        output_files = outputs,
        mnemonic = "VivadoPlace",
        jobs = ctx.attr.threads,
    )

    upstream = ctx.attr.checkpoint[VivadoLogInfo]
    logs = dict(upstream.logs)
    journals = dict(upstream.journals)
    logs["place"] = result.log
    journals["place"] = result.journal

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoPlacementCheckpointInfo(checkpoint = placement_checkpoint),
        VivadoLogInfo(logs = logs, journals = journals),
        VivadoReportsInfo(reports = reports.file_dict),
        OutputGroupInfo(
            log = depset(logs.values()),
            reports = depset(reports.files),
        ),
    ]

vivado_placement = rule(
    doc = "Run placement on a (synthesis-optimized) checkpoint.",
    implementation = _vivado_placement_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "checkpoint": attr.label(
            doc = "Synthesis checkpoint.",
            providers = [VivadoSynthCheckpointInfo],
            mandatory = True,
        ),
        "place_args": attr.string_list(
            doc = "Extra flags passed through to `place_design`.",
            default = [],
        ),
        "placement_template": attr.label(
            doc = "The placement tcl template",
            default = Label("//vivado/private:placement.tcl.template"),
            allow_single_file = [".template"],
        ),
        "post_hooks": attr.label_list(
            doc = "TCL files sourced after `place_design`, in list order.",
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = "TCL files sourced on the opened checkpoint before `place_design`.",
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "reports": attr.string_list(
            doc = _REPORTS_ATTR_DOC,
            default = _PLACEMENT_DEFAULT_REPORTS,
        ),
        "threads": attr.int(
            doc = "Threads to pass to vivado which defines the amount of parallelism.",
            default = 8,
        ),
    },
    provides = [
        DefaultInfo,
        VivadoLogInfo,
        VivadoPlacementCheckpointInfo,
        VivadoReportsInfo,
    ],
)

def _vivado_place_optimize_impl(ctx):
    placement_checkpoint = ctx.actions.declare_file("{}.dcp".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoPlacementCheckpointInfo].checkpoint

    pre_hooks_list, pre_hook_files = file_list(ctx.attr.pre_hooks)
    post_hooks_list, post_hook_files = file_list(ctx.attr.post_hooks)
    reports = reports_data(ctx, ctx.attr.reports)

    validate_args(ctx.label, "phys_opt_args", ctx.attr.phys_opt_args, [])

    substitutions = {
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{CHECKPOINT_OUT}}": placement_checkpoint.path,
        "{{PHYS_OPT_ARGS}}": tcl_args(ctx.attr.phys_opt_args),
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
        "{{REPORT_COMMANDS}}": reports.commands_dict,
        "{{REQUESTED_REPORTS}}": reports.requested,
        "{{THREADS}}": "{}".format(ctx.attr.threads),
    }

    outputs = [placement_checkpoint] + reports.files

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.place_optimize_template,
        substitutions = substitutions,
        input_files = [checkpoint_in] + pre_hook_files + post_hook_files,
        output_files = outputs,
        mnemonic = "VivadoPlaceOpt",
        jobs = ctx.attr.threads,
    )

    upstream = ctx.attr.checkpoint[VivadoLogInfo]
    logs = dict(upstream.logs)
    journals = dict(upstream.journals)
    logs["place_opt"] = result.log
    journals["place_opt"] = result.journal

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoPlacementCheckpointInfo(checkpoint = placement_checkpoint),
        VivadoLogInfo(logs = logs, journals = journals),
        VivadoReportsInfo(reports = reports.file_dict),
        OutputGroupInfo(
            log = depset(logs.values()),
            reports = depset(reports.files),
        ),
    ]

vivado_place_optimize = rule(
    doc = "Run post-placement physical optimization.",
    implementation = _vivado_place_optimize_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "checkpoint": attr.label(
            doc = "Placement checkpoint.",
            providers = [VivadoPlacementCheckpointInfo],
            mandatory = True,
        ),
        "phys_opt_args": attr.string_list(
            doc = "Extra flags passed through to `phys_opt_design`.",
            default = [],
        ),
        "place_optimize_template": attr.label(
            doc = "The placement tcl template",
            default = Label("//vivado/private:place_optimize.tcl.template"),
            allow_single_file = [".template"],
        ),
        "post_hooks": attr.label_list(
            doc = "TCL files sourced after `phys_opt_design`, in list order.",
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = "TCL files sourced on the opened checkpoint before `phys_opt_design`.",
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "reports": attr.string_list(
            doc = _REPORTS_ATTR_DOC,
            default = _PLACEMENT_DEFAULT_REPORTS,
        ),
        "threads": attr.int(
            doc = "Threads to pass to vivado which defines the amount of parallelism.",
            default = 8,
        ),
    },
    provides = [
        DefaultInfo,
        VivadoLogInfo,
        VivadoPlacementCheckpointInfo,
        VivadoReportsInfo,
    ],
)

def _vivado_routing_impl(ctx):
    route_checkpoint = ctx.actions.declare_file("{}.dcp".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoPlacementCheckpointInfo].checkpoint

    pre_hooks_list, pre_hook_files = file_list(ctx.attr.pre_hooks)
    post_hooks_list, post_hook_files = file_list(ctx.attr.post_hooks)
    reports = reports_data(ctx, ctx.attr.reports)

    validate_args(ctx.label, "route_args", ctx.attr.route_args, [])

    substitutions = {
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{CHECKPOINT_OUT}}": route_checkpoint.path,
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
        "{{REPORT_COMMANDS}}": reports.commands_dict,
        "{{REQUESTED_REPORTS}}": reports.requested,
        "{{ROUTE_ARGS}}": tcl_args(ctx.attr.route_args),
        "{{THREADS}}": "{}".format(ctx.attr.threads),
    }

    outputs = [route_checkpoint] + reports.files

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.route_template,
        substitutions = substitutions,
        input_files = [checkpoint_in] + pre_hook_files + post_hook_files,
        output_files = outputs,
        mnemonic = "VivadoRoute",
        jobs = ctx.attr.threads,
    )

    upstream = ctx.attr.checkpoint[VivadoLogInfo]
    logs = dict(upstream.logs)
    journals = dict(upstream.journals)
    logs["route"] = result.log
    journals["route"] = result.journal

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoRoutingCheckpointInfo(checkpoint = route_checkpoint),
        VivadoLogInfo(logs = logs, journals = journals),
        VivadoReportsInfo(reports = reports.file_dict),
        OutputGroupInfo(
            log = depset(logs.values()),
            reports = depset(reports.files),
        ),
    ]

vivado_routing = rule(
    doc = "Run routing on a placement checkpoint.",
    implementation = _vivado_routing_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "checkpoint": attr.label(
            doc = "Placement checkpoint.",
            providers = [VivadoPlacementCheckpointInfo],
            mandatory = True,
        ),
        "post_hooks": attr.label_list(
            doc = "TCL files sourced after `route_design`, in list order.",
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = "TCL files sourced on the opened checkpoint before `route_design`.",
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "reports": attr.string_list(
            doc = _REPORTS_ATTR_DOC,
            default = _ROUTING_DEFAULT_REPORTS,
        ),
        "route_args": attr.string_list(
            doc = "Extra flags passed through to `route_design`.",
            default = [],
        ),
        "route_template": attr.label(
            doc = "The routing tcl template",
            default = Label("//vivado/private:route.tcl.template"),
            allow_single_file = [".template"],
        ),
        "threads": attr.int(
            doc = "Threads to pass to vivado which defines the amount of parallelism.",
            default = 8,
        ),
    },
    provides = [
        DefaultInfo,
        VivadoLogInfo,
        VivadoReportsInfo,
        VivadoRoutingCheckpointInfo,
    ],
)
