"""Shared helpers used by every vivado rule.

These helpers return DATA — Tcl list / dict literals — for substitution into
the rule templates. Templates contain ALL of the Tcl code; rules emit only
data. The contract for every template is exhaustively listed in its top
`{{NAME}} = ...` block; the body below that is plain Tcl that iterates over
the substituted data with static `foreach` / `switch` / `if` blocks.
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
#
# Tcl list literals: `{a b c}` is a 3-element list. An empty element is `{}`.
# Elements separated by whitespace. Tcl is permissive about whitespace inside
# braces. Bazel-out paths never contain spaces or braces, so plain join works.
# For tuple-of-tuples (e.g. {kind path library standard} per HDL source), we
# brace each tuple and brace the outer list.

def _tcl_list(items):
    """Format `items` as a Tcl list literal: `{a b c}` (or `{}` if empty).

    Empty elements are encoded as `{}` so positional Tcl `lassign` still gets
    the right slot count.
    """
    if not items:
        return "{}"
    return "{ " + " ".join([i if i != "" else "{}" for i in items]) + " }"

def _tcl_tuples(rows):
    """Format a list-of-lists as Tcl `{{a b c} {d e f}}` (or `{}` if empty)."""
    if not rows:
        return "{}"
    return "{ " + " ".join([_tcl_list(r) for r in rows]) + " }"

def _tcl_dict(pairs):
    """Format `pairs = [(k, v), ...]` as a `[dict create ...]` Tcl expression.

    Values are brace-quoted so they can contain whitespace / Tcl tokens.
    """
    parts = []
    for k, v in pairs:
        parts.append("{} {{{}}}".format(k, v))
    return "[dict create " + " ".join(parts) + "]"

# ============================================================================
# Pass-through CLI args (`synth_args`, `place_args`, …)
# ============================================================================

def tcl_args(args):
    """Format a starlark `string_list` as a brace-quoted Tcl word list.

    Renders the list so a template can `{*}` expand it into a command line:

        set SYNTH_ARGS {{SYNTH_ARGS}}            ;# rendered by Bazel
        synth_design {*}$SYNTH_ARGS -top $TOP    ;# expanded at runtime

    Each starlark item becomes one Tcl word. Items containing whitespace are
    brace-wrapped so they stay a single token after Tcl parses the list (the
    common case is a flag value like `-include_dirs '/path with spaces'`).
    Items containing literal Tcl quoting metacharacters (`{`, `}`, `\\`,
    `"`) are not handled — those need to be brace-quoted by the caller.

    Args:
        args: list[str] from a rule's `string_list` attr (may be empty).

    Returns:
        Tcl source: `{}` for an empty list, `{ a {b c} d }` otherwise.
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

    Rules typically emit flags whose values they own (output paths, the
    top-module name, the `-force` overwrite policy). Letting a caller pass
    those same flags via `*_args` would either silently override the rule's
    value (last-wins) or trip a Vivado runtime error with a confusing
    message. This is the analysis-time guard.

    Defence in depth: callers of this helper also emit user args BEFORE the
    rule's flags in the template (`<cmd> {*}$ARGS -my_flag VAL`), so even if
    a new flag slips past the forbidden list, the rule still wins.

    Args:
        label: `ctx.label` for the error message.
        attr_name: the attr the args came from (e.g. `"synth_args"`).
        args: the args list.
        forbidden: set/list of flag strings the rule manages (e.g.
            `["-top"]`, `["-force", "-file"]`).
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
    """Resolve the Vivado toolchain settings for an action.

    Args:
        ctx: The rule context.

    Returns:
        VivadoToolchainInfo struct (xilinx_env: File, requires_network: bool,
        env: dict[str, str]).
    """
    return ctx.toolchains[TOOLCHAIN_TYPE].vivado_info

# ============================================================================
# Hooks / Tcl-file lists
# ============================================================================
#
# A rule's `pre_hooks` / `post_hooks` label_list attributes (and TCL_SOURCES
# from `module.data`) come into the template as a Tcl list of paths. The
# template's body does `foreach hook $PRE_HOOKS { source $hook }`.

def file_list(targets):
    """Turn a label_list of files into a (tcl_list, files) pair.

    Args:
        targets: A list of Target objects (typically from a `label_list` attr).
            All files from every target are collected in iteration order.

    Returns:
        (tcl_literal, files): `tcl_literal` is the Tcl list literal of file
            paths (`{}` if empty); `files` is the list of `File` objects the
            caller must add to the action's `input_files`.
    """
    files = []
    paths = []
    for t in targets:
        for f in t.files.to_list():
            files.append(f)
            paths.append(f.path)
    return _tcl_list(paths), files

# ============================================================================
# Report registry
# ============================================================================
#
# Vivado built-in `report_*` Tcl commands keyed by short type name. Each
# entry pairs the command template (`{OUT}` is the output path) with the
# canonical output filename. Splitting the filename from the command lets
# `power` and `power_xpe` share `report_power`'s family while landing at
# distinct paths (`power.rpt` vs `power.xpe`).
#
# Reports that take non-trivial flag combinations (e.g.
# `report_design_analysis -logic_level_distribution -of_timing_paths …`)
# get their own entry with the full canonical command. Keep sorted
# alphabetically.

REPORT_TYPES = {
    "cdc": struct(cmd = "report_cdc -file {OUT}", filename = "cdc.rpt"),
    "clock_interaction": struct(cmd = "report_clock_interaction -file {OUT}", filename = "clock_interaction.rpt"),
    "clock_networks": struct(cmd = "report_clock_networks -file {OUT}", filename = "clock_networks.rpt"),
    "clock_utilization": struct(cmd = "report_clock_utilization -file {OUT}", filename = "clock_utilization.rpt"),
    "clocks": struct(cmd = "report_clocks -file {OUT}", filename = "clocks.rpt"),
    "compile_order": struct(cmd = "report_compile_order -file {OUT}", filename = "compile_order.rpt"),
    "drc": struct(cmd = "report_drc -file {OUT}", filename = "drc.rpt"),
    "io": struct(cmd = "report_io -file {OUT}", filename = "io.rpt"),
    "methodology": struct(cmd = "report_methodology -file {OUT}", filename = "methodology.rpt"),
    "power": struct(cmd = "report_power -file {OUT}", filename = "power.rpt"),
    "power_xpe": struct(cmd = "report_power -xpe {OUT}", filename = "power.xpe"),
    "pulse_width": struct(cmd = "report_pulse_width -file {OUT}", filename = "pulse_width.rpt"),
    "qor_assessment": struct(cmd = "report_qor_assessment -file {OUT}", filename = "qor_assessment.rpt"),
    "qor_suggestions": struct(cmd = "report_qor_suggestions -file {OUT}", filename = "qor_suggestions.rpt"),
    "ram_utilization": struct(cmd = "report_ram_utilization -file {OUT}", filename = "ram_utilization.rpt"),
    "route_status": struct(cmd = "report_route_status -file {OUT}", filename = "route_status.rpt"),
    "timing_summary": struct(cmd = "report_timing_summary -file {OUT}", filename = "timing_summary.rpt"),
    "utilization": struct(cmd = "report_utilization -file {OUT}", filename = "utilization.rpt"),
}

def reports_data(ctx, reports):
    """Render the `reports` attr into substitution data.

    Args:
        ctx: The rule context (used for `actions.declare_file`).
        reports: list[str] from the rule's `reports` attr. Each entry must
            be a key in `REPORT_TYPES`.

    Returns:
        struct(
            commands_dict: Tcl `[dict create ...]` literal mapping each type
                in REPORT_TYPES to its command template (with `{OUT}`).
            requested: Tcl list-of-tuples literal: `{ {type out_path} ... }`
                for each entry in `reports`.
            files: list[File] of declared outputs.
            file_dict: dict[str, File] keyed by report type (for VivadoReportsInfo).
        )
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

    # Per-target subdirectory (`<target>.reports/`) so two phase targets
    # in the same package can request identical report types without
    # colliding on the declared path.
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

def run_tcl_template(
        *,
        ctx,
        template,
        substitutions,
        input_files,
        output_files,
        mnemonic,
        jobs = 1,
        post_processing_command = "",
        extra_execution_requirements = {},
        progress_message = None):
    """Runs a tcl template in vivado.

    Args:
        ctx: Context from a rule.
        template: The template file to use.
        substitutions: The substitutions to apply to the template.
        input_files: A list of input files that vivado needs to run.
        output_files: A list of expected outputs from the tcl script running on vivado.
        mnemonic: A short CamelCase identifier shown in Bazel output for this action.
        jobs: How many CPUs Vivado will use for this action. Used as the
            `resource_set` hint to Bazel's scheduler. Clamped at
            MAX_VIVADO_THREADS. Pass 1 (the default) for single-threaded actions.
        post_processing_command: A bash command to run after vivado.
        extra_execution_requirements: dict[str, str] of additional entries to
            merge into the action's `execution_requirements`.
        progress_message: An optional progress message for the action.

    Returns:
        A struct with named fields:
            .outputs (list[File]): every File the action declares.
            .log (File): the `<target>.log` Vivado writes via `-log`.
            .journal (File): the `<target>.jou` Vivado writes via `-journal`.
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

    # `vivado` is the toolchain's tracked executable (typically a shim that
    # `exec`s the install) — passed via `tools=` so runfiles come along
    # when the user wires a `*_binary` rule. `xilinx_env` is an optional
    # shell-side escape hatch sourced before it — plain data file. Static
    # env flows through `run_shell(env=...)`.
    vivado_command = "set -e\n"

    # Vivado's `create_waiver` (and a handful of other metadata-writing
    # commands invoked from IP-provided XDCs) read `$USER` to stamp the
    # waiver's author field, and raise CRITICAL WARNING [Vivado_Tcl
    # 4-907] when it's empty — which is the norm on sandboxed RBE
    # workers. The toolchain's env exposes `$BUILD_USER` (a clean
    # forwarding name that aligns with Bazel `--stamp`'s
    # workspace-status `BUILD_USER` field, should the consumer later
    # opt in to stamping). Forward it into `$USER` here so the IP XDCs
    # see a populated value without us claiming an arbitrary identity
    # at the OS-process layer.
    vivado_command += "export USER=\"${BUILD_USER:-}\"\n"

    if env.xilinx_env:
        vivado_command += "source " + env.xilinx_env.path + "\n"
    vivado_command += (
        "trap 'rc=$?; if [ \"$rc\" -ne 0 ]; then " +
        "echo \"ERROR: vivado exited with status $rc. Log follows (" +
        vivado_log.path + "):\" >&2; " +
        "cat " + vivado_log.path + " >&2 2>/dev/null || true; " +
        "fi' EXIT INT TERM\n"
    )
    vivado_command += (
        env.vivado.executable.path + " -mode batch -source " + vivado_tcl.path +
        " -log " + vivado_log.path +
        " -journal " + vivado_journal.path +
        " > /dev/null\n"
    )
    if post_processing_command:
        vivado_command += post_processing_command + "\n"

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

    ctx.actions.run_shell(
        outputs = outputs,
        inputs = action_inputs,
        tools = [env.vivado],
        progress_message = progress_message,
        command = vivado_command,
        mnemonic = mnemonic,
        toolchain = TOOLCHAIN_TYPE,
        resource_set = get_resource_set(jobs),
        execution_requirements = execution_requirements,
        env = env.env,
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
    """Return a (kind, path, library, standard) tuple or None for an HDL file.

    `None` means "skip this file" (e.g. IP-XACT metadata).
    """
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

    Handles both `VerilogInfo` (rules_verilog) and `VhdlInfo` (rules_vhdl).
    VHDL sources carry their `library`/`standard` from VhdlInfo; .vhd files
    reached via VerilogInfo.data fall back to (`xil_defaultlib`, `2008`).

    Args:
        module: The top-level HDL library target.

    Returns:
        struct(
            all_files: list[File] of every file the module depends on.
            hdl_sources: Tcl list-of-tuples literal `{{kind path lib std} ...}`
                covering .v, .sv, .vhd, and generic `import_files` entries.
            xdc_files: Tcl list literal of `.xdc` constraint file paths.
            tcl_files: Tcl list literal of `.tcl` script paths.
        )
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

    if VerilogInfo in module:
        info = module[VerilogInfo]
        for v in info.deps.to_list() + [info]:
            for f in v.srcs.to_list() + v.hdrs.to_list() + v.data.to_list():
                _process(f, _DEFAULT_VHDL_LIBRARY, _DEFAULT_VHDL_STANDARD)

    if VhdlInfo in module:
        info = module[VhdlInfo]
        for v in info.deps.to_list() + [info]:
            vhdl_library = v.library if v.library else _DEFAULT_VHDL_LIBRARY
            vhdl_standard = v.standard if v.standard else _DEFAULT_VHDL_STANDARD
            for f in v.srcs.to_list() + v.data.to_list():
                _process(f, vhdl_library, vhdl_standard)

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
    """Extract `ip_blocks` deps into three substitution-ready Tcl literals.

    Args:
        ip_blocks: A list of targets providing `VivadoIPBlockInfo`.

    Returns:
        struct(
            ip_repos: Tcl list literal of repo directory paths.
            ip_configured_instances: Tcl list-of-tuples literal:
                `{ {module_top repo_path xci_relpath} ... }`.
            ip_instances: Tcl list-of-tuples literal:
                `{ {name vendor library version module_name} ... }`.
            input_files: list[File] of repo `bd_dir`-style TreeArtifacts the
                caller must add to the action's `input_files`.
        )
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
        block_designs: A list of targets providing `VivadoBlockDesignInfo`.

    Returns:
        struct(
            block_designs: Tcl list-of-tuples literal:
                `{ {module_top bd_dir_path} ... }`.
            input_files: list[File] of `bd_dir` TreeArtifacts AND each BD's
                transitively-referenced IP-block repo directories. Caller adds
                all of them to the action's `input_files`.
        )
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

    The encryption keyfile path is NOT passed here — the rule substitutes it
    as the scalar `{{ENCRYPT_KEYFILE}}` so the template loop can reference
    `$ENCRYPT_KEYFILE` once per file in a static `foreach`.

    Args:
        ctx: The rule context.
        all_files: All files the IP depends on (filter to .v/.sv/.vhd here).
        ip_dir_src: Path of the IP repo's `src/` directory; used to stage
            encrypted copies for downstream consumers.

    Returns:
        struct(
            encrypt_files: Tcl list-of-tuples literal:
                `{ {lang ext file_path} ... }`. Empty when no encryptable
                source files were found.
            encrypted_outputs: list[File] of the `<name>.enc.<ext>` files
                the rule must declare as outputs.
            post_processing_command: Bash command to run after vivado that
                copies the encrypted artifacts to their declared output
                paths and into the IP `src/` directory.
        )
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
        synth_checkpoint: Output File for `write_checkpoint`. Required when
            with_synth=1; ignored otherwise.
        synth_strategy: Synthesis strategy name (e.g. "Vivado Synthesis
            Defaults"). Required when with_synth=1.
        reports: `struct` returned by `reports_data` (or None for no reports).
        impl_xdc_bundle: Optional output File for the implementation-only
            XDC bundle. When set (and `with_synth=1`), the synth template
            captures source XDCs marked `USED_IN_IMPLEMENTATION == True`
            (and `IS_GENERATED == False`) into this file so downstream
            phases can re-read them. When `None`, no bundle is produced.
            See `VivadoSynthCheckpointInfo.impl_xdc` for the consumer
            side of the contract.

    Returns:
        A struct (forwarded from `run_tcl_template`) with `outputs`, `log`,
        `journal`.
    """
    hdl = hdl_sources_data(ctx.attr.module)
    ip = ip_blocks_data(ctx.attr.ip_blocks)
    bd = block_designs_data(ctx.attr.block_designs)

    # `vivado_create_project` doesn't expose `project_mode`; it always
    # writes a named on-disk project (that's the rule's whole point).
    project_mode = getattr(ctx.attr, "project_mode", "project")

    if project_mode == "project":
        project_dir = ctx.actions.declare_directory(ctx.label.name)
        project_dir_path = project_dir.path
    else:
        # `in_memory` mode: Vivado's project state lives only in the
        # current process; no on-disk directory to declare as an output.
        project_dir = None
        project_dir_path = ""

    # `vivado_create_project` declares only `pre_hooks`; `vivado_synthesize`
    # declares both. Use getattr so this helper supports either caller.
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

    # `synth_args` only exists as an attr on `vivado_synthesize`. For
    # callers that share this helper but don't synthesise (e.g.
    # `vivado_create_project`), the substitution renders as `{}` and is
    # never evaluated (the template gates the use behind `if {$WITH_SYNTH}`).
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
        "{{SYNTH_INVOCATION}}": ctx.attr.synth_invocation,
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
