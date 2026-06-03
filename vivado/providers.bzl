"""# Vivado providers."""

VivadoSynthCheckpointInfo = provider(
    doc = "Contains information at output of synthesis.",
    fields = {
        "checkpoint": "File: a Vivado synthesis checkpoint (.dcp).",
        "impl_xdc": (
            "Optional[File]: Bundle of XDC content from source files that " +
            "were marked `USED_IN_IMPLEMENTATION == True` (and " +
            "`IS_GENERATED == False`) in the upstream synth project. " +
            "These are IP-supplied constraints that target post-synth " +
            "physical resources (LOC, CLOCK_REGION, BUFG_GT placement, " +
            "GT_QUAD_BASE pins) — `synth_design` does not apply them, " +
            "and `write_checkpoint` only persists already-applied " +
            "constraints. Downstream phases that consume this checkpoint " +
            "via `open_checkpoint` will be missing those constraints " +
            "unless they re-read this bundle before `opt_design` / " +
            "`place_design`. The bundle is a concatenation of the source " +
            "XDC files in `get_files` order, suitable for a single " +
            "`read_xdc <bundle>` call. May be `None` when produced by a " +
            "rule that has no source project to inspect; consumers must " +
            "tolerate that case."
        ),
        "module_top": (
            "Optional[str]: Name of the top-level module synthesized into " +
            "the checkpoint. Downstream phases that drop the project " +
            "wrapper (`read_checkpoint` + `link_design -top <name>`, the " +
            "non-project re-elaboration path) need the name explicitly. " +
            "May be `\"\"` when produced by a rule that does not have a " +
            "single named top; consumers fall back to `open_checkpoint`."
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
    doc = ("Describes the contents of a Vivado IP artifact. Consumers " +
           "(typically `vivado_synthesize` and friends) read the fields to " +
           "decide what to do — call `create_ip`, `add_files` a configured " +
           "`.xci`, or just expose the repo on `ip_repo_paths`. The provider " +
           "describes what's in the artifact, not what the consumer must do."),
    fields = {
        "configured_instance": (
            "Optional[struct(repo_dir: File, xci_relpath: str, module_top: str)]: " +
            "Set when this artifact contains a pre-configured IP instance. " +
            "`repo_dir` is the TreeArtifact holding the instance (also " +
            "appears in `repo`); `xci_relpath` is the path of the `.xci` " +
            "file inside `repo_dir`; `module_top` is the instance's module " +
            "name. Consumers add the `.xci` to their source set so the IP " +
            "is synthesized as part of the design. None when the artifact " +
            "is just a catalog directory with no configured instance."
        ),
        "instantiable": (
            "Optional[struct(vendor: str, library: str, name: str, " +
            "version: str, module_name: str)]: Set when this artifact " +
            "packages an IP that consumers are expected to bring into " +
            "their project via `create_ip` using these VLNV identifiers " +
            "(`vendor:library:name:version`) with `-module_name = " +
            "<module_name>`. None when the artifact isn't intended for " +
            "fresh-instantiation use (vendor catalogs, configured instances, " +
            "interface definitions)."
        ),
        "repo": ("list[File]: Directory artifacts forming an IP repository — " +
                 "typically a tree rooted at one or more `component.xml` files. " +
                 "Always added to the consuming project's `ip_repo_paths`."),
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
    doc = ("Aggregated Vivado `-log` (`.log`) and `-journal` (`.jou`) " +
           "files for a phase target and all its transitive upstream phases. " +
           "The Vivado flow is linear (synth → synth_opt → place → place_opt " +
           "→ route → write_device_image), so every phase rule pulls the " +
           "upstream's `logs` / `journals` dicts from its checkpoint input " +
           "and adds its own entry. The terminal phase's provider therefore " +
           "carries the entire chain — a downstream bundler can read just " +
           "the `write_device_image` target and stage one file per phase " +
           "without enumerating each phase by hand. Keys are short phase " +
           "names (`synth`, `synth_opt`, `place`, `place_opt`, `route`, " +
           "`write_device_image`, `write_bitstream`)."),
    fields = {
        "journals": "dict[str, File]: phase name → journal File.",
        "logs": "dict[str, File]: phase name → log File.",
    },
)

VivadoReportsInfo = provider(
    doc = ("Maps the `reports` attr's caller-chosen output names to the " +
           "declared File objects so downstream rules can place each report " +
           "at a known path without relying on basename matching. Returned " +
           "by every phase rule that exposes a `reports` attribute."),
    fields = {
        "reports": "dict[str, File]: caller-chosen output filename → declared File.",
    },
)

VivadoExportSimulationInfo = provider(
    doc = ("Output of `vivado_export_simulation` — the directory Vivado " +
           "writes when invoked with `export_simulation -directory <dir>`. " +
           "Contents follow Vivado's contract for the chosen simulator " +
           "(see UG835)."),
    fields = {
        "export_dir": "File: TreeArtifact directory containing the export.",
        "simulator": ("string: The `-simulator` argument that was passed " +
                      "to Vivado. Consumers use it to confirm an artifact " +
                      "matches the simulator they're about to run."),
    },
)

VivadoCompiledSimlibInfo = provider(
    doc = ("Output of `vivado_compile_simlib`. The simlib directory is a " +
           "TreeArtifact holding the Xilinx baseline simulation libraries " +
           "(`unisim`, `unimacro`, `secureip`, `unifast`, …) compiled for " +
           "one third-party simulator. Layout matches Vivado's " +
           "`compile_simlib -directory <dir>` output: `<simlib_dir>/<simulator>/` " +
           "contains the simulator's link-config file (Aldec: `library.cfg`) " +
           "plus the per-library compiled artifacts. Downstream test wrappers " +
           "consume this provider to attach the simlib to their simulator's " +
           "library set via the simulator's link mechanism (Aldec: " +
           "`vmap -link`)."),
    fields = {
        "simlib_dir": ("File: TreeArtifact directory containing the " +
                       "compiled simlib. The simulator-conventional " +
                       "link-config file lives at " +
                       "`<simlib_dir>/<simulator>/<link_config_basename>` " +
                       "(e.g. `<simlib_dir>/riviera/library.cfg`)."),
        "simulator": ("string: The simulator the simlib targets. One of " +
                      "Vivado's `compile_simlib -simulator` choices."),
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
