"""Pre-packaged IP rule: vivado_packaged_ip.

Wraps a directory of files containing a Vivado-packaged IP (a tree rooted at
one or more `component.xml` files) into a `VivadoIPBlockInfo` target. No
Vivado action — the IP is already packaged; the rule just stages the files
into a TreeArtifact so consumers can add the directory to their
`ip_repo_paths`.

Use this for third-party / vendor-supplied IPs that ship as a directory
(e.g. SoC-e, Northwest Logic). For Xilinx-catalog IPs configured via a
`create_ip` TCL, use `vivado_xci`. For your own HDL packaged as a new IP,
use `vivado_create_ip`.

The produced `VivadoIPBlockInfo` has `configured_instance = None` and
`instantiable = None`, so the `ip_blocks_data` helper adds the repo to
`ip_repo_paths` without trying to call `create_ip` or `add_files` against
it — the IP is already in the repo.

# Consumption patterns

## Vendored (IP files checked into the source tree)

```starlark
# fpga/third_party/managed_ethernet_switch/ip/BUILD.bazel
load("@rules_vivado//vivado:packaged_ip.bzl", "vivado_packaged_ip")

vivado_packaged_ip(
    name = "managed_ethernet_switch_repo",
    srcs = glob(["managed_ethernet_switch/**"]),
    visibility = ["//visibility:public"],
)
```

## External via `http_archive` (or any custom repository rule)

In MODULE.bazel:

```starlark
http_archive(
    name = "soc_e_managed_ethernet_switch",
    urls = ["https://your.vendor.portal/managed_ethernet_switch-23.01.tar.gz"],
    sha256 = "...",
    strip_prefix = "managed_ethernet_switch-23.01",
    build_file_content = '''
load("@rules_vivado//vivado:packaged_ip.bzl", "vivado_packaged_ip")
vivado_packaged_ip(
    name = "repo",
    srcs = glob(["**/*"]),
    visibility = ["//visibility:public"],
)
''',
)
```

Custom repository rules generating their own BUILD files use the same shape.
The rule is intentionally repository-agnostic — it derives staging structure
from `ctx.label.package` plus each `src`'s path, so the same call works
identically in the main repo or in any external repo.

## `hdl_libraries` — composing with gazelle-generated HDL targets

When the HDL inside an IP directory is already declared as `vhdl_library` /
`verilog_library` targets (e.g. when a gazelle HDL extension has walked the subtree
and emitted one library per `.vhd` / `.sv` file), the same labels can feed
both IP packaging here AND downstream simulation — no need to vendor-glob
the HDL twice or maintain two parallel source lists.

```starlark
load("@rules_vivado//vivado:packaged_ip.bzl", "vivado_packaged_ip")

vivado_packaged_ip(
    name = "managed_ethernet_switch_repo",
    # Non-HDL: component.xml, XGUI TCL, vendor scripts.
    srcs = glob([
        "managed_ethernet_switch/component.xml",
        "managed_ethernet_switch/xgui/**",
        "managed_ethernet_switch/**/*.tcl",
    ]),
    # HDL: every gazelle-generated library label whose sources should
    # land in the staged repo. The rule walks `VhdlInfo`/`VerilogInfo`
    # transitively and stages each file at its package-relative path.
    hdl_libraries = [
        ":inbound_parser",
        ":ingress_rate_limit",
        ":pattern_filter",
        # ... etc, or a single aggregate :all_hdl target if you prefer.
    ],
    visibility = ["//visibility:public"],
)
```

The same `:inbound_parser` label is what a sibling cocotb / vunit test depends
on for its DUT, so the source set never drifts between sim and IP packaging.

## `strip_prefix` when the BUILD file isn't at the IP repo root

If the BUILD file sits above the IP's directory (e.g. a vendor tarball
extracts to `vendor-23.01/ip/<ip>/...` and you put one BUILD at the
`vendor-23.01/` root):

```starlark
vivado_packaged_ip(
    name = "repo",
    srcs = glob(["ip/<ip>/**"]),
    strip_prefix = "ip",  # stage as <ip>/component.xml instead of ip/<ip>/component.xml
)
```

`strip_prefix` mirrors `http_archive.strip_prefix` semantics. It's optional —
Vivado walks `ip_repo_paths` recursively for `component.xml`, so the staged
depth doesn't affect correctness, only hygiene.
"""

load("@rules_verilog//verilog:defs.bzl", "VerilogInfo")
load("@rules_vhdl//vhdl:defs.bzl", "VhdlInfo")
load("//vivado:providers.bzl", "VivadoIPBlockInfo")
load("//vivado:toolchain.bzl", "TOOLCHAIN_TYPE")
load("//vivado/private:common.bzl", "hdl_sources_data")

def _stage_relpath(short_path, package, strip_prefix):
    """Compute where `short_path` should land in the staged TreeArtifact.

    For a file in the main repo: `short_path` is workspace-relative
    ("<package>/<sub>").  For a file in an external repo: it's
    "../<repo_name>/<package>/<sub>".  In either case, the staging path
    is `<sub>` (modulo `strip_prefix`).
    """
    parts = short_path.split("/")
    pkg_parts = package.split("/") if package else []

    # Locate `pkg_parts` as a contiguous sub-sequence in `parts`; the tail
    # after that match is the package-relative path. For top-level packages
    # (empty `pkg_parts`), also strip a leading "../<repo>/" if present.
    rel_parts = None
    if pkg_parts:
        for i in range(len(parts) - len(pkg_parts) + 1):
            if parts[i:i + len(pkg_parts)] == pkg_parts:
                rel_parts = parts[i + len(pkg_parts):]
                break
    elif parts[:1] == [".."] and len(parts) >= 2:
        rel_parts = parts[2:]
    else:
        rel_parts = parts

    if rel_parts == None:
        # Source isn't under the rule's package — fall back to the basename
        # so the file is at least staged, even if its location is weird.
        rel_parts = [parts[-1]]

    if strip_prefix:
        strip_parts = strip_prefix.strip("/").split("/")
        if rel_parts[:len(strip_parts)] == strip_parts:
            rel_parts = rel_parts[len(strip_parts):]

    return "/".join(rel_parts)

def _vivado_packaged_ip_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name)
    package = ctx.label.package

    # `srcs` carries non-HDL files (component.xml, XGUI TCL, vendor
    # scripts) plus — for back-compat — HDL when no `hdl_libraries`
    # input is used. `hdl_libraries` walks `VhdlInfo`/`VerilogInfo` to
    # collect HDL `File`s with the same staging-path semantics as
    # `srcs`. Combining the two lets a consumer mix the gazelle-typed
    # HDL set with hand-globbed non-HDL files in the same target.
    hdl_files = []
    for lib in ctx.attr.hdl_libraries:
        hdl_files.extend(hdl_sources_data(lib).all_files)
    all_input_files = ctx.files.srcs + hdl_files

    if not all_input_files:
        fail(
            "{label}: vivado_packaged_ip needs at least one of `srcs` or " +
            "`hdl_libraries` to be non-empty.".format(label = ctx.label),
        )

    # Build (src_exec_path, staging_rel_path) pairs.
    entries = []
    for f in all_input_files:
        rel = _stage_relpath(f.short_path, package, ctx.attr.strip_prefix)
        entries.append((f.path, rel))

    # Generate an inline shell command: mkdir -p for each unique destination
    # dir (once), then `cp -L` per file. `-L` dereferences symlinks so the
    # staged tree contains real files rather than chains back to source.
    cmd_lines = ["mkdir -p " + out_dir.path]
    seen_dirs = {}
    for src, dst in entries:
        full_dst = out_dir.path + "/" + dst if dst else out_dir.path + "/" + src.rsplit("/", 1)[-1]
        if "/" in dst:
            dst_dir = out_dir.path + "/" + dst.rsplit("/", 1)[0]
        else:
            dst_dir = out_dir.path
        if dst_dir not in seen_dirs:
            cmd_lines.append("mkdir -p " + dst_dir)
            seen_dirs[dst_dir] = True
        cmd_lines.append("cp -L {} {}".format(src, full_dst))

    ctx.actions.run_shell(
        outputs = [out_dir],
        inputs = all_input_files,
        command = " && ".join(cmd_lines),
        progress_message = "Staging packaged IP repo: %{label}",
        mnemonic = "VivadoPackagedIp",
        toolchain = TOOLCHAIN_TYPE,
        env = ctx.toolchains[TOOLCHAIN_TYPE].vivado_info.env,
    )

    return [
        DefaultInfo(files = depset([out_dir])),
        VivadoIPBlockInfo(
            repo = [out_dir],
            # A pre-packaged IP repository may contain one or more catalog
            # entries (.xml-rooted IPs). Consumers reference them by VLNV
            # from elsewhere (typically a BD's create_bd_cell) — nothing
            # to add to the consumer's source set, and no fresh
            # instantiation is intended at this layer.
            configured_instance = None,
            instantiable = None,
        ),
    ]

vivado_packaged_ip = rule(
    doc = """Wrap a pre-packaged Vivado IP directory as a consumable IP repo.

Stages each file in `srcs` into a TreeArtifact, preserving its path
relative to the rule's package (with optional `strip_prefix` applied), and
exposes the staged directory via `VivadoIPBlockInfo.repo`. Consumers list
the target in their `ip_blocks` attr; the existing IP-block plumbing adds
the directory to `ip_repo_paths` in the consumer's project so any
`create_ip` calls referencing the IP's VLNV resolve via the catalog.

The rule is repository-agnostic: it works identically in the main repo,
inside an `http_archive`-fetched external repo, or in any custom
repository rule's generated BUILD file. See the module docstring for
worked examples of each pattern.
""",
    implementation = _vivado_packaged_ip_impl,
    toolchains = [TOOLCHAIN_TYPE],
    attrs = {
        "hdl_libraries": attr.label_list(
            doc = "HDL libraries whose transitive sources contribute to the staged IP tree. Walks `VhdlInfo` / `VerilogInfo` providers and stages each `File` at its package-relative path under the staged root (same path computation as `srcs`).",
            providers = [[VerilogInfo], [VhdlInfo]],
            allow_empty = True,
        ),
        "srcs": attr.label_list(
            doc = "Files under the IP repo root — typically the non-HDL portion: `component.xml`, `xgui/**`, vendor TCL scripts.",
            allow_files = True,
        ),
        "strip_prefix": attr.string(
            doc = "Optional package-relative prefix to strip from each src's staging path. Mirrors `http_archive.strip_prefix` semantics. Use when the BUILD file is at a higher level than the IP repo root and you want a flatter staged tree. Vivado walks `ip_repo_paths` recursively for `component.xml`, so this is hygiene/predictability only — leaving it empty doesn't affect correctness.",
            default = "",
        ),
    },
    provides = [
        DefaultInfo,
        VivadoIPBlockInfo,
    ],
)
