"""# Simulation rules"""

load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load(
    "//vivado:providers.bzl",
    "VivadoBlockDesignInfo",
    "VivadoCompiledSimlibInfo",
    "VivadoExportSimulationInfo",
    "VivadoIPBlockInfo",
)
load(
    "//vivado/private:common.bzl",
    "TOOLCHAIN_TYPE",
    "block_designs_data",
    "exec_hooks_data",
    "hdl_sources_data",
    "ip_blocks_data",
    "run_tcl_template",
    "tcl_hooks_data",
)

_SIMULATOR_CHOICES = [
    "activehdl",
    "ies",
    "modelsim",
    "questa",
    "riviera",
    "vcs",
    "vcs_mx",
    "xcelium",
    "xsim",
]

_DEFAULT_XSIM_ERROR_PATTERNS = [
    "^Error: ",
    "^ERROR:",
    "FATAL_ERROR",
    "\\$fatal",
]

_DEFAULT_XSIM_COMPLETION_PATTERN = "\\$finish"

def _validate_xsim_pattern(label, attr_name, pattern):
    if "'" in pattern:
        fail(("{label}: `{attr}` pattern {pattern!r} contains a literal " +
              "single quote, which would break the embedded pass/fail " +
              "shell script. Use the ERE character class `[\\x27]` " +
              "instead if you need to match a `'`.").format(
            label = label,
            attr = attr_name,
            pattern = pattern,
        ))

def _bash_single_quote(s):
    """Wrap `s` in single quotes for bash embedding, using the classic `'"'"'` escape."""
    return "'" + s.replace("'", "'\\''") + "'"

def _xsim_test_impl(ctx):
    if ctx.attr.with_waveform:
        fail(("{}: `with_waveform = True` is not wired end-to-end. To " +
              "capture waveforms, add a `pre_hooks` Tcl script that " +
              "sets `xsim.simulate.log_all_signals` (and, if needed, " +
              "`xsim.simulate.wdb`) on the sim fileset before " +
              "`export_simulation` runs; any `.wdb` the run produces is " +
              "copied to `$TEST_UNDECLARED_OUTPUTS_DIR` automatically. " +
              "Silently accepting the flag while producing no waveform " +
              "was the prior behavior and is now rejected.").format(ctx.label))

    hdl = hdl_sources_data(ctx.attr.module)
    ip = ip_blocks_data(ctx.attr.ip_blocks)
    bd = block_designs_data(ctx.attr.block_designs)

    export_dir = ctx.actions.declare_directory("{}_export".format(ctx.label.name))
    project_dir = ctx.actions.declare_directory("{}_prj".format(ctx.label.name))

    sim_top = ctx.attr.module_top

    substitutions = {
        "{{BLOCK_DESIGNS}}": bd.block_designs,
        "{{EXPORT_DIR}}": export_dir.path,
        "{{HDL_SOURCES}}": hdl.hdl_sources,
        "{{IP_CONFIGURED_INSTANCES}}": ip.ip_configured_instances,
        "{{IP_INSTANCES}}": ip.ip_instances,
        "{{IP_REPOS}}": ip.ip_repos,
        "{{PART_NUMBER}}": ctx.attr.part_number,
        "{{POST_HOOKS}}": "{}",
        "{{PRE_HOOKS}}": "{}",
        "{{PROJECT_DIR}}": project_dir.path,
        "{{SIMULATOR}}": "xsim",
        "{{SIM_TOP}}": sim_top,
        "{{TCL_FILES}}": hdl.tcl_files,
        "{{XDC_FILES}}": hdl.xdc_files,
    }

    run_tcl_template(
        ctx = ctx,
        template = ctx.file.export_simulation_template,
        substitutions = substitutions,
        input_files = hdl.all_files + ip.input_files + bd.input_files,
        output_files = [export_dir, project_dir],
        mnemonic = "VivadoXSimExport",
    )

    for p in ctx.attr.error_patterns:
        _validate_xsim_pattern(ctx.label, "error_patterns", p)
    _validate_xsim_pattern(ctx.label, "completion_pattern", ctx.attr.completion_pattern)

    error_pattern_ere = "|".join(ctx.attr.error_patterns)
    completion_pattern_ere = ctx.attr.completion_pattern

    toolchain = ctx.toolchains[TOOLCHAIN_TYPE].vivado_info
    xilinx_env_short_path = toolchain.xilinx_env.short_path if toolchain.xilinx_env else ""

    env_lines = []
    for k, v in toolchain.env.items():
        env_lines.append("export {}={}".format(k, _bash_single_quote(v)))
    env_exports = "\n".join(env_lines)

    ctx.actions.expand_template(
        template = ctx.file.xsim_test_wrapper_template,
        output = ctx.outputs.executable,
        substitutions = {
            "{{COMPLETION_PATTERN}}": _bash_single_quote(completion_pattern_ere),
            "{{ENV_EXPORTS}}": env_exports,
            "{{ERROR_PATTERN}}": _bash_single_quote(error_pattern_ere),
            "{{EXPORT_DIR_SHORT_PATH}}": _bash_single_quote(export_dir.short_path),
            "{{TEST_NAME}}": _bash_single_quote(ctx.label.name),
            "{{XILINX_ENV_SHORT_PATH}}": _bash_single_quote(xilinx_env_short_path),
        },
        is_executable = True,
    )

    # Vivado's `export_simulation` copies only HDL sources into the export tree,
    # dropping `.mem` init files and other `data =` payloads. Stage every transitive
    # file so runtime references like `$readmemh "tests/foo/init.mem"` resolve.
    runfiles_files = [export_dir] + hdl.all_files + ip.input_files + bd.input_files
    if toolchain.xilinx_env:
        runfiles_files.append(toolchain.xilinx_env)

    return [
        DefaultInfo(
            executable = ctx.outputs.executable,
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
        coverage_common.instrumented_files_info(
            ctx,
            dependency_attributes = ["module", "ip_blocks", "block_designs"],
        ),
    ]

xsim_test = rule(
    doc = """Run a Vivado xsim simulation as a Bazel test.

A build action calls `export_simulation` to produce a self-contained xsim
script bundle; the test binary runs `simulate.sh` at test time. Log-scan
patterns catch `$error` output, which xsim prints but doesn't exit nonzero for.
The wrapper writes a JUnit XML at `$XML_OUTPUT_FILE` and copies the sim log,
per-tool logs, and any `.wdb` waveform into `$TEST_UNDECLARED_OUTPUTS_DIR`.
""",
    implementation = _xsim_test_impl,
    test = True,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "block_designs": attr.label_list(
            doc = "Block designs to fold into the exported sim.",
            providers = [VivadoBlockDesignInfo],
            default = [],
        ),
        "completion_pattern": attr.string(
            doc = ("ERE pattern the simulation log must match for the test " +
                   "to pass. Set to `\"\"` to disable. Only consulted when " +
                   "the driver script exited 0."),
            default = _DEFAULT_XSIM_COMPLETION_PATTERN,
        ),
        "error_patterns": attr.string_list(
            doc = ("ERE patterns that mark the simulation log as failed. " +
                   "Joined with `|` and passed to `grep -E`. Pass `[]` to " +
                   "disable log scanning. Patterns must not contain literal " +
                   "single quotes; use `[\\x27]` if you need to match one."),
            default = _DEFAULT_XSIM_ERROR_PATTERNS,
        ),
        "export_simulation_template": attr.label(
            doc = "The tcl template that drives `export_simulation` for xsim.",
            default = Label("//vivado/private:export_simulation.tcl.template"),
            allow_single_file = [".template"],
        ),
        "ip_blocks": attr.label_list(
            doc = "Ip blocks to include in this design.",
            providers = [VivadoIPBlockInfo],
            default = [],
        ),
        "module": attr.label(
            doc = "The top level build.",
            providers = [[VerilogInfo], [VhdlInfo]],
            mandatory = True,
        ),
        "module_top": attr.string(
            doc = "The name of the top-level module; set as the sim fileset top.",
            mandatory = True,
        ),
        "part_number": attr.string(
            doc = "The targeted xilinx part.",
            mandatory = True,
        ),
        "with_waveform": attr.bool(
            doc = ("Only `False` is accepted; `True` fails at analysis. To " +
                   "capture waveforms, add a `pre_hooks` Tcl script that " +
                   "sets `xsim.simulate.log_all_signals` on the sim fileset."),
            default = False,
        ),
        "xsim_test_wrapper_template": attr.label(
            doc = "Bash template driving the exported `simulate.sh` at test time.",
            default = Label("//vivado/private:xsim_test_wrapper.sh.template"),
            allow_single_file = [".template"],
        ),
    },
)

def _derive_export_simulation_top(ctx):
    """Resolve the simulation-fileset top; Vivado refuses `export_simulation` without one."""
    if ctx.attr.module_top:
        return ctx.attr.module_top

    bds = ctx.attr.block_designs
    ips = ctx.attr.ip_blocks

    # Vivado's `make_wrapper` names the auto-generated top `<bd>_wrapper`.
    if len(bds) == 1 and len(ips) == 0:
        return bds[0][VivadoBlockDesignInfo].module_top + "_wrapper"

    if len(bds) == 0 and len(ips) == 1:
        ip_info = ips[0][VivadoIPBlockInfo]
        if ip_info.configured_instance:
            return ip_info.configured_instance.module_top
        if ip_info.instantiable:
            return ip_info.instantiable.module_name

    fail(("`vivado_export_simulation` target `{label}` could not derive a " +
          "simulation top automatically. Set `module_top = \"<name>\"` " +
          "explicitly. (Auto-derive only handles a single `block_designs` " +
          "entry, or a single `ip_blocks` entry with either " +
          "`configured_instance` or `instantiable` set; got " +
          "{nbd} BD(s) + {nip} IP(s).)").format(
        label = ctx.label,
        nbd = len(bds),
        nip = len(ips),
    ))

def _vivado_export_simulation_impl(ctx):
    if ctx.attr.module:
        hdl = hdl_sources_data(ctx.attr.module)
        hdl_all_files = hdl.all_files
        hdl_sources_literal = hdl.hdl_sources
        xdc_files_literal = hdl.xdc_files
        tcl_files_literal = hdl.tcl_files
    else:
        hdl_all_files = []
        hdl_sources_literal = "{}"
        xdc_files_literal = "{}"
        tcl_files_literal = "{}"

    ip = ip_blocks_data(ctx.attr.ip_blocks)
    bd = block_designs_data(ctx.attr.block_designs)

    project_dir = ctx.actions.declare_directory("{}_prj".format(ctx.label.name))
    export_dir = ctx.actions.declare_directory(ctx.label.name)

    sim_top = _derive_export_simulation_top(ctx)

    pre_tcl = tcl_hooks_data(ctx.attr.pre_hooks)
    post_tcl = tcl_hooks_data(ctx.attr.post_hooks)
    pre_exec = exec_hooks_data(
        ctx.attr.pre_hook_tools,
        project_dir_path = project_dir.path,
        export_dir_path = export_dir.path,
    )
    post_exec = exec_hooks_data(
        ctx.attr.post_hook_tools,
        project_dir_path = project_dir.path,
        export_dir_path = export_dir.path,
    )

    substitutions = {
        "{{BLOCK_DESIGNS}}": bd.block_designs,
        "{{EXPORT_DIR}}": export_dir.path,
        "{{HDL_SOURCES}}": hdl_sources_literal,
        "{{IP_CONFIGURED_INSTANCES}}": ip.ip_configured_instances,
        "{{IP_INSTANCES}}": ip.ip_instances,
        "{{IP_REPOS}}": ip.ip_repos,
        "{{PART_NUMBER}}": ctx.attr.part_number,
        "{{POST_HOOKS}}": post_tcl.files_literal,
        "{{PRE_HOOKS}}": pre_tcl.files_literal,
        "{{PROJECT_DIR}}": project_dir.path,
        "{{SIMULATOR}}": ctx.attr.simulator,
        "{{SIM_TOP}}": sim_top,
        "{{TCL_FILES}}": tcl_files_literal,
        "{{XDC_FILES}}": xdc_files_literal,
    }

    merged_hook_env = dict(pre_exec.env)
    for k, v in post_exec.env.items():
        merged_hook_env[k] = v

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.export_simulation_template,
        substitutions = substitutions,
        input_files = (
            hdl_all_files + ip.input_files + bd.input_files +
            pre_tcl.input_files + post_tcl.input_files
        ),
        output_files = [project_dir, export_dir],
        mnemonic = "VivadoExportSimulation",
        pre_processing_command = pre_exec.command,
        post_processing_command = post_exec.command,
        hook_tools = pre_exec.tools + post_exec.tools,
        hook_env = merged_hook_env,
    )

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoExportSimulationInfo(
            export_dir = export_dir,
            simulator = ctx.attr.simulator,
        ),
    ]

vivado_export_simulation = rule(
    doc = """Run Vivado's `export_simulation` over IP / block designs (plus optional
user HDL) and stage the resulting directory as a TreeArtifact. The downstream
simulator is not run; consumers compose against `VivadoExportSimulationInfo`.
""",
    implementation = _vivado_export_simulation_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "block_designs": attr.label_list(
            doc = "Block designs whose IP runs should be included in the export.",
            providers = [VivadoBlockDesignInfo],
            default = [],
        ),
        "export_simulation_template": attr.label(
            doc = "The tcl template that drives `export_simulation`.",
            default = Label("//vivado/private:export_simulation.tcl.template"),
            allow_single_file = [".template"],
        ),
        "ip_blocks": attr.label_list(
            doc = "Packaged IP blocks to include in the export.",
            providers = [VivadoIPBlockInfo],
            default = [],
        ),
        "module": attr.label(
            doc = "Optional top-level HDL library to also stage into the project.",
            providers = [[VerilogInfo], [VhdlInfo]],
        ),
        "module_top": attr.string(
            doc = ("Top module set on the simulation fileset. Auto-derived to " +
                   "`<bd>_wrapper` for a single-BD export or to the IP's " +
                   "instance module for a single configured-IP export."),
            default = "",
        ),
        "part_number": attr.string(
            doc = "The Xilinx part the export targets; must match the BDs / IPs.",
            mandatory = True,
        ),
        "post_hook_tools": attr.label_list(
            doc = ("Executable targets invoked in the same Bazel action AFTER " +
                   "Vivado exits. Each receives `--project-dir <path> " +
                   "--export-dir <path>` and the same paths via " +
                   "`VIVADO_PROJECT_DIR` / `VIVADO_EXPORT_DIR` env vars. Order " +
                   "is preserved; first non-zero exit fails the action."),
            cfg = "exec",
            default = [],
        ),
        "post_hooks": attr.label_list(
            doc = ("`.tcl` files sourced inside Vivado at the end of the export " +
                   "body, with the project still open. Sourced in list order."),
            allow_files = [".tcl"],
            default = [],
        ),
        "pre_hook_tools": attr.label_list(
            doc = "Executable targets invoked BEFORE Vivado starts; see `post_hook_tools`.",
            cfg = "exec",
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = ("`.tcl` files sourced inside Vivado BEFORE the export body runs " +
                   "(before the project exists). Sourced in list order."),
            allow_files = [".tcl"],
            default = [],
        ),
        "simulator": attr.string(
            doc = "Target simulator for the export.",
            mandatory = True,
            values = _SIMULATOR_CHOICES,
        ),
    },
    provides = [
        DefaultInfo,
        VivadoExportSimulationInfo,
    ],
)

# Riviera-PRO and Active-HDL are independent FlexLM features on the same Aldec
# server, so they get separate pools. Simulators absent from this map get no
# license claim by default; callers override via `license_resource_name`.
_DEFAULT_LICENSE_RESOURCE_BY_SIMULATOR = {
    "activehdl": ("activehdl_license", 1),
    "riviera": ("riviera_license", 1),
}

# Per-simulator install-root env var and bin subdir. `compile_simlib` shells
# out to vsimsa AND its peer tools (vlib/vlog/vcom/etc.), so a single Bazel-
# tracked binary isn't enough. Mentor's `MODEL_TECH` is already the bin dir.
_INSTALL_ENV_VAR = {
    "activehdl": ("ALDEC_PATH", "/bin"),
    "ies": ("CDS_INST_DIR", "/tools/bin"),
    "modelsim": ("MODEL_TECH", ""),
    "questa": ("QUESTA_HOME", "/bin"),
    "riviera": ("RIVIERA_HOME", "/bin"),
    "vcs": ("VCS_HOME", "/bin"),
    "vcs_mx": ("VCS_HOME", "/bin"),
    "xcelium": ("CDS_INST_DIR", "/tools/bin"),
}

def _vivado_compile_simlib_impl(ctx):
    simlib_dir = ctx.actions.declare_directory(ctx.label.name)

    install_env_var, install_bin_subdir = _INSTALL_ENV_VAR[ctx.attr.simulator]

    substitutions = {
        "{{FAMILY}}": ctx.attr.family,
        "{{INSTALL_BIN_SUBDIR}}": install_bin_subdir,
        "{{INSTALL_ENV_VAR}}": install_env_var,
        "{{LANGUAGE}}": ctx.attr.language,
        "{{LIBRARY}}": ctx.attr.library,
        "{{NO_IP_COMPILE}}": "1" if ctx.attr.no_ip_compile else "0",
        "{{NO_SYSTEMC_COMPILE}}": "1" if ctx.attr.no_systemc_compile else "0",
        "{{SIMLIB_DIR}}": simlib_dir.path,
        "{{SIMULATOR}}": ctx.attr.simulator,
    }

    if ctx.attr.license_resource_name:
        resource_name = ctx.attr.license_resource_name
        count = ctx.attr.license_resource_count if ctx.attr.license_resource_count > 0 else 1
    elif ctx.attr.simulator in _DEFAULT_LICENSE_RESOURCE_BY_SIMULATOR:
        resource_name, count = _DEFAULT_LICENSE_RESOURCE_BY_SIMULATOR[ctx.attr.simulator]
    else:
        resource_name, count = "", 0

    extra_execution_requirements = {}
    if resource_name:
        extra_execution_requirements["resources:{}".format(resource_name)] = str(count)

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.compile_simlib_template,
        substitutions = substitutions,
        input_files = [],
        output_files = [simlib_dir],
        mnemonic = "VivadoCompileSimlib",
        extra_execution_requirements = extra_execution_requirements,
    )

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoCompiledSimlibInfo(
            simlib_dir = simlib_dir,
            simulator = ctx.attr.simulator,
        ),
    ]

vivado_compile_simlib = rule(
    doc = """Pre-compile the Xilinx baseline simulation libraries (`unisim`,
`unimacro`, `secureip`, `unifast`, ...) for a third-party simulator. Output is
a TreeArtifact at the layout `compile_simlib -directory <dir>` produces.

`compile_simlib` is hours of work for `-family all`; pass a specific silicon
family to bound the scope. The simulator install is located via an env-var
lookup on the exec platform (`$RIVIERA_HOME` for riviera, etc.) because
`compile_simlib` shells out to vsimsa AND its peer tools.
""",
    implementation = _vivado_compile_simlib_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "compile_simlib_template": attr.label(
            doc = "The tcl template that drives `compile_simlib`.",
            default = Label("//vivado/private:compile_simlib.tcl.template"),
            allow_single_file = [".template"],
        ),
        "family": attr.string(
            doc = ("Xilinx silicon family, passed to `compile_simlib -family <X>`. " +
                   "Common values: `all` (hours), `versal`, `kintexuplus`, `zynquplus`."),
            mandatory = True,
        ),
        "language": attr.string(
            doc = "HDL language, passed to `compile_simlib -language <X>`.",
            default = "all",
            values = ["all", "vhdl", "verilog"],
        ),
        "library": attr.string(
            doc = ("Simulation library set, passed to `compile_simlib -library <X>`. " +
                   "For families whose `all` set omits a needed library, compile " +
                   "that library in a second target with `no_ip_compile = True` " +
                   "and chain via `vmap -link` at consume time."),
            default = "all",
        ),
        "license_resource_count": attr.int(
            doc = ("Number of `license_resource_name` units to claim. Values <= 0 " +
                   "fall back to 1 when a resource name is set."),
            default = 0,
        ),
        "license_resource_name": attr.string(
            doc = ("FlexLM feature name to claim from Bazel's local resource pool. " +
                   "Callers wire the pool via `--local_extra_resources=<name>=N`. " +
                   "Overrides the built-in default map (activehdl, riviera). Empty " +
                   "falls back to that map."),
            default = "",
        ),
        "no_ip_compile": attr.bool(
            doc = ("Pass `-no_ip_compile`. Required on chained follow-up targets: " +
                   "Vivado rewrites `library.cfg` on each `compile_simlib`, so a " +
                   "later call's IP compile pass errors with `Library \"<baseline>\" " +
                   "not found` because the fresh `library.cfg` lacks the baseline " +
                   "mappings the IPs reference."),
            default = False,
        ),
        "no_systemc_compile": attr.bool(
            doc = ("Pass `-no_systemc_compile` (default true). The SystemC libs " +
                   "require a working SystemC install reachable by the simulator's " +
                   "C++ toolchain, which often isn't present in CI images."),
            default = True,
        ),
        "simulator": attr.string(
            doc = "Target simulator. `xsim` is built into Vivado and doesn't need precompile.",
            mandatory = True,
            values = sorted(_INSTALL_ENV_VAR.keys()),
        ),
    },
    provides = [
        DefaultInfo,
        VivadoCompiledSimlibInfo,
    ],
)
