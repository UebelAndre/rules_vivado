"""# Bitstream-phase rule: vivado_write_bitstream."""

load("//vivado:providers.bzl", "VivadoLogInfo", "VivadoRoutingCheckpointInfo")
load(
    "//vivado/private:common.bzl",
    "TOOLCHAIN_TYPE",
    "file_list",
    "run_tcl_template",
    "tcl_args",
    "validate_args",
)

def _vivado_write_bitstream_impl(ctx):
    bitstream = ctx.actions.declare_file("{}.bit".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoRoutingCheckpointInfo].checkpoint

    outputs = [bitstream]

    if ctx.attr.with_xsa:
        with_xsa_str = "1"
        xsa_out = ctx.actions.declare_file("{}.xsa".format(ctx.label.name))
        xsa_path = xsa_out.path
        outputs.append(xsa_out)
    else:
        with_xsa_str = "0"
        xsa_path = ""

    pre_hooks_list, pre_hook_files = file_list(ctx.attr.pre_hooks)
    post_hooks_list, post_hook_files = file_list(ctx.attr.post_hooks)

    substitutions = {
        "{{BITSTREAM}}": bitstream.path,
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
        "{{THREADS}}": "{}".format(ctx.attr.threads),
        "{{WRITE_XSA}}": with_xsa_str,
        "{{XSA_PATH}}": xsa_path,
    }

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.write_bitstream_template,
        substitutions = substitutions,
        input_files = [checkpoint_in] + pre_hook_files + post_hook_files,
        output_files = outputs,
        mnemonic = "VivadoWriteBitstream",
        jobs = ctx.attr.threads,
    )

    upstream = ctx.attr.checkpoint[VivadoLogInfo]
    logs = dict(upstream.logs)
    journals = dict(upstream.journals)
    logs["write_bitstream"] = result.log
    journals["write_bitstream"] = result.journal

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoLogInfo(logs = logs, journals = journals),
        OutputGroupInfo(log = depset(logs.values())),
    ]

vivado_write_bitstream = rule(
    doc = "Write a Vivado bitstream (.bit) from a routed checkpoint, optionally including a .xsa.",
    implementation = _vivado_write_bitstream_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "checkpoint": attr.label(
            doc = "Routed checkpoint.",
            providers = [VivadoRoutingCheckpointInfo],
            mandatory = True,
        ),
        "post_hooks": attr.label_list(
            doc = ("TCL files sourced after a successful `write_bitstream`. " +
                   "Sourced in list order. Use for bitstream post-processing " +
                   "(eFUSE programming, signing, etc.)."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = ("TCL files sourced on the opened routed checkpoint, " +
                   "before `write_bitstream`. Sourced in list order. Use " +
                   "for last-mile bitstream settings (encryption, compression)."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "threads": attr.int(
            doc = "Threads to pass to vivado which defines the amount of parallelism.",
            default = 8,
        ),
        "with_xsa": attr.bool(
            doc = "Generate xsa too",
            default = False,
        ),
        "write_bitstream_template": attr.label(
            doc = "The write bitstream tcl template",
            default = Label("//vivado/private:write_bitstream.tcl.template"),
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoLogInfo,
    ],
)

def _vivado_write_device_image_impl(ctx):
    device_image = ctx.actions.declare_file("{}.pdi".format(ctx.label.name))

    checkpoint_in = ctx.attr.checkpoint[VivadoRoutingCheckpointInfo].checkpoint

    outputs = [device_image]
    xsa_out = None

    if ctx.attr.with_xsa:
        with_xsa_str = "1"
        xsa_out = ctx.actions.declare_file("{}.xsa".format(ctx.label.name))
        xsa_path = xsa_out.path
        outputs.append(xsa_out)
    else:
        with_xsa_str = "0"
        xsa_path = ""

    pre_hooks_list, pre_hook_files = file_list(ctx.attr.pre_hooks)
    post_hooks_list, post_hook_files = file_list(ctx.attr.post_hooks)

    validate_args(
        ctx.label,
        "write_args",
        ctx.attr.write_args,
        ["-force", "-file"],
    )

    substitutions = {
        "{{CHECKPOINT_IN}}": checkpoint_in.path,
        "{{DEVICE_IMAGE}}": device_image.path,
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
        "{{THREADS}}": "{}".format(ctx.attr.threads),
        "{{WRITE_ARGS}}": tcl_args(ctx.attr.write_args),
        "{{WRITE_XSA}}": with_xsa_str,
        "{{XSA_PATH}}": xsa_path,
    }

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.write_device_image_template,
        substitutions = substitutions,
        input_files = [checkpoint_in] + pre_hook_files + post_hook_files,
        output_files = outputs,
        mnemonic = "VivadoWriteDeviceImage",
        jobs = ctx.attr.threads,
    )

    upstream = ctx.attr.checkpoint[VivadoLogInfo]
    logs = dict(upstream.logs)
    journals = dict(upstream.journals)
    logs["write_device_image"] = result.log
    journals["write_device_image"] = result.journal

    # Per-file output groups so downstream macros can extract just the
    # `.pdi` / `.xsa` via `filegroup(output_group = …)`. The `xsa` group
    # is an empty depset when `with_xsa = False` rather than absent so
    # consumers don't have to guard the access. The `log` group carries
    # every transitive phase log (the full chain), so a bundler that
    # only sees `write_device_image` still gets all per-phase logs.
    output_groups = {
        "log": depset(logs.values()),
        "pdi": depset([device_image]),
        "xsa": depset([xsa_out] if xsa_out else []),
    }
    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoLogInfo(logs = logs, journals = journals),
        OutputGroupInfo(**output_groups),
    ]

vivado_write_device_image = rule(
    doc = ("Write a Versal device image (.pdi) from a routed checkpoint, " +
           "optionally including a .xsa. For non-Versal architectures use " +
           "`vivado_write_bitstream` instead."),
    implementation = _vivado_write_device_image_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "checkpoint": attr.label(
            doc = "Routed checkpoint.",
            providers = [VivadoRoutingCheckpointInfo],
            mandatory = True,
        ),
        "post_hooks": attr.label_list(
            doc = ("TCL files sourced after a successful `write_device_image`. " +
                   "Sourced in list order. Ideal for PDI post-processing " +
                   "(PMC CDO patches, BIF templating, IDCODE relaxation)."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = ("TCL files sourced on the opened routed checkpoint, " +
                   "before `write_device_image`. Sourced in list order. Use " +
                   "for last-mile PDI settings (encryption, partition options)."),
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "threads": attr.int(
            doc = "Threads to pass to vivado which defines the amount of parallelism.",
            default = 8,
        ),
        "with_xsa": attr.bool(
            doc = "Generate xsa too",
            default = False,
        ),
        "write_args": attr.string_list(
            doc = ("Extra flags passed through to `write_device_image`, " +
                   "e.g. `[\"-no_pdi\"]` or `[\"-no_partial_pdi\", " +
                   "\"-key_file\", \"keys.nky\"]`. Empty by default. " +
                   "Each list item becomes one Tcl word; items with " +
                   "embedded whitespace are auto brace-wrapped to stay " +
                   "a single token. Cannot contain `-force` (always " +
                   "emitted by the rule) or `-file` (the rule's " +
                   "declared output path is the positional " +
                   "argument) — analysis-fail otherwise."),
            default = [],
        ),
        "write_device_image_template": attr.label(
            doc = "The write device image tcl template",
            default = Label("//vivado/private:write_device_image.tcl.template"),
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoLogInfo,
    ],
)
