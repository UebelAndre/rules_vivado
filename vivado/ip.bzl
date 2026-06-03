"""# IP packaging rules"""

load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load(
    "//vivado:providers.bzl",
    "VivadoIPBlockInfo",
    "VivadoInterfaceInfo",
)
load(
    "//vivado/private:common.bzl",
    "TOOLCHAIN_TYPE",
    "encrypt_data",
    "file_list",
    "get_vivado_toolchain",
    "hdl_sources_data",
    "ip_blocks_data",
    "run_tcl_template",
)

def _vivado_create_ip_impl(ctx):
    hdl = hdl_sources_data(ctx.attr.module)
    ip = ip_blocks_data(ctx.attr.ip_blocks)

    xci_name = ctx.label.name
    ip_dir = ctx.actions.declare_directory(ctx.label.name)

    outputs = [ip_dir]

    post_processing_command = ""
    if ctx.attr.encrypt:
        enc = encrypt_data(
            ctx = ctx,
            all_files = hdl.all_files,
            ip_dir_src = "{}/src/".format(ip_dir.path),
        )
        encrypt_files_literal = enc.encrypt_files
        outputs += enc.encrypted_outputs
        post_processing_command = enc.post_processing_command
    else:
        encrypt_files_literal = "{}"

    substitutions = {
        "{{ENCRYPT_FILES}}": encrypt_files_literal,
        "{{ENCRYPT_KEYFILE}}": ctx.file.keyfile.path,
        "{{HDL_SOURCES}}": hdl.hdl_sources,
        "{{IP_CONFIGURED_INSTANCES}}": ip.ip_configured_instances,
        "{{IP_INSTANCES}}": ip.ip_instances,
        "{{IP_LIBRARY}}": ctx.attr.ip_library,
        "{{IP_OUTPUT_DIR}}": ip_dir.path,
        "{{IP_REPOS}}": ip.ip_repos,
        "{{IP_VENDOR}}": ctx.attr.ip_vendor,
        "{{IP_VERSION}}": ctx.attr.ip_version,
        "{{JOBS}}": "{}".format(ctx.attr.jobs),
        "{{MODULE_TOP}}": ctx.attr.module_top,
        "{{PART_NUMBER}}": ctx.attr.part_number,
        "{{PROJECT_DIR}}": "./",
        "{{TCL_FILES}}": hdl.tcl_files,
        "{{XCI_NAME}}": xci_name,
        "{{XDC_FILES}}": hdl.xdc_files,
    }

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.create_ip_block_template,
        substitutions = substitutions,
        input_files = hdl.all_files + [ctx.file.keyfile] + ip.input_files,
        output_files = outputs,
        mnemonic = "VivadoCreateIp",
        jobs = ctx.attr.jobs,
        post_processing_command = post_processing_command,
    )

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoIPBlockInfo(
            repo = [ip_dir] + ip.input_files,
            configured_instance = None,
            instantiable = struct(
                vendor = ctx.attr.ip_vendor,
                library = ctx.attr.ip_library,
                name = ctx.attr.module_top,
                version = ctx.attr.ip_version,
                # Convention preserved from the previous helper: the
                # consumer's create_ip call names the instance
                # `<module_top>_ip` to disambiguate from the IP name.
                module_name = ctx.attr.module_top + "_ip",
            ),
        ),
        coverage_common.instrumented_files_info(
            ctx,
            dependency_attributes = ["module", "ip_blocks"],
        ),
    ]

vivado_create_ip = rule(
    implementation = _vivado_create_ip_impl,
    doc = "Use vivado to package a module into an IP core",
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "create_ip_block_template": attr.label(
            doc = "The create project tcl template",
            default = Label("//vivado/private:create_ip_block.tcl.template"),
            allow_single_file = [".template"],
        ),
        "encrypt": attr.bool(
            doc = "Encrypt the sources. Note: This requires a license. See: https://support.xilinx.com/s/article/68071?language=en_US",
            default = False,
        ),
        "ip_blocks": attr.label_list(
            doc = "Ip blocks to include in this design.",
            providers = [VivadoIPBlockInfo],
            default = [],
        ),
        "ip_library": attr.string(
            doc = "The version of this ip core.",
            mandatory = True,
        ),
        "ip_vendor": attr.string(
            doc = "The version of this ip core.",
            mandatory = True,
        ),
        "ip_version": attr.string(
            doc = "The version of this ip core.",
            mandatory = True,
        ),
        "jobs": attr.int(
            doc = "Jobs to pass to vivado which defines the amount of parallelism.",
            default = 4,
        ),
        "keyfile": attr.label(
            doc = "The keyfile to use when optionally encrypting",
            default = Label("//vivado/private:xilinx_keyfile.txt"),
            allow_single_file = [".txt"],
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
    },
    provides = [
        DefaultInfo,
        VivadoIPBlockInfo,
    ],
)

def _vivado_interface_definition_impl(ctx):
    """Implementation of vivado_interface_definition rule.

    Uses two chained actions:
      1. Parse SV file -> signals JSON (overridable parser)
      2. Generate XML/TCL from JSON + templates (internal generator)
    """
    name = ctx.attr.interface_name
    vendor = ctx.attr.vendor
    library = ctx.attr.library
    version = ctx.attr.version

    sv_file = ctx.file.src
    parser = ctx.executable.parser
    generator = ctx.executable._generator
    toolchain_env = get_vivado_toolchain(ctx).env

    signals_json = ctx.actions.declare_file("{}_signals.json".format(name))
    ctx.actions.run(
        executable = parser,
        arguments = ["--input", sv_file.path, "--output", signals_json.path],
        inputs = [sv_file],
        outputs = [signals_json],
        mnemonic = "VivadoParseInterface",
        progress_message = "Parsing SV interface %{label}",
        toolchain = TOOLCHAIN_TYPE,
        env = toolchain_env,
    )

    bus_def_file = ctx.actions.declare_file("{}.xml".format(name))
    abs_def_file = ctx.actions.declare_file("{}_rtl.xml".format(name))
    setup_tcl_file = ctx.actions.declare_file("{}_if_setup.tcl".format(name))

    description = ctx.attr.description if ctx.attr.description else ""

    ctx.actions.run(
        executable = generator,
        arguments = [
            "--signals-json",
            signals_json.path,
            "--bus-def-template",
            ctx.file.bus_definition_template.path,
            "--abs-def-template",
            ctx.file.abstraction_definition_template.path,
            "--setup-tcl-template",
            ctx.file.interface_setup_template.path,
            "--bus-def-output",
            bus_def_file.path,
            "--abs-def-output",
            abs_def_file.path,
            "--setup-tcl-output",
            setup_tcl_file.path,
            "--vendor",
            vendor,
            "--library",
            library,
            "--name",
            name,
            "--version",
            version,
            "--direct-connection",
            "true" if ctx.attr.direct_connection else "false",
            "--is-addressable",
            "true" if ctx.attr.is_addressable else "false",
            "--max-masters",
            str(ctx.attr.max_masters),
            "--max-slaves",
            str(ctx.attr.max_slaves),
            "--description",
            description,
        ],
        inputs = [
            signals_json,
            ctx.file.bus_definition_template,
            ctx.file.abstraction_definition_template,
            ctx.file.interface_setup_template,
        ],
        outputs = [bus_def_file, abs_def_file, setup_tcl_file],
        mnemonic = "VivadoGenInterfaceXml",
        progress_message = "Generating IP-XACT XML %{label}",
        toolchain = TOOLCHAIN_TYPE,
        env = toolchain_env,
    )

    outputs = [bus_def_file, abs_def_file, setup_tcl_file]

    return [
        DefaultInfo(files = depset(outputs)),
        VivadoInterfaceInfo(
            name = name,
            vendor = vendor,
            library = library,
            version = version,
            bus_definition = bus_def_file,
            abstraction_definition = abs_def_file,
            setup_tcl = setup_tcl_file,
        ),
    ]

vivado_interface_definition = rule(
    implementation = _vivado_interface_definition_impl,
    doc = "Generate Vivado IP-XACT interface definition files (bus definition and abstraction definition XML).",
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "abstraction_definition_template": attr.label(
            doc = "The abstraction definition XML template.",
            default = Label("//vivado/private:abstraction_definition.xml.template"),
            allow_single_file = [".template"],
        ),
        "bus_definition_template": attr.label(
            doc = "The bus definition XML template.",
            default = Label("//vivado/private:bus_definition.xml.template"),
            allow_single_file = [".template"],
        ),
        "description": attr.string(
            doc = "Description for the interface.",
            default = "",
        ),
        "direct_connection": attr.bool(
            doc = "Whether direct connections are allowed.",
            default = True,
        ),
        "interface_name": attr.string(
            doc = "The name of the interface (e.g., 'hbm_reader').",
            mandatory = True,
        ),
        "interface_setup_template": attr.label(
            doc = "The interface setup TCL template.",
            default = Label("//vivado/private:interface_setup.tcl.template"),
            allow_single_file = [".template"],
        ),
        "is_addressable": attr.bool(
            doc = "Whether the interface is addressable.",
            default = True,
        ),
        "library": attr.string(
            doc = "The library VLNV component (e.g., 'interface').",
            default = "interface",
        ),
        "max_masters": attr.int(
            doc = "Maximum number of masters.",
            default = 1,
        ),
        "max_slaves": attr.int(
            doc = "Maximum number of slaves.",
            default = 1,
        ),
        "parser": attr.label(
            doc = "Python parser script (SV -> JSON). Override to customize SV parsing.",
            default = Label("//vivado/private:parse_sv_interface"),
            cfg = "exec",
            executable = True,
        ),
        "src": attr.label(
            doc = "The SystemVerilog interface source file to parse.",
            mandatory = True,
            allow_single_file = [".sv"],
        ),
        "vendor": attr.string(
            doc = "The vendor VLNV component (e.g., 'mycompany.com').",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The version VLNV component (e.g., '1.0').",
            default = "1.0",
        ),
        "_generator": attr.label(
            default = Label("//vivado/private:generate_interface_xml"),
            cfg = "exec",
            executable = True,
        ),
    },
    provides = [
        DefaultInfo,
        VivadoInterfaceInfo,
    ],
)

def _vivado_create_interface_ip_impl(ctx):
    """Implementation of vivado_create_interface_ip rule."""
    interface_info = ctx.attr.interface[VivadoInterfaceInfo]

    ip_dir = ctx.actions.declare_directory(ctx.label.name)

    all_files = []
    if ctx.attr.module:
        hdl = hdl_sources_data(ctx.attr.module)
        all_files = hdl.all_files

    substitutions = {
        "{{ABSTRACTION_DEFINITION_FILE}}": interface_info.abstraction_definition.path,
        "{{BUS_DEFINITION_FILE}}": interface_info.bus_definition.path,
        "{{IP_OUTPUT_DIR}}": ip_dir.path,
    }

    input_files = [
        interface_info.bus_definition,
        interface_info.abstraction_definition,
    ] + all_files

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.create_interface_ip_template,
        substitutions = substitutions,
        input_files = input_files,
        output_files = [ip_dir],
        mnemonic = "VivadoCreateInterfaceIp",
    )

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoIPBlockInfo(
            repo = [ip_dir],
            # Interface definitions live in `repo` and are referenced by
            # name from other IPs / BDs — not instantiated via create_ip,
            # not added as a source. Repo-only.
            configured_instance = None,
            instantiable = None,
        ),
        # Propagate coverage instrumentation from the optional wrapped
        # module so a downstream test walking through this IP reaches
        # the underlying `verilog_library`/`vhdl_library` sources.
        coverage_common.instrumented_files_info(
            ctx,
            dependency_attributes = ["module"],
        ),
    ]

vivado_create_interface_ip = rule(
    implementation = _vivado_create_interface_ip_impl,
    doc = "Package a Vivado interface definition as an IP block. Unlike vivado_create_ip, this does not require a top module.",
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "create_interface_ip_template": attr.label(
            doc = "The TCL template for creating interface IP.",
            default = Label("//vivado/private:create_interface_ip.tcl.template"),
            allow_single_file = [".template"],
        ),
        "interface": attr.label(
            doc = "The interface definition to package.",
            providers = [VivadoInterfaceInfo],
            mandatory = True,
        ),
        "module": attr.label(
            doc = "The verilog_library containing the interface source file(s).",
            providers = [[VerilogInfo], [VhdlInfo]],
        ),
        "part_number": attr.string(
            doc = "The targeted xilinx part.",
            mandatory = True,
        ),
    },
    provides = [
        DefaultInfo,
        VivadoIPBlockInfo,
    ],
)

def _vivado_xci_impl(ctx):
    ip_dir = ctx.actions.declare_directory(ctx.label.name)

    pre_hooks_list, pre_hook_files = file_list(ctx.attr.pre_hooks)
    post_hooks_list, post_hook_files = file_list(ctx.attr.post_hooks)
    ip = ip_blocks_data(ctx.attr.ip_blocks)

    substitutions = {
        "{{IP_CONFIGURED_INSTANCES}}": ip.ip_configured_instances,
        "{{IP_DIR}}": ip_dir.path,
        "{{IP_INSTANCES}}": ip.ip_instances,
        "{{IP_REPOS}}": ip.ip_repos,
        "{{IP_SRC}}": ctx.file.src.path,
        "{{MODULE_TOP}}": ctx.attr.module_top,
        "{{PART_NUMBER}}": ctx.attr.part_number,
        "{{POST_HOOKS}}": post_hooks_list,
        "{{PRE_HOOKS}}": pre_hooks_list,
    }

    result = run_tcl_template(
        ctx = ctx,
        template = ctx.file.xci_template,
        substitutions = substitutions,
        input_files = (
            [ctx.file.src] + ip.input_files +
            pre_hook_files + post_hook_files +
            ctx.files.data
        ),
        output_files = [ip_dir],
        mnemonic = "VivadoXci",
        jobs = ctx.attr.jobs,
    )

    return [
        DefaultInfo(files = depset(result.outputs)),
        VivadoIPBlockInfo(
            repo = [ip_dir] + ip.input_files,
            # The .xci that was just generated lives at the top of `ip_dir`
            # (per the create_xci.tcl.template's flat copy of the source
            # IP tree). Consumers `add_files` it to bring the configured
            # instance into their project.
            configured_instance = struct(
                repo_dir = ip_dir,
                xci_relpath = ctx.attr.module_top + ".xci",
                module_top = ctx.attr.module_top,
            ),
            # The IP is already configured inside the .xci; consumers must
            # NOT call create_ip on it.
            instantiable = None,
        ),
    ]

vivado_xci = rule(
    doc = """Package a Xilinx-catalog IP from a configuration TCL into a \
consumable IP repo.

The `src` TCL is sourced inside a fresh Vivado project; it must call
`create_ip -name <ip> -vendor xilinx.com -library ip -version <ver> \\
    -module_name <module_top> -dir . -force` and (optionally) configure
the IP via `set_property -dict {...} [get_ips <module_top>]`. The
resulting `.xci` plus generated HDL/sim files are captured into a
TreeArtifact directory and exposed via `VivadoIPBlockInfo` so the IP
repo is auto-added to the consumer's `ip_repo_paths`.

Use the `ip_blocks` attribute on `vivado_synthesize`, `vivado_create_project`,
`vivado_block_design`, or `vivado_create_ip` to make this IP available to
that consumer. BD cells that reference the IP's VLNV (e.g.
`create_bd_cell -vlnv xilinx.com:ip:axi_dma:7.1`) will then resolve via
the catalog.

For your own HDL packaged as a new reusable IP, use `vivado_create_ip`
instead.
""",
    implementation = _vivado_xci_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "data": attr.label_list(
            doc = ("Additional files the IP-config TCL needs available in " +
                   "the action's sandbox. Each file is materialized at its " +
                   "workspace-relative path; the TCL can reference it via " +
                   "that path (e.g., to `exec patch -i ...` against the " +
                   "generated HDL, or to `read` a side data file). Same " +
                   "semantics as `cc_library.data`, `py_test.data`, etc."),
            allow_files = True,
            default = [],
        ),
        "ip_blocks": attr.label_list(
            doc = "Other IP blocks the configuration TCL depends on (rare; mostly empty).",
            providers = [VivadoIPBlockInfo],
            default = [],
        ),
        "jobs": attr.int(
            doc = "Jobs to pass to vivado (resource hint to Bazel's scheduler).",
            default = 1,
        ),
        "module_top": attr.string(
            doc = "The `module_name` passed to `create_ip` in `src`. Used to locate the produced `.xci`.",
            mandatory = True,
        ),
        "part_number": attr.string(
            doc = "Xilinx part number the IP is configured for.",
            mandatory = True,
        ),
        "post_hooks": attr.label_list(
            doc = "TCL files sourced after `generate_target`, before the project closes. Sourced in list order.",
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "pre_hooks": attr.label_list(
            doc = "TCL files sourced after project + IP-block setup, before sourcing the user IP TCL. Sourced in list order.",
            allow_files = [".tcl", ".xdc", ".sdc"],
            default = [],
        ),
        "src": attr.label(
            doc = "TCL script that calls `create_ip ... -module_name <module_top>` and (optionally) sets properties.",
            mandatory = True,
            allow_single_file = [".tcl"],
        ),
        "xci_template": attr.label(
            doc = "The XCI tcl template.",
            default = Label("//vivado/private:create_xci.tcl.template"),
            allow_single_file = [".template"],
        ),
    },
    provides = [
        DefaultInfo,
        VivadoIPBlockInfo,
    ],
)
