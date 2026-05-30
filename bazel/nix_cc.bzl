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

load(":nix_common.bzl", "NIX_DEPS_DIR", "dir_exists", "file_exists", "init_extension", "resolve_path", "symlink_if_exists")

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

def _nix_cc_repo_impl(repository_ctx):
    """Creates a CC toolchain repository by symlinking to a Nix store path."""
    path = resolve_path(repository_ctx, repository_ctx.attr.path)

    build_file = path + "/BUILD.bazel"
    if not file_exists(repository_ctx, build_file):
        fail("BUILD.bazel file not found at {}. Path: {}".format(build_file, path))
    repository_ctx.symlink(build_file, "BUILD.bazel")

    config_file = path + "/cc_toolchain_config.bzl"
    if not file_exists(repository_ctx, config_file):
        fail("cc_toolchain_config.bzl not found at {}".format(config_file))
    repository_ctx.symlink(config_file, "cc_toolchain_config.bzl")

    symlink_if_exists(repository_ctx, path + "/bin", "bin")

_nix_cc_repo = repository_rule(
    implementation = _nix_cc_repo_impl,
    attrs = {"path": attr.string(mandatory = True)},
    local = True,
)

def _nix_cc_deps_repo_impl(repository_ctx):
    """Creates the toolchain deps repository.

    Mirrors every entry the Nix derivation placed in the deps directory
    (BUILD.bazel plus gcc, gcc-lib, clang-lib, libc, libc-dev, binutils as
    applicable). Enumerating rather than hardcoding the dep names keeps this
    in lockstep with localConfigCcDeps in lib/cc/toolchain.nix: a hardcoded
    list silently dropped clang-lib, leaving Clang toolchains with a dangling
    -isystem path.
    """
    path = resolve_path(repository_ctx, repository_ctx.attr.path)

    build_file = path + "/BUILD.bazel"
    if not file_exists(repository_ctx, build_file):
        fail("BUILD.bazel not found at {}. Run 'nix develop' first.".format(build_file))

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

def _stub_cc_repo_impl(repository_ctx):
    """Creates a stub repository for unavailable toolchains."""
    name = repository_ctx.attr.toolchain_name
    repository_ctx.file("BUILD.bazel", """
# Stub toolchain '{name}' - not available in current shell
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

_stub_cc_repo = repository_rule(
    implementation = _stub_cc_repo_impl,
    attrs = {"toolchain_name": attr.string(mandatory = True)},
    local = True,
)

def _stub_cc_deps_repo_impl(repository_ctx):
    """Creates a stub deps repository for unavailable toolchains."""
    repository_ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])
filegroup(name = "all", srcs = [])
""")

_stub_cc_deps_repo = repository_rule(
    implementation = _stub_cc_deps_repo_impl,
    attrs = {},
    local = True,
)

def _stub_cc_cross_repo_impl(repository_ctx):
    """Creates a minimal CC toolchain for cross-compilation targets that lack a real compiler.

    Unlike _stub_cc_repo (which fails at config time for unavailable Nix toolchains),
    this produces a valid but non-functional toolchain that passes Bazel's toolchain
    resolution. Useful when Rust targets require a CC toolchain for a platform you
    never actually compile C/C++ for.
    """
    name = repository_ctx.attr.toolchain_name
    target_cpu = repository_ctx.attr.target_cpu
    target_os = repository_ctx.attr.target_os

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
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
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
    """Creates a repository for a nixpkgs library."""
    path = resolve_path(repository_ctx, repository_ctx.attr.path)

    build_file = path + "/BUILD.bazel"
    if not file_exists(repository_ctx, build_file):
        fail("BUILD.bazel not found at '{}' (relative path: '{}')".format(build_file, repository_ctx.attr.path))
    repository_ctx.symlink(build_file, "BUILD.bazel")

    symlink_if_exists(repository_ctx, path + "/MODULE.bazel", "MODULE.bazel")
    symlink_if_exists(repository_ctx, path + "/include", "include")
    symlink_if_exists(repository_ctx, path + "/lib", "lib")

_nix_lib_repo = repository_rule(
    implementation = _nix_lib_repo_impl,
    attrs = {"path": attr.string(mandatory = True)},
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
    """Module extension that creates CC toolchain and library repositories."""
    nix_deps = init_extension(module_ctx)

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

    # Track which toolchains actually exist
    available_toolchains = []

    # Create repos for each requested toolchain
    # Use absolute paths for existence checks, relative paths for repo attrs (lockfile portability)
    toolchains_dir = nix_deps + "/toolchains"
    toolchains_dir_rel = NIX_DEPS_DIR + "/toolchains"
    for name in requested_toolchains:
        cc_path = toolchains_dir + "/" + name + "/cc"
        cc_path_rel = toolchains_dir_rel + "/" + name + "/cc"
        deps_path = toolchains_dir + "/" + name + "/deps"
        deps_path_rel = toolchains_dir_rel + "/" + name + "/deps"

        # Check if toolchain exists
        if dir_exists(module_ctx, cc_path):
            # Real toolchain exists - create real repos
            available_toolchains.append(name)
            _nix_cc_repo(name = "local_config_cc_" + name, path = cc_path_rel)

            if dir_exists(module_ctx, deps_path):
                _nix_cc_deps_repo(name = "local_config_cc_" + name + "_deps", path = deps_path_rel)
            else:
                _stub_cc_deps_repo(name = "local_config_cc_" + name + "_deps")
        else:
            # Toolchain not available - create stubs
            _stub_cc_repo(name = "local_config_cc_" + name, toolchain_name = name)
            _stub_cc_deps_repo(name = "local_config_cc_" + name + "_deps")

    # Create repos for each requested package
    libs_dir = nix_deps + "/libs"
    libs_dir_rel = NIX_DEPS_DIR + "/libs"
    for lib_name in requested_packages:
        # Create per-toolchain library repos (suffixed)
        for tc in requested_toolchains:
            suffixed_name = lib_name + "_" + tc
            lib_path = libs_dir + "/" + suffixed_name
            lib_path_rel = libs_dir_rel + "/" + suffixed_name

            if dir_exists(module_ctx, lib_path):
                _nix_lib_repo(name = suffixed_name, path = lib_path_rel)
            else:
                # Fallback to unsuffixed if suffixed doesn't exist
                unsuffixed_path = libs_dir + "/" + lib_name
                unsuffixed_path_rel = libs_dir_rel + "/" + lib_name
                if dir_exists(module_ctx, unsuffixed_path):
                    _nix_lib_repo(name = suffixed_name, path = unsuffixed_path_rel)
                else:
                    fail("Library '{}' not found for toolchain '{}' in {}".format(
                        lib_name,
                        tc,
                        libs_dir,
                    ))

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
