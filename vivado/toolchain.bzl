"""# Toolchain for the Xilinx Vivado tool.

Defines `VivadoToolchainInfo` and the `vivado_toolchain` rule. Register an
instance against `//vivado:toolchain_type` so every `vivado_*` rule resolves
the Xilinx environment automatically. Multiple instances can be registered
side-by-side and selected via `exec_compatible_with` against the per-version
`constraint_value`s in `//vivado/constraints/BUILD.bazel`.
"""

TOOLCHAIN_TYPE = str(Label("//vivado:toolchain_type"))

VivadoToolchainInfo = provider(
    doc = "Toolchain info for the Xilinx Vivado tool.",
    fields = {
        "env": "dict[str, str]: environment variables passed to every Vivado action.",
        "requires_network": "bool: whether Vivado actions need network access (typically for a network license server).",
        "version": "str: The version of Vivado associated with this toolchain.",
        "vivado": "FilesToRunProvider: executable Bazel invokes for every Vivado action. Typically a shim that `exec`s the real `vivado` binary.",
        "xilinx_env": "File or None: optional shell script sourced immediately before `vivado` runs, for shell-side env composition `env` cannot express.",
    },
)

def _vivado_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            vivado_info = VivadoToolchainInfo(
                vivado = ctx.attr.vivado[DefaultInfo].files_to_run,
                xilinx_env = ctx.file.xilinx_env,
                requires_network = ctx.attr.requires_network,
                env = ctx.attr.env,
                version = ctx.attr.version,
            ),
        ),
    ]

vivado_toolchain = rule(
    doc = """Declares a Vivado toolchain.

Wrap with `toolchain(...)` and register via `register_toolchains(...)` in
MODULE.bazel so every `vivado_*` rule resolves it automatically. Multiple
instances can be registered side-by-side and selected via `target_settings`
(flag-driven) or `exec_compatible_with` (platform-driven).
""",
    implementation = _vivado_toolchain_impl,
    attrs = {
        "env": attr.string_dict(
            doc = "Environment variables passed to every Vivado action.",
            default = {},
        ),
        "requires_network": attr.bool(
            doc = ("Whether Vivado actions need network access. True (the " +
                   "default) is correct for a floating/network license server " +
                   "(`XILINXD_LICENSE_FILE=PORT@HOST`). Set to False for " +
                   "license-free editions (Vivado ML Standard / WebPACK) or " +
                   "node-locked .lic files read from disk. Controls whether " +
                   "the `requires-network` execution requirement is set on " +
                   "every `vivado_*` action."),
            default = True,
        ),
        "version": attr.string(
            doc = "The version of Vivado associated with this toolchain.",
        ),
        "vivado": attr.label(
            doc = ("The Vivado executable. Typically a small bash shim that " +
                   "`exec`s the real `vivado` out of a known install path " +
                   "(e.g. baked into a container image), but any " +
                   "`*_binary` rule works too — runfiles travel along. " +
                   "Defaults to a stock shim that calls `vivado` from the " +
                   "exec platform's `PATH` as a migration aid; production " +
                   "toolchains should pin the install path with their own " +
                   "shim."),
            default = Label("//vivado/private:vivado.sh"),
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
        "xilinx_env": attr.label(
            doc = ("Optional escape hatch — a shell script sourced inside " +
                   "the action shell immediately before `vivado` runs, for " +
                   "shell-side env composition `env` cannot express. " +
                   "Prefer `env`."),
            allow_single_file = True,
        ),
    },
)
