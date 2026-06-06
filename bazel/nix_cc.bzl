"""Module extension for Nix-provided CC toolchains and libraries.

This extension creates CC toolchain repositories and library aliases from
.nix-bazel-deps/. Libraries automatically select the correct architecture
based on the target platform.

Usage in MODULE.bazel:
    nix_cc = use_extension("@flazel//bazel:nix_cc.bzl", "nix_cc")

    # Declare packages (libraries)
    nix_cc.package(name = "libjpeg")
    nix_cc.package(name = "openssl")

    # Declare toolchains
    nix_cc.toolchain(name = "default")
    nix_cc.toolchain(name = "aarch64")  # Optional cross-compilation

    use_repo(nix_cc,
        # Toolchains
        "local_config_cc_default",
        "local_config_cc_default_deps",
        "local_config_cc_aarch64",
        "local_config_cc_aarch64_deps",
        # Libraries (alias repos with automatic platform selection)
        "libjpeg",
        "openssl",
    )

Libraries are accessed as @libjpeg//:libjpeg - the correct architecture
is automatically selected based on --platforms.
"""

load(":nix_common.bzl", "NIX_DEPS_DIR", "host_constraints", "init_extension", "path_exists", "repo_source", "resolve_path", "symlink_if_exists")

# Keep in sync with lib/core/platform.nix
_CPU_CONSTRAINTS = {
    "x86_64": "@platforms//cpu:x86_64",
    "aarch64": "@platforms//cpu:aarch64",
    "mips64": "@platforms//cpu:mips64",
    "arm": "@platforms//cpu:arm",
    "riscv32": "@platforms//cpu:riscv32",
    "riscv64": "@platforms//cpu:riscv64",
}

# Keep in sync with lib/core/platform.nix
_OS_CONSTRAINTS = {
    "linux": "@platforms//os:linux",
    "ios": "@platforms//os:ios",
    "macos": "@platforms//os:macos",
    "darwin": "@platforms//os:macos",
    "none": "@platforms//os:none",
}

# =============================================================================
# Toolchain repository rules
# =============================================================================

def _write_cc_stub(repository_ctx, name):
    """Writes a valid-but-non-functional CC toolchain repo for an absent toolchain.

    Used when a declared toolchain is not present in the current environment.
    The repo still resolves (so `use_repo` and label references do not fail),
    but selecting its toolchain or evaluating its config fails loudly.
    """
    repository_ctx.file("BUILD.bazel", """
# Stub toolchain '{name}' - not available in current environment
# Use 'nix develop .#multi' for cross-compilation support
package(default_visibility = ["//visibility:public"])

filegroup(name = "empty")

# Stub platform so use_repo doesn't fail
platform(
    name = "platform",
    constraint_values = [],
)
""".format(name = name))
    repository_ctx.file("cc_toolchain_config.bzl", """
def cc_toolchain_config(**kwargs):
    fail("Toolchain '{name}' not available. Use 'nix develop .#multi' for cross-compilation.")
""".format(name = name))

def _nix_cc_repo_impl(repository_ctx):
    """Creates a CC toolchain repository.

    Symlinks the Nix store path when the toolchain is present in this
    environment, or writes a stub when it is absent. The real-vs-stub decision
    is made here, at fetch time, NOT in the module extension at eval time, so
    the extension's generated repo specs stay a pure function of the declared
    toolchains and MODULE.bazel.lock is portable across environments. An absent
    toolchain is only ever fetched if a target actually selects it, so the stub
    is a safety net rather than a path the common build hits.
    """
    name = repository_ctx.attr.toolchain_name
    path, present = repo_source(repository_ctx)
    if not present:
        _write_cc_stub(repository_ctx, name)
        return
    repository_ctx.symlink(path + "/BUILD.bazel", "BUILD.bazel")

    config_file = path + "/cc_toolchain_config.bzl"
    if not path_exists(repository_ctx, config_file):
        fail("cc_toolchain_config.bzl not found at {} (toolchain dir present but malformed)".format(config_file))
    repository_ctx.symlink(config_file, "cc_toolchain_config.bzl")

    symlink_if_exists(repository_ctx, path + "/bin", "bin")

_nix_cc_repo = repository_rule(
    implementation = _nix_cc_repo_impl,
    attrs = {
        "path": attr.string(mandatory = True),
        "toolchain_name": attr.string(mandatory = True),
    },
    local = True,
)

def _write_empty_cc_deps(repository_ctx):
    """Writes an empty toolchain-deps repo (a `:all` filegroup with no srcs)."""
    repository_ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])
filegroup(name = "all", srcs = [])
""")

def _nix_cc_deps_repo_impl(repository_ctx):
    """Creates the toolchain deps repository.

    Mirrors every entry the Nix derivation placed in the deps directory
    (BUILD.bazel plus gcc, gcc-lib, clang-lib, libc, libc-dev, binutils as
    applicable). Enumerating rather than hardcoding the dep names keeps this
    in lockstep with localConfigCcDeps in lib/cc/toolchain.nix: a hardcoded
    list silently dropped clang-lib, leaving Clang toolchains with a dangling
    -isystem path.
    """
    path, present = repo_source(repository_ctx)
    if not present:
        # Deps absent in this environment (toolchain stubbed) — emit an empty
        # deps repo so references resolve. Portable: same spec everywhere.
        _write_empty_cc_deps(repository_ctx)
        return

    result = repository_ctx.execute(["ls", "-1", path])
    if result.return_code != 0:
        fail("Cannot list toolchain deps at {}: {}".format(path, result.stderr))
    for entry in result.stdout.splitlines():
        if entry:
            repository_ctx.symlink(path + "/" + entry, entry)

_nix_cc_deps_repo = repository_rule(
    implementation = _nix_cc_deps_repo_impl,
    attrs = {"path": attr.string(mandatory = True)},
    local = True,
)

def _stub_cc_deps_repo_impl(repository_ctx):
    """Creates a stub deps repository, paired with _stub_cc_cross_repo."""
    _write_empty_cc_deps(repository_ctx)

_stub_cc_deps_repo = repository_rule(
    implementation = _stub_cc_deps_repo_impl,
    attrs = {},
    local = True,
)

def _stub_cc_cross_repo_impl(repository_ctx):
    """Creates a minimal CC toolchain for cross-compilation targets that lack a real compiler.

    Unlike the absent-toolchain stub (_write_cc_stub, whose config fails if used),
    this produces a valid but non-functional toolchain that passes Bazel's toolchain
    resolution. Useful when Rust targets require a CC toolchain for a platform you
    never actually compile C/C++ for.
    """
    name = repository_ctx.attr.toolchain_name
    target_cpu = repository_ctx.attr.target_cpu
    target_os = repository_ctx.attr.target_os

    # Exec platform = the host running the build, detected rather than assumed
    # x86_64-linux, so the stub resolves on non-x86_64-linux hosts too.
    exec_cpu, exec_os = host_constraints(repository_ctx)

    repository_ctx.file("cc_toolchain_config.bzl", """\
def _impl(ctx):
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "stub-{name}",
        host_system_name = "local",
        target_system_name = "stub",
        target_cpu = "stub",
        target_libc = "stub",
        compiler = "stub",
        abi_version = "stub",
        abi_libc_version = "stub",
        tool_paths = [],
    )

stub_cc_config = rule(implementation = _impl, provides = [CcToolchainConfigInfo])
""".format(name = name))

    repository_ctx.file("BUILD.bazel", """\
load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load(":cc_toolchain_config.bzl", "stub_cc_config")

package(default_visibility = ["//visibility:public"])

filegroup(name = "empty")

stub_cc_config(name = "cc_toolchain_config")

cc_toolchain(
    name = "cc_toolchain_impl",
    all_files = ":empty",
    ar_files = ":empty",
    as_files = ":empty",
    compiler_files = ":empty",
    dwp_files = ":empty",
    linker_files = ":empty",
    objcopy_files = ":empty",
    strip_files = ":empty",
    toolchain_config = ":cc_toolchain_config",
)

toolchain(
    name = "cc_toolchain",
    exec_compatible_with = [
        "{exec_cpu}",
        "{exec_os}",
    ],
    target_compatible_with = [
        "{target_cpu}",
        "{target_os}",
    ],
    toolchain = ":cc_toolchain_impl",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
)

platform(
    name = "platform",
    constraint_values = [
        "{target_cpu}",
        "{target_os}",
    ],
)
""".format(
        target_cpu = target_cpu,
        target_os = target_os,
        exec_cpu = exec_cpu,
        exec_os = exec_os,
    ))

_stub_cc_cross_repo = repository_rule(
    implementation = _stub_cc_cross_repo_impl,
    attrs = {
        "toolchain_name": attr.string(mandatory = True),
        "target_cpu": attr.string(mandatory = True),
        "target_os": attr.string(mandatory = True),
    },
    local = True,
)

# =============================================================================
# Library repository rules
# =============================================================================

def _nix_lib_repo_impl(repository_ctx):
    """Creates a repository for a nixpkgs library.

    Tries the toolchain-suffixed path first, then the unsuffixed fallback (a
    toolchain that shares the default arch's libs has no suffixed dir). The
    path selection happens here, at fetch time, so the extension emits one
    portable spec regardless of which dirs exist in a given environment. A
    library provided by neither path fails here, when it is actually fetched
    (i.e. linked), not at extension eval time.
    """
    for candidate in [repository_ctx.attr.path, repository_ctx.attr.fallback_path]:
        path = resolve_path(repository_ctx, candidate)
        build_file = path + "/BUILD.bazel"
        if path_exists(repository_ctx, build_file):
            repository_ctx.symlink(build_file, "BUILD.bazel")
            symlink_if_exists(repository_ctx, path + "/MODULE.bazel", "MODULE.bazel")
            symlink_if_exists(repository_ctx, path + "/include", "include")
            symlink_if_exists(repository_ctx, path + "/lib", "lib")
            return

    fail("Library '{}' not found at '{}' or fallback '{}' in this environment.".format(
        repository_ctx.attr.lib_name,
        repository_ctx.attr.path,
        repository_ctx.attr.fallback_path,
    ))

_nix_lib_repo = repository_rule(
    implementation = _nix_lib_repo_impl,
    attrs = {
        "path": attr.string(mandatory = True),
        "fallback_path": attr.string(mandatory = True),
        "lib_name": attr.string(mandatory = True),
    },
    local = True,
)

def _nix_lib_alias_repo_impl(repository_ctx):
    """Creates an alias repository that selects library based on platform."""
    lib_name = repository_ctx.attr.lib_name
    toolchains = repository_ctx.attr.toolchains
    default_toolchain = repository_ctx.attr.default_toolchain

    # Build the select() cases using module-level _CPU_CONSTRAINTS
    select_cases = []
    for tc in toolchains:
        if tc != default_toolchain and tc in _CPU_CONSTRAINTS:
            select_cases.append('        "{constraint}": "@{lib}_{tc}//:{lib}",'.format(
                constraint = _CPU_CONSTRAINTS[tc],
                tc = tc,
                lib = lib_name,
            ))

    select_cases.append('        "//conditions:default": "@{lib}_{tc}//:{lib}",'.format(
        tc = default_toolchain,
        lib = lib_name,
    ))

    build_content = """
package(default_visibility = ["//visibility:public"])

alias(
    name = "{lib}",
    actual = select({{
{cases}
    }}),
)
""".format(lib = lib_name, cases = "\n".join(select_cases))

    repository_ctx.file("BUILD.bazel", build_content)
    repository_ctx.file("MODULE.bazel", 'module(name = "{}")'.format(lib_name))

_nix_lib_alias_repo = repository_rule(
    implementation = _nix_lib_alias_repo_impl,
    attrs = {
        "lib_name": attr.string(mandatory = True),
        "toolchains": attr.string_list(mandatory = True),
        "default_toolchain": attr.string(mandatory = True),
    },
    local = True,
)

# =============================================================================
# Module extension
# =============================================================================

def _nix_cc_extension_impl(module_ctx):
    """Module extension that creates CC toolchain and library repositories.

    Repo specs are a pure function of the declared toolchains and packages: no
    filesystem probing happens here. Each repo rule decides real-vs-stub (for
    toolchains) or suffixed-vs-fallback (for libs) at fetch time, which keeps
    MODULE.bazel.lock portable across environments that set up different
    toolchain subsets.
    """
    init_extension(module_ctx)

    # Collect requested toolchains and packages from tags
    requested_toolchains = []
    requested_packages = []
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            requested_toolchains.append(tag.name)
        for tag in mod.tags.package:
            requested_packages.append(tag.name)

    # Determine default toolchain (first one, or "default" if present)
    default_toolchain = requested_toolchains[0] if requested_toolchains else "default"
    if "default" in requested_toolchains:
        default_toolchain = "default"

    # Create repos for each requested toolchain. Relative paths only (lockfile
    # portability); the repo rule resolves and stubs at fetch time.
    toolchains_dir_rel = NIX_DEPS_DIR + "/toolchains"
    for name in requested_toolchains:
        _nix_cc_repo(
            name = "local_config_cc_" + name,
            path = toolchains_dir_rel + "/" + name + "/cc",
            toolchain_name = name,
        )
        _nix_cc_deps_repo(
            name = "local_config_cc_" + name + "_deps",
            path = toolchains_dir_rel + "/" + name + "/deps",
        )

    # Create repos for each requested package
    libs_dir_rel = NIX_DEPS_DIR + "/libs"
    for lib_name in requested_packages:
        # Per-toolchain library repos: suffixed path, with the unsuffixed dir as
        # the fetch-time fallback (resolved inside _nix_lib_repo).
        for tc in requested_toolchains:
            _nix_lib_repo(
                name = lib_name + "_" + tc,
                path = libs_dir_rel + "/" + lib_name + "_" + tc,
                fallback_path = libs_dir_rel + "/" + lib_name,
                lib_name = lib_name,
            )

        # Create alias repo that selects based on platform
        _nix_lib_alias_repo(
            name = lib_name,
            lib_name = lib_name,
            toolchains = requested_toolchains,
            default_toolchain = default_toolchain,
        )

    # Create stub CC toolchain repos for cross-compilation platforms
    for mod in module_ctx.modules:
        for tag in mod.tags.stub:
            cpu = _CPU_CONSTRAINTS.get(tag.target_cpu)
            if not cpu:
                fail("Unknown target_cpu '{}'. Supported: {}".format(
                    tag.target_cpu,
                    ", ".join(_CPU_CONSTRAINTS.keys()),
                ))
            os = _OS_CONSTRAINTS.get(tag.target_os)
            if not os:
                fail("Unknown target_os '{}'. Supported: {}".format(
                    tag.target_os,
                    ", ".join(_OS_CONSTRAINTS.keys()),
                ))
            _stub_cc_cross_repo(
                name = "local_config_cc_" + tag.name,
                toolchain_name = tag.name,
                target_cpu = cpu,
                target_os = os,
            )
            _stub_cc_deps_repo(name = "local_config_cc_" + tag.name + "_deps")

_toolchain_tag = tag_class(
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the toolchain (e.g., 'default', 'aarch64')",
        ),
    },
    doc = "Declares a CC toolchain to be provided by Nix.",
)

_package_tag = tag_class(
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the library package (e.g., 'openssl', 'libjpeg')",
        ),
    },
    doc = "Declares a library package to be provided by Nix.",
)

_stub_tag = tag_class(
    attrs = {
        "name": attr.string(mandatory = True, doc = "Name for this stub toolchain"),
        "target_cpu": attr.string(mandatory = True, doc = "Target CPU (e.g., 'aarch64', 'x86_64')"),
        "target_os": attr.string(mandatory = True, doc = "Target OS (e.g., 'linux', 'ios', 'macos')"),
    },
    doc = "Declares a stub CC toolchain for a cross-compilation target that lacks a real compiler.",
)

nix_cc = module_extension(
    implementation = _nix_cc_extension_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
        "package": _package_tag,
        "stub": _stub_tag,
    },
)
