"""Shared helpers used by every vivado rule.

Helpers return DATA (Tcl list / dict literals) for substitution into rule
templates. Templates own all Tcl code; rules emit only data.
"""

load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load("//vivado:providers.bzl", "VivadoBlockDesignInfo", "VivadoIPBlockInfo")
load("//vivado:toolchain.bzl", _TOOLCHAIN_TYPE = "TOOLCHAIN_TYPE")
load(":resource_set.bzl", "get_resource_set")

TOOLCHAIN_TYPE = _TOOLCHAIN_TYPE

# ============================================================================
# Tcl literal formatting
# ============================================================================

def _tcl_list(items):
    """Format `items` as a Tcl list literal.

    Empty elements are encoded as `{}` so positional Tcl `lassign` still gets
    the right slot count.
    """
    if not items:
        return "{}"
    return "{ " + " ".join([i if i != "" else "{}" for i in items]) + " }"

def _tcl_tuples(rows):
    """Format a list-of-lists as Tcl `{{a b c} {d e f}}`."""
    if not rows:
        return "{}"
    return "{ " + " ".join([_tcl_list(r) for r in rows]) + " }"

def _tcl_dict(pairs):
    """Format `pairs` as a `[dict create ...]` Tcl expression."""
    parts = []
    for k, v in pairs:
        parts.append("{} {{{}}}".format(k, v))
    return "[dict create " + " ".join(parts) + "]"

# ============================================================================
# Pass-through CLI args (`synth_args`, `place_args`, …)
# ============================================================================

def tcl_args(args):
    """Format a starlark `string_list` as a brace-quoted Tcl word list.

    Items containing whitespace are brace-wrapped so they survive Tcl list
    parsing as a single token. Literal Tcl quoting metacharacters
    (`{`, `}`, `\\`, `"`) must be brace-quoted by the caller.

    Args:
        args: list[str] (may be empty).

    Returns:
        Tcl source.
    """
    if not args:
        return "{}"
    out = []
    for a in args:
        if " " in a or "\t" in a:
            out.append("{" + a + "}")
        else:
            out.append(a)
    return "{ " + " ".join(out) + " }"

def validate_args(label, attr_name, args, forbidden):
    """Fail loudly if user-supplied args contain rule-controlled flags.

    Templates also emit user args BEFORE the rule's flags
    (`<cmd> {*}$ARGS -my_flag VAL`), so the rule wins if a new flag slips
    past `forbidden`.

    Args:
        label: `ctx.label` for the error message.
        attr_name: the attr the args came from.
        args: the args list.
        forbidden: flag strings the rule manages.
    """
    for arg in args:
        if arg in forbidden:
            fail(("{label}: `{attr} = [...]` cannot contain `{arg}` — that " +
                  "flag is rule-controlled (the rule emits it from a " +
                  "dedicated attribute / from its declared outputs). Remove " +
                  "`{arg}` from `{attr}`; if you need a different value, " +
                  "either set the corresponding rule attr or open a " +
                  "rules_vivado issue.").format(
                label = label,
                attr = attr_name,
                arg = arg,
            ))

# ============================================================================
# Toolchain resolution
# ============================================================================

def get_vivado_toolchain(ctx):
    """Resolve the Vivado toolchain settings for an action."""
    return ctx.toolchains[TOOLCHAIN_TYPE].vivado_info

# ============================================================================
# Hooks / Tcl-file lists
# ============================================================================

def file_list(targets):
    """Turn a label_list of files into a (tcl_list, files) pair.

    Args:
        targets: Targets whose files to collect.

    Returns:
        (tcl_literal, files): Tcl list literal of paths and the File objects
        the caller must add to action inputs.
    """
    files = []
    paths = []
    for t in targets:
        for f in t.files.to_list():
            files.append(f)
            paths.append(f.path)
    return _tcl_list(paths), files

# ============================================================================
# Hook helpers (TCL sources vs executable binaries — split by attr)
# ============================================================================
#
# Bazel transitions can't dispatch per-item, so hook lists are split at the
# attr layer: `.tcl` sources on a `cfg = "target"` attr, executables on a
# `cfg = "exec"` attr so they can run in the Bazel action.

def tcl_hooks_data(targets):
    """Collect `.tcl` hook files for template substitution.

    Args:
        targets: list of Target objects from a `.tcl`-only hook `label_list`.

    Returns:
        struct(files_literal, input_files).
    """
    files = []
    for t in targets:
        for f in t.files.to_list():
            files.append(f)
    return struct(
        files_literal = _tcl_list([f.path for f in files]),
        input_files = files,
    )

def exec_hooks_data(targets, *, project_dir_path, export_dir_path):
    """Build subprocess invocations for executable hooks.

    Hooks run in listed order under `set -e`; the first non-zero exit fails
    the action.

    Args:
        targets: Target objects from an executable-only hook `label_list`.
        project_dir_path: Path of the rule's project TreeArtifact.
        export_dir_path: Path of the rule's export TreeArtifact.

    Returns:
        struct(command, tools, env). `tools` must be passed to
        `ctx.actions.run_shell(tools=…)` so hook runfiles stage in the sandbox.
    """
    snippets = []
    tools = []
    for t in targets:
        exec_file = t[DefaultInfo].files_to_run.executable
        if exec_file == None:
            fail(("hook target {} is not executable — pass a rule that " +
                  "produces an executable (`sh_binary`, `py_binary`, " +
                  "`cc_binary`, `*_test`, or a rule setting " +
                  "`DefaultInfo(executable=...)`). Plain source files " +
                  "and `filegroup`s are rejected because the action " +
                  "invokes each hook as a subprocess.").format(t.label))
        snippets.append(
            "\"" + exec_file.path + "\"" +
            " --project-dir \"" + project_dir_path + "\"" +
            " --export-dir \"" + export_dir_path + "\"",
        )
        tools.append(t[DefaultInfo].files_to_run)
    env = {}
    if tools:
        env["VIVADO_PROJECT_DIR"] = project_dir_path
        env["VIVADO_EXPORT_DIR"] = export_dir_path
    return struct(
        command = "\n".join(snippets),
        tools = tools,
        env = env,
    )

# ============================================================================
# Report registry
# ============================================================================
#
# Splitting `filename` from `cmd` lets variants of one Vivado command land at
# distinct paths (e.g. `power` -> `power.rpt`, `power_xpe` -> `power.xpe`).
# Keep sorted alphabetically.

def _report(*, cmd, filename):
    """Build a REPORT_TYPES entry.

    Args:
        cmd: str. Tcl command template with `{OUT}` where the output path lands.
        filename: str. Canonical output filename Vivado writes to.

    Returns:
        struct(cmd: str, filename: str).
    """
    return struct(cmd = cmd, filename = filename)

REPORT_TYPES = {
    "cdc": _report(cmd = "report_cdc -file {OUT}", filename = "cdc.rpt"),
    "clock_interaction": _report(cmd = "report_clock_interaction -file {OUT}", filename = "clock_interaction.rpt"),
    "clock_networks": _report(cmd = "report_clock_networks -file {OUT}", filename = "clock_networks.rpt"),
    "clock_utilization": _report(cmd = "report_clock_utilization -file {OUT}", filename = "clock_utilization.rpt"),
    "clocks": _report(cmd = "report_clocks -file {OUT}", filename = "clocks.rpt"),
    "compile_order": _report(cmd = "report_compile_order -file {OUT}", filename = "compile_order.rpt"),
    "drc": _report(cmd = "report_drc -file {OUT}", filename = "drc.rpt"),
    "io": _report(cmd = "report_io -file {OUT}", filename = "io.rpt"),
    "methodology": _report(cmd = "report_methodology -file {OUT}", filename = "methodology.rpt"),
    "power": _report(cmd = "report_power -file {OUT}", filename = "power.rpt"),
    "power_xpe": _report(cmd = "report_power -xpe {OUT}", filename = "power.xpe"),
    "pulse_width": _report(cmd = "report_pulse_width -file {OUT}", filename = "pulse_width.rpt"),
    "qor_assessment": _report(cmd = "report_qor_assessment -file {OUT}", filename = "qor_assessment.rpt"),
    "qor_suggestions": _report(cmd = "report_qor_suggestions -file {OUT}", filename = "qor_suggestions.rpt"),
    "ram_utilization": _report(cmd = "report_ram_utilization -file {OUT}", filename = "ram_utilization.rpt"),
    "route_status": _report(cmd = "report_route_status -file {OUT}", filename = "route_status.rpt"),
    "timing_summary": _report(cmd = "report_timing_summary -file {OUT}", filename = "timing_summary.rpt"),
    "utilization": _report(cmd = "report_utilization -file {OUT}", filename = "utilization.rpt"),
}

def reports_data(ctx, reports):
    """Render the `reports` attr into substitution data.

    Args:
        ctx: The rule context.
        reports: Report-type strings; each must key `REPORT_TYPES`.

    Returns:
        struct(commands_dict, requested, files, file_dict).
    """
    if not reports:
        return struct(
            commands_dict = _tcl_dict([]),
            requested = _tcl_tuples([]),
            files = [],
            file_dict = {},
        )

    unknown = sorted([t for t in reports if t not in REPORT_TYPES])
    if unknown:
        fail("Unknown report types {}. Valid types: {}".format(
            unknown,
            sorted(REPORT_TYPES.keys()),
        ))

    # Per-target subdirectory so two phase targets in the same package can
    # request identical report types without colliding on declared paths.
    subdir = "{}.reports".format(ctx.label.name)
    files = []
    file_dict = {}
    rows = []
    for report_type in sorted(reports):
        entry = REPORT_TYPES[report_type]
        out_file = ctx.actions.declare_file("{}/{}".format(subdir, entry.filename))
        files.append(out_file)
        file_dict[report_type] = out_file
        rows.append([report_type, out_file.path])

    commands_dict = _tcl_dict([
        (t, REPORT_TYPES[t].cmd)
        for t in sorted(REPORT_TYPES.keys())
    ])

    return struct(
        commands_dict = commands_dict,
        requested = _tcl_tuples(rows),
        files = files,
        file_dict = file_dict,
    )

# ============================================================================
# run_tcl_template
# ============================================================================

# `export USER="${BUILD_USER:-}"` — Vivado's `create_waiver` and other
# metadata-writing commands invoked from IP-provided XDCs read `$USER` and
# raise CRITICAL WARNING [Vivado_Tcl 4-907] when it's empty (the norm on
# sandboxed RBE workers). `$BUILD_USER` comes from the toolchain env
# (aligned with Bazel `--stamp`'s workspace-status field).
#
# `trap` re-emits the Vivado log to stderr on failure; Vivado's stdout is
# discarded because `-log` is the authoritative capture.
_VIVADO_COMMAND = """\
set -e
export USER="${BUILD_USER:-}"
{{PRE_HOOKS}}
{{XILINX_ENV_SOURCE}}
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "ERROR: vivado exited with status $rc. Log follows ({{LOG}}):" >&2; cat "{{LOG}}" >&2 2>/dev/null || true; fi' EXIT INT TERM
"{{VIVADO_EXE}}" -mode batch -source "{{TCL}}" -log "{{LOG}}" -journal "{{JOURNAL}}" > /dev/null
{{POST_HOOKS}}
"""

def run_tcl_template(
        *,
        ctx,
        template,
        substitutions,
        input_files,
        output_files,
        mnemonic,
        jobs = 1,
        pre_processing_command = "",
        post_processing_command = "",
        hook_tools = [],
        hook_env = {},
        extra_execution_requirements = {},
        progress_message = None):
    """Runs a tcl template in vivado.

    Args:
        ctx: Context from a rule.
        template: The template file to use.
        substitutions: The substitutions to apply to the template.
        input_files: Input files that vivado needs.
        output_files: Expected outputs from the tcl script.
        mnemonic: Short CamelCase identifier shown in Bazel output.
        jobs: How many CPUs Vivado will use; used as scheduler
            `resource_set` hint. Clamped at MAX_VIVADO_THREADS.
        pre_processing_command: Bash command run BEFORE vivado.
        post_processing_command: Bash command run AFTER vivado.
        hook_tools: Executable targets referenced by the pre/post commands.
            Passed via `ctx.actions.run_shell(tools=...)` so runfiles stage.
        hook_env: Env vars merged into the action. Toolchain env wins on key
            collision — hooks can only augment, not override.
        extra_execution_requirements: Additional entries merged into the
            action's `execution_requirements`.
        progress_message: Optional progress message for the action.

    Returns:
        struct(outputs, log, journal).
    """
    env = get_vivado_toolchain(ctx)
    vivado_tcl = ctx.actions.declare_file("{}_run_vivado.tcl".format(ctx.label.name))
    vivado_log = ctx.actions.declare_file("{}.log".format(ctx.label.name))
    vivado_journal = ctx.actions.declare_file("{}.jou".format(ctx.label.name))

    ctx.actions.expand_template(
        template = template,
        output = vivado_tcl,
        substitutions = substitutions,
    )

    # Substitute paths BEFORE hook snippets so a hook whose path or args
    # happen to contain a `{{…}}` sequence can't collide with a placeholder
    # that was still pending expansion.
    substitutions = [
        ("{{VIVADO_EXE}}", env.vivado.executable.path),
        ("{{TCL}}", vivado_tcl.path),
        ("{{LOG}}", vivado_log.path),
        ("{{JOURNAL}}", vivado_journal.path),
        ("{{XILINX_ENV_SOURCE}}", "source \"" + env.xilinx_env.path + "\"" if env.xilinx_env else ""),
        ("{{PRE_HOOKS}}", pre_processing_command),
        ("{{POST_HOOKS}}", post_processing_command),
    ]
    vivado_command = _VIVADO_COMMAND
    for key, value in substitutions:
        vivado_command = vivado_command.replace(key, value)

    outputs = output_files + [vivado_log, vivado_journal]
    action_inputs = input_files + [vivado_tcl]
    if env.xilinx_env:
        action_inputs.append(env.xilinx_env)

    execution_requirements = dict(extra_execution_requirements)
    if env.requires_network:
        execution_requirements["requires-network"] = ""
    execution_requirements["resources:vivado_license"] = "1"

    if progress_message == None:
        progress_message = "{} %{{label}}".format(mnemonic)

    # Toolchain env wins on key collision — hooks can only augment.
    action_env = dict(hook_env)
    for k, v in env.env.items():
        action_env[k] = v

    ctx.actions.run_shell(
        outputs = outputs,
        inputs = action_inputs,
        tools = [env.vivado] + hook_tools,
        progress_message = progress_message,
        command = vivado_command,
        mnemonic = mnemonic,
        toolchain = TOOLCHAIN_TYPE,
        resource_set = get_resource_set(jobs),
        execution_requirements = execution_requirements,
        env = action_env,
    )

    return struct(
        outputs = outputs,
        log = vivado_log,
        journal = vivado_journal,
    )

# ============================================================================
# HDL source data
# ============================================================================

_DEFAULT_VHDL_LIBRARY = "xil_defaultlib"
_DEFAULT_VHDL_STANDARD = "2008"

def _hdl_row(file, vhdl_library, vhdl_standard):
    """Return a (kind, path, library, standard) tuple; None to skip the file."""
    ext = file.extension
    if ext == "v":
        return ("verilog", file.path, "xil_defaultlib", "")
    if ext == "sv":
        return ("systemverilog", file.path, "xil_defaultlib", "")
    if ext in ["vhd", "vhdl"]:
        return ("vhdl", file.path, vhdl_library, vhdl_standard)
    if ext == "tcl":
        return ("tcl", file.path, "", "")
    if ext == "xdc":
        return ("xdc", file.path, "", "")
    if ext in ["xml", "json"]:
        return None
    return ("import", file.path, "", "")

def hdl_sources_data(module):
    """Walk a module's transitive sources and split into per-kind Tcl lists.

    Walks `VerilogInfo.vhdl_deps` and `VhdlInfo.verilog_deps` so cross-lang
    instantiations reach the synth project. Without this, synth fails with
    `[Synth 8-439] module '<entity>' not found`.

    `.vhd` files reached via `VerilogInfo.data` (no `VhdlInfo` context) fall
    back to (`xil_defaultlib`, `2008`).

    Args:
        module: The top-level HDL library target.

    Returns:
        struct(all_files, hdl_sources, xdc_files, tcl_files).
    """
    all_files = []
    hdl_rows = []
    xdc_paths = []
    tcl_paths = []

    def _process(file, vhdl_library, vhdl_standard):
        all_files.append(file)
        row = _hdl_row(file, vhdl_library, vhdl_standard)
        if row == None:
            return
        kind = row[0]
        if kind == "xdc":
            xdc_paths.append(row[1])
        elif kind == "tcl":
            tcl_paths.append(row[1])
        else:
            hdl_rows.append(list(row))

    def _process_verilog(v):
        for f in v.srcs.to_list() + v.hdrs.to_list() + v.data.to_list():
            _process(f, _DEFAULT_VHDL_LIBRARY, _DEFAULT_VHDL_STANDARD)

    def _process_vhdl(v):
        vhdl_library = v.library if v.library else _DEFAULT_VHDL_LIBRARY
        vhdl_standard = v.standard if v.standard else _DEFAULT_VHDL_STANDARD
        for f in v.srcs.to_list() + v.data.to_list():
            _process(f, vhdl_library, vhdl_standard)

    if VerilogInfo in module:
        info = module[VerilogInfo]
        for v in info.deps.to_list() + [info]:
            _process_verilog(v)
        for v in info.vhdl_deps.to_list():
            _process_vhdl(v)

    if VhdlInfo in module:
        info = module[VhdlInfo]
        for v in info.deps.to_list() + [info]:
            _process_vhdl(v)
        for v in info.verilog_deps.to_list():
            _process_verilog(v)

    return struct(
        all_files = all_files,
        hdl_sources = _tcl_tuples(hdl_rows),
        xdc_files = _tcl_list(xdc_paths),
        tcl_files = _tcl_list(tcl_paths),
    )

# ============================================================================
# IP-block data
# ============================================================================

def ip_blocks_data(ip_blocks):
    """Extract `ip_blocks` deps into substitution-ready Tcl literals.

    Args:
        ip_blocks: Targets providing `VivadoIPBlockInfo`.

    Returns:
        struct(ip_repos, ip_configured_instances, ip_instances, input_files).
    """
    repo_paths = []
    repo_files = []
    configured_rows = []
    instance_rows = []

    for ip_block in ip_blocks:
        info = ip_block[VivadoIPBlockInfo]
        for repo in info.repo:
            repo_paths.append(repo.path)
            repo_files.append(repo)
        if info.configured_instance:
            ci = info.configured_instance
            configured_rows.append([ci.module_top, ci.repo_dir.path, ci.xci_relpath])
        if info.instantiable:
            i = info.instantiable
            instance_rows.append([i.name, i.vendor, i.library, i.version, i.module_name])

    return struct(
        ip_repos = _tcl_list(repo_paths),
        ip_configured_instances = _tcl_tuples(configured_rows),
        ip_instances = _tcl_tuples(instance_rows),
        input_files = repo_files,
    )

# ============================================================================
# Block-design data
# ============================================================================

def block_designs_data(block_designs):
    """Extract `block_designs` deps into a substitution-ready Tcl literal.

    Args:
        block_designs: Targets providing `VivadoBlockDesignInfo`.

    Returns:
        struct(block_designs, input_files). `input_files` includes each BD's
        `bd_dir` and its transitively-referenced IP-block repo directories.
    """
    rows = []
    input_files = []
    for bd in block_designs:
        info = bd[VivadoBlockDesignInfo]
        input_files.append(info.bd_dir)
        input_files.extend(info.ip_block_repos)
        rows.append([info.module_top, info.bd_dir.path])
    return struct(
        block_designs = _tcl_tuples(rows),
        input_files = input_files,
    )

# ============================================================================
# Encrypt data
# ============================================================================

def encrypt_data(*, ctx, all_files, ip_dir_src):
    """Produce substitution data + post-processing command for IP encryption.

    Args:
        ctx: The rule context.
        all_files: All files the IP depends on; filtered to .v/.sv/.vhd here.
        ip_dir_src: Path of the IP repo's `src/` directory.

    Returns:
        struct(encrypt_files, encrypted_outputs, post_processing_command).
    """
    rows = []
    encrypted_outputs = []
    post_processing_command = ""
    for file in all_files:
        if file.extension in ["v", "sv"]:
            language = "verilog"
        elif file.extension in ["vhd", "vhdl"]:
            language = "vhdl"
        else:
            continue
        enc_extension = ".enc.{}".format(file.extension)
        enc_filename = "{}{}".format(file.basename.split(".")[0], enc_extension)
        rows.append([language, enc_extension, file.path])
        enc_file = ctx.actions.declare_file(enc_filename)
        encrypted_outputs.append(enc_file)
        source_file = "{}/{}".format(file.dirname, enc_file.basename)
        post_processing_command += "cp {} {}; ".format(source_file, enc_file.path)
        post_processing_command += "cp {} {}/{}; ".format(source_file, ip_dir_src, file.basename)

    return struct(
        encrypt_files = _tcl_tuples(rows),
        encrypted_outputs = encrypted_outputs,
        post_processing_command = post_processing_command,
    )

# ============================================================================
# create_and_synth (shared by vivado_create_project + vivado_synthesize)
# ============================================================================

def create_and_synth(
        *,
        ctx,
        with_synth,
        synth_checkpoint = None,
        synth_strategy = None,
        reports = None,
        impl_xdc_bundle = None):
    """Create a project and optionally synthesize.

    Args:
        ctx: Context from a rule.
        with_synth: 1 to run synth_design, 0 to just create the project.
        synth_checkpoint: Output File for `write_checkpoint`; required when
            with_synth=1.
        synth_strategy: Synthesis strategy name; required when with_synth=1.
        reports: `struct` from `reports_data`, or None.
        impl_xdc_bundle: Optional output File; when set (and with_synth=1),
            the synth template captures source XDCs marked
            `USED_IN_IMPLEMENTATION && !IS_GENERATED` into this file so
            downstream phases can re-read them.

    Returns:
        struct(outputs, log, journal) forwarded from `run_tcl_template`.
    """
    hdl = hdl_sources_data(ctx.attr.module)
    ip = ip_blocks_data(ctx.attr.ip_blocks)
    bd = block_designs_data(ctx.attr.block_designs)

    project_mode = getattr(ctx.attr, "project_mode", "project")

    if project_mode == "project":
        project_dir = ctx.actions.declare_directory(ctx.label.name)
        project_dir_path = project_dir.path
    else:
        # `in_memory` mode: no on-disk project directory to declare.
        project_dir = None
        project_dir_path = ""

    pre_hooks_list, pre_hook_files = file_list(getattr(ctx.attr, "pre_hooks", []))
    post_hooks_list, post_hook_files = file_list(getattr(ctx.attr, "post_hooks", []))

    if with_synth:
        synth_path = synth_checkpoint.path
        with_synth_str = "1"
        synth_strategy_str = synth_strategy
        outputs = [synth_checkpoint]
        if project_dir != None:
            outputs.append(project_dir)
        if reports != None:
            outputs += reports.files
        if impl_xdc_bundle != None:
            outputs.append(impl_xdc_bundle)
            impl_xdc_bundle_path = impl_xdc_bundle.path
        else:
            impl_xdc_bundle_path = ""
    else:
        synth_path = ""
        with_synth_str = "0"
        synth_strategy_str = ""
        outputs = []
        if project_dir != None:
            outputs.append(project_dir)
        impl_xdc_bundle_path = ""

    if reports != None:
        report_commands_dict = reports.commands_dict
        requested_reports = reports.requested
    else:
        report_commands_dict = _tcl_dict([])
        requested_reports = _tcl_tuples([])

    # `synth_invocation` and `synth_args` only exist on `vivado_synthesize`;
    # for the no-synth path the substitutions are dead (gated by
    # `if {$WITH_SYNTH}` in the template).
    synth_invocation = getattr(ctx.attr, "synth_invocation", "launch_runs")
    synth_args = getattr(ctx.attr, "synth_args", [])
    validate_args(ctx.label, "synth_args", synth_args, ["-top"])

    substitutions = {
        "{{BLOCK_DESIGNS}}": bd.block_designs,
        "{{HDL_SOURCES}}": hdl.hdl_sources,
        "{{IMPL_XDC_BUNDLE}}": impl_xdc_bundle_path,
        "{{IP_CONFIGURED_INSTANCES}}": ip.ip_configured_instances,
        "{{IP_INSTANCES}}": ip.ip_instances,
        "{{IP_REPOS}}": ip.ip_repos,
        "{{JOBS}}": "{}".format(ctx.attr.jobs),
        "{{MODULE_TOP}}": ctx.attr.module_top,
        "{{PART_NUMBER}}": ctx.attr.part_number,
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
        "{{PROJECT_DIR}}": project_dir_path,
        "{{PROJECT_MODE}}": project_mode,
        "{{REPORT_COMMANDS}}": report_commands_dict,
        "{{REQUESTED_REPORTS}}": requested_reports,
        "{{SYNTH_ARGS}}": tcl_args(synth_args),
        "{{SYNTH_CHECKPOINT}}": synth_path,
        "{{SYNTH_INVOCATION}}": synth_invocation,
        "{{SYNTH_STRATEGY}}": synth_strategy_str,
        "{{TCL_FILES}}": hdl.tcl_files,
        "{{WITH_SYNTH}}": with_synth_str,
        "{{XDC_FILES}}": hdl.xdc_files,
    }

    return run_tcl_template(
        ctx = ctx,
        template = ctx.file.create_project_tcl_template,
        substitutions = substitutions,
        input_files = (
            hdl.all_files +
            ip.input_files +
            bd.input_files +
            pre_hook_files +
            post_hook_files
        ),
        output_files = outputs,
        mnemonic = "VivadoSynth" if with_synth else "VivadoCreateProject",
        jobs = ctx.attr.jobs,
    )
