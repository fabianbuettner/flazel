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

_NIX_DEPS_DIR = ".nix-bazel-deps"

# =============================================================================
# Toolchain repository rules
# =============================================================================

def _file_exists(repository_ctx, path):
    """Check if a file exists using test command (sandbox compatible)."""
    result = repository_ctx.execute(["test", "-e", path])
    return result.return_code == 0

def _resolve_path(repository_ctx, relative_path):
    """Resolve a relative path to absolute using the workspace root."""
    workspace_root = repository_ctx.path(Label("@@//:MODULE.bazel")).dirname
    return str(workspace_root) + "/" + relative_path

def _nix_cc_repo_impl(repository_ctx):
    """Creates a CC toolchain repository by symlinking to a Nix store path."""
    path = _resolve_path(repository_ctx, repository_ctx.attr.path)

    build_file = path + "/BUILD.bazel"
    if not _file_exists(repository_ctx, build_file):
        fail("BUILD.bazel file not found at {}. Path: {}".format(build_file, path))
    repository_ctx.symlink(build_file, "BUILD.bazel")

    config_file = path + "/cc_toolchain_config.bzl"
    if not _file_exists(repository_ctx, config_file):
        fail("cc_toolchain_config.bzl not found at {}".format(config_file))
    repository_ctx.symlink(config_file, "cc_toolchain_config.bzl")

    bin_dir = path + "/bin"
    if _file_exists(repository_ctx, bin_dir):
        repository_ctx.symlink(bin_dir, "bin")

_nix_cc_repo = repository_rule(
    implementation = _nix_cc_repo_impl,
    attrs = {"path": attr.string(mandatory = True)},
    local = True,
)

def _nix_cc_deps_repo_impl(repository_ctx):
    """Creates the toolchain deps repository."""
    path = _resolve_path(repository_ctx, repository_ctx.attr.path)
    repository_ctx.symlink(path + "/BUILD.bazel", "BUILD.bazel")

    for dep in ["gcc", "gcc-lib", "libc", "libc-dev", "binutils"]:
        dep_full_path = path + "/" + dep
        if _file_exists(repository_ctx, dep_full_path):
            repository_ctx.symlink(dep_full_path, dep)

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

# =============================================================================
# Library repository rules
# =============================================================================

def _nix_lib_repo_impl(repository_ctx):
    """Creates a repository for a nixpkgs library."""
    path = _resolve_path(repository_ctx, repository_ctx.attr.path)

    build_file = path + "/BUILD.bazel"
    if not _file_exists(repository_ctx, build_file):
        fail("BUILD.bazel not found at '{}' (relative path: '{}')".format(build_file, repository_ctx.attr.path))
    repository_ctx.symlink(build_file, "BUILD.bazel")

    if _file_exists(repository_ctx, path + "/MODULE.bazel"):
        repository_ctx.symlink(path + "/MODULE.bazel", "MODULE.bazel")

    if _file_exists(repository_ctx, path + "/include"):
        repository_ctx.symlink(path + "/include", "include")

    if _file_exists(repository_ctx, path + "/lib"):
        repository_ctx.symlink(path + "/lib", "lib")

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

    # Map toolchain names to platform constraint values
    # This uses standard @platforms constraints so it works even with stub toolchains
    toolchain_constraints = {
        "default": None,  # No constraint, matches default
        "aarch64": "@platforms//cpu:aarch64",
        "mips64": "@platforms//cpu:mips64",
        "arm": "@platforms//cpu:arm",
        "riscv64": "@platforms//cpu:riscv64",
    }

    # Build the select() cases
    select_cases = []
    for tc in toolchains:
        if tc != default_toolchain and tc in toolchain_constraints and toolchain_constraints[tc]:
            select_cases.append('        "{constraint}": "@{lib}_{tc}//:{lib}",'.format(
                constraint = toolchain_constraints[tc],
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

def _get_nix_deps_path(module_ctx):
    """Get the absolute path to the .nix-bazel-deps directory in the root module."""
    for mod in module_ctx.modules:
        if mod.is_root:
            # @@// refers to the root module's apparent repo
            workspace_root = module_ctx.path(Label("@@//:MODULE.bazel")).dirname
            return str(workspace_root) + "/" + _NIX_DEPS_DIR
    fail("No root module found - this should never happen")

def _path_exists(module_ctx, path):
    """Check if a path exists using shell test command (works for external paths)."""
    result = module_ctx.execute(["test", "-e", path])
    return result.return_code == 0

def _dir_exists(module_ctx, path):
    """Check if a directory exists using shell test command (works for external paths)."""
    result = module_ctx.execute(["test", "-d", path])
    return result.return_code == 0

def _nix_cc_extension_impl(module_ctx):
    """Module extension that creates CC toolchain and library repositories."""
    nix_deps = _get_nix_deps_path(module_ctx)

    # Check if the deps directory exists
    if not _dir_exists(module_ctx, nix_deps):
        fail("Nix dependencies not found at {}. Run 'nix develop' first.".format(nix_deps))

    # Read marker file to create dependency - forces re-evaluation when shell changes
    # The marker file contains a sorted list of available toolchains
    marker_path = nix_deps + "/.toolchain-marker"
    if _path_exists(module_ctx, marker_path):
        module_ctx.read(marker_path)

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
    toolchains_dir_rel = _NIX_DEPS_DIR + "/toolchains"
    for name in requested_toolchains:
        cc_path = toolchains_dir + "/" + name + "/cc"
        cc_path_rel = toolchains_dir_rel + "/" + name + "/cc"
        deps_path = toolchains_dir + "/" + name + "/deps"
        deps_path_rel = toolchains_dir_rel + "/" + name + "/deps"

        # Check if toolchain exists
        if _dir_exists(module_ctx, cc_path):
            # Real toolchain exists - create real repos
            available_toolchains.append(name)
            _nix_cc_repo(name = "local_config_cc_" + name, path = cc_path_rel)

            if _dir_exists(module_ctx, deps_path):
                _nix_cc_deps_repo(name = "local_config_cc_" + name + "_deps", path = deps_path_rel)
            else:
                _stub_cc_deps_repo(name = "local_config_cc_" + name + "_deps")
        else:
            # Toolchain not available - create stubs
            _stub_cc_repo(name = "local_config_cc_" + name, toolchain_name = name)
            _stub_cc_deps_repo(name = "local_config_cc_" + name + "_deps")

    # Create repos for each requested package
    libs_dir = nix_deps + "/libs"
    libs_dir_rel = _NIX_DEPS_DIR + "/libs"
    for lib_name in requested_packages:
        # Create per-toolchain library repos (suffixed)
        for tc in requested_toolchains:
            suffixed_name = lib_name + "_" + tc
            lib_path = libs_dir + "/" + suffixed_name
            lib_path_rel = libs_dir_rel + "/" + suffixed_name

            if _dir_exists(module_ctx, lib_path):
                _nix_lib_repo(name = suffixed_name, path = lib_path_rel)
            else:
                # Fallback to unsuffixed if suffixed doesn't exist
                unsuffixed_path = libs_dir + "/" + lib_name
                unsuffixed_path_rel = libs_dir_rel + "/" + lib_name
                if _dir_exists(module_ctx, unsuffixed_path):
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

nix_cc = module_extension(
    implementation = _nix_cc_extension_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
        "package": _package_tag,
    },
)
