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
    "hdl_sources_data",
    "ip_blocks_data",
    "run_tcl_template",
)

# Vivado's `export_simulation -simulator` choices, as accepted by the
# 2024.2 / 2025.1 releases. Keep in sync with the Vivado UG835 reference.
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
    """Wrap `s` in single quotes for safe bash embedding.

    Any embedded single quotes are terminated, escaped as `\\'`, and
    re-opened — the classic `'"'"'` idiom expressed via string concatenation.
    """
    return "'" + s.replace("'", "'\\''") + "'"

def _xsim_test_impl(ctx):
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

    runfiles_files = [export_dir]
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

Two-phase: a build action calls Vivado's `export_simulation` to produce a
self-contained xsim script bundle for the design (compile.sh / elaborate.sh /
simulate.sh + source files, IP repos resolved). The test binary then runs
`simulate.sh` at `bazel test` time, so xsim's own exit code drives pass/fail
and the log-scan patterns are only a safety net for `$error` (which xsim
prints but doesn't exit nonzero for).

The wrapper writes a JUnit XML at `$XML_OUTPUT_FILE` and copies the sim log,
per-tool logs (`xsim.log`, `xelab.log`, `xvlog.log`), and any `.wdb` waveform
into `$TEST_UNDECLARED_OUTPUTS_DIR` — accessible via
`bazel-testlogs/<pkg>/<test>/test.outputs/outputs.zip`.
""",
    implementation = _xsim_test_impl,
    test = True,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "block_designs": attr.label_list(
            doc = ("Block designs (`vivado_block_design` targets) to fold " +
                   "into the exported sim. Each BD's IP runs are generated " +
                   "before `export_simulation` traces the sim source set."),
            providers = [VivadoBlockDesignInfo],
            default = [],
        ),
        "completion_pattern": attr.string(
            doc = ("ERE pattern the simulation log must match for the test " +
                   "to pass. Default `\\$finish` matches SystemVerilog's " +
                   "`$finish` system task, which the testbench should call " +
                   "on successful completion. Set to `\"\"` to disable the " +
                   "completion check (e.g. testbenches that rely solely on " +
                   "assertions and never call `$finish`). Only consulted " +
                   "when the driver script itself exited 0 — a nonzero " +
                   "exit already fails the test."),
            default = _DEFAULT_XSIM_COMPLETION_PATTERN,
        ),
        "error_patterns": attr.string_list(
            doc = ("ERE patterns that mark the simulation log as failed. " +
                   "Joined with `|` and passed to `grep -E`; matching any " +
                   "of them fails the test. Default set catches " +
                   "`$error`-formatted output (`^Error: `), Vivado/xsim " +
                   "`ERROR:` diagnostics, `FATAL_ERROR`, and SystemVerilog " +
                   "`$fatal`. Pass `[]` to disable log scanning entirely " +
                   "and rely solely on the driver's exit code (fine when " +
                   "the testbench uses `$fatal` for every failure path). " +
                   "Patterns must not contain literal single quotes; use " +
                   "`[\\x27]` if you need to match one."),
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
            doc = ("The name of the top-level module. Also set as the " +
                   "simulation fileset top before `export_simulation` runs."),
            mandatory = True,
        ),
        "part_number": attr.string(
            doc = "The targeted xilinx part.",
            mandatory = True,
        ),
        "with_waveform": attr.bool(
            doc = ("Accepted for source compatibility. Waveform capture is " +
                   "controlled by the exported `simulate.sh`'s default " +
                   "behavior; any `.wdb` written to the sim working dir is " +
                   "always copied to `$TEST_UNDECLARED_OUTPUTS_DIR`."),
            default = False,
        ),
        "xsim_test_wrapper_template": attr.label(
            doc = ("Bash template driving the exported `simulate.sh` at " +
                   "`bazel test` time. Overridable for callers that want " +
                   "to customize log capture, JUnit XML shape, or " +
                   "coverage post-processing."),
            default = Label("//vivado/private:xsim_test_wrapper.sh.template"),
            allow_single_file = [".template"],
        ),
    },
)

def _derive_export_simulation_top(ctx):
    """Resolve the simulation-fileset top for the export action.

    Vivado refuses `export_simulation` if the simulation fileset has no
    `top` set (`[exportsim-Tcl-70] A simulation top was not set`). The
    user can name one explicitly via `module_top`; when omitted, we
    auto-derive in the unambiguous cases (single BD: BD wrapper; single
    configured IP: IP instance module). Anything else fails analysis
    with a clear message so the user can set `module_top`.
    """
    if ctx.attr.module_top:
        return ctx.attr.module_top

    bds = ctx.attr.block_designs
    ips = ctx.attr.ip_blocks

    # Single BD, no IPs → wrap the BD. Vivado's `make_wrapper` convention
    # names the auto-generated top `<bd>_wrapper`, which is what synth
    # consumers reach for as well.
    if len(bds) == 1 and len(ips) == 0:
        return bds[0][VivadoBlockDesignInfo].module_top + "_wrapper"

    # Single configured IP, no BDs → the IP instance's module is the top.
    if len(bds) == 0 and len(ips) == 1:
        ip_info = ips[0][VivadoIPBlockInfo]
        if ip_info.configured_instance:
            return ip_info.configured_instance.module_top

    fail(("`vivado_export_simulation` target `{label}` could not derive a " +
          "simulation top automatically. Set `module_top = \"<name>\"` " +
          "explicitly. (Auto-derive only handles a single `block_designs` " +
          "entry, or a single configured `ip_blocks` entry; got " +
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

    substitutions = {
        "{{BLOCK_DESIGNS}}": bd.block_designs,
        "{{EXPORT_DIR}}": export_dir.path,
        "{{HDL_SOURCES}}": hdl_sources_literal,
        "{{IP_CONFIGURED_INSTANCES}}": ip.ip_configured_instances,
        "{{IP_INSTANCES}}": ip.ip_instances,
        "{{IP_REPOS}}": ip.ip_repos,
        "{{PART_NUMBER}}": ctx.attr.part_number,
        "{{PROJECT_DIR}}": project_dir.path,
        "{{SIMULATOR}}": ctx.attr.simulator,
        "{{SIM_TOP}}": sim_top,
        "{{TCL_FILES}}": tcl_files_literal,
        "{{XDC_FILES}}": xdc_files_literal,
    }

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.export_simulation_template,
        substitutions = substitutions,
        input_files = hdl_all_files + ip.input_files + bd.input_files,
        output_files = [project_dir, export_dir],
        mnemonic = "VivadoExportSimulation",
    )

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoExportSimulationInfo(
            export_dir = export_dir,
            simulator = ctx.attr.simulator,
        ),
    ]

vivado_export_simulation = rule(
    doc = """Run Vivado's `export_simulation` over a set of IP / block designs
(plus optional user HDL) and stage the resulting directory as a TreeArtifact.

The output is exactly what Vivado writes when you call
`export_simulation -simulator <sim> -directory <dir>` — see Vivado UG835 for
the authoritative layout. The rule performs no transforms beyond capturing
the directory.

The downstream simulator is not run; consumers compose against
`VivadoExportSimulationInfo` as they see fit.
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
            doc = ("Optional top-level HDL library to also stage into the " +
                   "project. Pass this when the export should include " +
                   "non-IP user sources (e.g. wrapper VHDL that " +
                   "instantiates the BD). Omit for IP-only exports."),
            providers = [[VerilogInfo], [VhdlInfo]],
        ),
        "module_top": attr.string(
            doc = ("Top module set on the simulation fileset before " +
                   "`export_simulation` runs (Vivado errors with " +
                   "`[exportsim-Tcl-70] A simulation top was not set` " +
                   "without it). Optional — auto-derived to " +
                   "`<bd>_wrapper` for a single-BD export or to the IP's " +
                   "instance module for a single configured-IP export. " +
                   "Set explicitly when the export combines multiple BDs/" +
                   "IPs or when a non-default wrapper is the intended sim " +
                   "top."),
            default = "",
        ),
        "part_number": attr.string(
            doc = "The Xilinx part the export targets. Must match the part " +
                  "the BDs / IPs were generated for.",
            mandatory = True,
        ),
        "simulator": attr.string(
            doc = ("Target simulator for the export. One of " +
                   "`activehdl`, `ies`, `modelsim`, `questa`, `riviera`, " +
                   "`vcs`, `vcs_mx`, `xcelium`, `xsim`. The output script " +
                   "name and dialect are simulator-specific."),
            mandatory = True,
            values = _SIMULATOR_CHOICES,
        ),
    },
    provides = [
        DefaultInfo,
        VivadoExportSimulationInfo,
    ],
)

# Built-in defaults for the floating-license resource that
# `vivado_compile_simlib` claims per simulator, so Bazel's local scheduler
# caps concurrent license check-outs. Each entry names the FlexLM feature
# being throttled (NOT the vendor) — Riviera-PRO and Active-HDL are
# independent FlexLM features on the same Aldec server, so they get
# separate pools. Downstream consumers declare matching
# `--local_extra_resources=<name>=N` to bound concurrency. Simulators not
# in this map get no license claim by default — either their license model
# isn't floating (xsim ships with Vivado), or their pool isn't modeled
# here. Callers can override or extend for any simulator via the
# `license_resource_name` / `license_resource_count` rule attrs; see
# `vivado_compile_simlib`.
_DEFAULT_LICENSE_RESOURCE_BY_SIMULATOR = {
    "activehdl": ("activehdl_license", 1),
    "riviera": ("riviera_license", 1),
}

# Per-simulator install-root env var the exec platform is expected to export.
# `compile_simlib` shells out to vsimsa AND its peer tools (vlib/vlog/vcom/
# etc.) — a single Bazel-tracked binary isn't enough. Until the full vendor
# install becomes a Bazel input, do an env-var lookup on the exec platform.
# Second tuple element is the bin subdir under the env root (most installs
# use `/bin`; Mentor's `MODEL_TECH` is already the bin dir, hence empty).
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
        "{{NO_SYSTEMC_COMPILE}}": "1" if ctx.attr.no_systemc_compile else "0",
        "{{SIMLIB_DIR}}": simlib_dir.path,
        "{{SIMULATOR}}": ctx.attr.simulator,
    }

    # A non-empty `license_resource_name` overrides the default map for
    # any simulator. An empty name (the attr default) falls back to the
    # default map entry, if any.
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
    doc = """Pre-compile the Xilinx baseline simulation libraries
(`unisim`, `unimacro`, `secureip`, `unifast`, …) for a third-party
simulator. Output is a TreeArtifact at the layout Vivado's
`compile_simlib -directory <dir>` produces — for Aldec sims that's
`<simlib_dir>/<simulator>/library.cfg` plus per-library subdirectories.

This is a one-time(-per-version) precompile cost; downstream cocotb /
xsim_test / vsimsa-driven simulations link the simlib via the
simulator's link mechanism (Aldec: `vmap -link`) so user code that
references `library unisim;` resolves without recompiling Xilinx's
HDL on every test.

`compile_simlib` is hours of work for `-family all`; pass a specific
silicon family (`versal`, `kintexuplus`, `zynquplus`, …) to bound the
scope. Valid family names come from Vivado's `compile_simlib -family`
docs — they vary by Vivado release, so consult UG973 for your install.

The simulator install is located via an env-var lookup on the exec
platform (`$RIVIERA_HOME` for riviera, `$QUESTA_HOME` for questa, etc.).
Vivado's `compile_simlib` shells out to vsimsa AND its peer tools
(vlib/vlog/vcom/...), so a single Bazel-tracked binary isn't enough;
once the full install becomes a Bazel input we can pass it via
`-simulator_exec_path` directly.
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
            doc = ("Xilinx silicon family to compile for. Passed to " +
                   "`compile_simlib -family <X>`. Common values: `all` " +
                   "(hours), `versal`, `kintexuplus`, `zynquplus`. " +
                   "Exact set of accepted families depends on the Vivado " +
                   "release; see UG973 for your install."),
            mandatory = True,
        ),
        "language": attr.string(
            doc = ("HDL language to compile. Passed to `compile_simlib " +
                   "-language <X>`. `all` compiles both VHDL and Verilog/SV " +
                   "libraries; `vhdl` or `verilog` restricts to one. " +
                   "Default `all` matches Vivado's own default."),
            default = "all",
            values = ["all", "vhdl", "verilog"],
        ),
        "library": attr.string(
            doc = ("Subset of Xilinx baseline libraries to compile. Passed " +
                   "to `compile_simlib -library <X>`. `all` compiles every " +
                   "library (`unisim`, `unimacro`, `secureip`, `unifast`, " +
                   "…); pass a comma-separated list to compile a subset " +
                   "(e.g. `unisim,unimacro` skips secureip / unifast and " +
                   "shrinks the simlib substantially)."),
            default = "all",
        ),
        "license_resource_count": attr.int(
            doc = ("Number of `license_resource_name` units the action " +
                   "claims (usually 1). Ignored when the effective " +
                   "resource name is empty. Values <= 0 fall back to 1 " +
                   "when a resource name is set."),
            default = 0,
        ),
        "license_resource_name": attr.string(
            doc = ("FlexLM feature name to claim from Bazel's local " +
                   "resource pool while this action runs. Callers wire " +
                   "the matching pool size via `--local_extra_resources=" +
                   "<name>=N` so parallel Bazel actions don't oversubscribe " +
                   "a floating license. Overrides the built-in default map " +
                   "(currently `activehdl` -> `activehdl_license`, " +
                   "`riviera` -> `riviera_license`). Set explicitly for any " +
                   "simulator whose license pool isn't in the default map " +
                   "(questa, vcs, xcelium, ies, etc.). Empty (the default) " +
                   "means \"use whatever the default map has for " +
                   "`simulator`, if anything.\""),
            default = "",
        ),
        "no_systemc_compile": attr.bool(
            doc = ("If true (default), pass `-no_systemc_compile` to skip " +
                   "the SystemC TLM/AXI libraries. The SystemC libs require " +
                   "a working SystemC install reachable by the simulator's " +
                   "C++ toolchain, which often isn't present in CI images " +
                   "and causes spurious build failures. Flip to false when " +
                   "your tests need the SystemC libs (HBM TLM models, NoC " +
                   "SystemC sims, etc.)."),
            default = True,
        ),
        "simulator": attr.string(
            doc = ("Target simulator. One of `activehdl`, `ies`, `modelsim`, " +
                   "`questa`, `riviera`, `vcs`, `vcs_mx`, `xcelium`. " +
                   "(`xsim` is the Vivado built-in and doesn't need precompile.)"),
            mandatory = True,
            values = sorted(_INSTALL_ENV_VAR.keys()),
        ),
    },
    provides = [
        DefaultInfo,
        VivadoCompiledSimlibInfo,
    ],
)
