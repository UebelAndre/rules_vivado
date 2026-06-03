"""# Vivado providers."""

VivadoSynthCheckpointInfo = provider(
    doc = "Contains information at output of synthesis.",
    fields = {
        "checkpoint": "File: a Vivado synthesis checkpoint (.dcp).",
        "impl_xdc": (
            "Optional[File]: Bundle of XDC content from source files marked " +
            "`USED_IN_IMPLEMENTATION == True`. `synth_design` doesn't apply " +
            "these and `write_checkpoint` only persists applied constraints, " +
            "so downstream phases must `read_xdc <bundle>` before " +
            "`opt_design` / `place_design` or the constraints are lost. " +
            "May be `None`; consumers must tolerate that case."
        ),
        "module_top": (
            "Optional[str]: Name of the top-level module in the checkpoint. " +
            "Needed by downstream phases that use `link_design -top <name>` " +
            "instead of `open_checkpoint`. May be `\"\"`."
        ),
    },
)

VivadoPlacementCheckpointInfo = provider(
    doc = "Contains information at output of placement.",
    fields = {
        "checkpoint": "File: a Vivado placement checkpoint (.dcp).",
    },
)

VivadoRoutingCheckpointInfo = provider(
    doc = "Contains information at output of routing.",
    fields = {
        "checkpoint": "File: a Vivado post-route checkpoint (.dcp).",
    },
)

VivadoIPBlockInfo = provider(
    doc = "Describes the contents of a Vivado IP artifact. Consumers read the fields to decide whether to call `create_ip`, `add_files` a configured `.xci`, or just expose the repo on `ip_repo_paths`.",
    fields = {
        "configured_instance": (
            "Optional[struct(repo_dir: File, xci_relpath: str, module_top: str)]: " +
            "Set when the artifact contains a pre-configured IP instance. " +
            "Consumers add `<repo_dir>/<xci_relpath>` to their source set. " +
            "None when there is no configured instance."
        ),
        "instantiable": (
            "Optional[struct(vendor: str, library: str, name: str, " +
            "version: str, module_name: str)]: Set when consumers are " +
            "expected to `create_ip` with these VLNV identifiers and " +
            "`-module_name <module_name>`. None otherwise."
        ),
        "repo": "list[File]: Directory artifacts forming an IP repository (`component.xml`-rooted tree). Added to the consuming project's `ip_repo_paths`.",
    },
)

VivadoBlockDesignInfo = provider(
    doc = "Info for a Vivado block design (.bd) produced by `vivado_block_design`.",
    fields = {
        "bd_dir": "File: tree-artifact directory containing the generated `.bd` and its supporting files. The `.bd` itself is normalized to `<bd_dir>/<module_top>.bd` by the rule.",
        "ip_block_repos": "list[File]: IP repo directories from `ip_blocks` deps that must be added to the consuming project's `ip_repo_paths` for the BD to resolve.",
        "module_top": "string: The block-design name (the argument to `create_bd_design` in the source TCL). Consumers use `<bd_dir>/<module_top>.bd` to find the file.",
    },
)

VivadoLogInfo = provider(
    doc = "Aggregated Vivado `.log` and `.jou` files for a phase target and all its transitive upstream phases. Keys are short phase names (`synth`, `synth_opt`, `place`, `place_opt`, `route`, `write_bitstream`, `write_device_image`).",
    fields = {
        "journals": "dict[str, File]: phase name → journal File.",
        "logs": "dict[str, File]: phase name → log File.",
    },
)

VivadoReportsInfo = provider(
    doc = "Maps the `reports` attr's caller-chosen output names to the declared File objects.",
    fields = {
        "reports": "dict[str, File]: caller-chosen output filename → declared File.",
    },
)

VivadoExportSimulationInfo = provider(
    doc = "Output of `vivado_export_simulation` — the directory Vivado writes when invoked with `export_simulation -directory <dir>`. Contents follow Vivado's contract for the chosen simulator (see UG835).",
    fields = {
        "export_dir": "File: TreeArtifact directory containing the export.",
        "simulator": "string: The `-simulator` argument passed to Vivado.",
    },
)

VivadoCompiledSimlibInfo = provider(
    doc = "Output of `vivado_compile_simlib`. Layout matches `compile_simlib -directory <dir>`: `<simlib_dir>/<simulator>/` contains the simulator's link-config file plus per-library compiled artifacts.",
    fields = {
        "simlib_dir": "File: TreeArtifact directory containing the compiled simlib. The link-config file lives at `<simlib_dir>/<simulator>/<link_config_basename>` (e.g. `<simlib_dir>/riviera/library.cfg`).",
        "simulator": "string: The simulator the simlib targets. One of Vivado's `compile_simlib -simulator` choices.",
    },
)

VivadoInterfaceInfo = provider(
    doc = "Info for a Vivado IP-XACT interface definition",
    fields = {
        "abstraction_definition": "File: The abstraction definition XML file.",
        "bus_definition": "File: The bus definition XML file.",
        "library": "string: The library VLNV component.",
        "name": "string: The interface name.",
        "setup_tcl": "File: The TCL setup file for IP packaging.",
        "vendor": "string: The vendor VLNV component.",
        "version": "string: The version VLNV component.",
    },
)
