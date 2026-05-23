"""Module extension for Nix-provided Rust toolchains.

This extension creates Rust toolchain repositories from .nix-bazel-deps/,
which is set up by `nix develop` or during `nix build`. The Nix store
provides rustc, cargo, clippy, rustfmt, and rust-std — pre-built binaries
from rules_rust do not run on NixOS.

Usage in MODULE.bazel:
    nix_rust = use_extension("@flazel//bazel:nix_rust.bzl", "nix_rust")
    nix_rust.toolchain(name = "default")
    use_repo(nix_rust, "local_config_rust_default")
"""

_NIX_DEPS_DIR = ".nix-bazel-deps"

def _file_exists(repository_ctx, path):
    """Check if a file exists using test command (sandbox compatible)."""
    result = repository_ctx.execute(["test", "-e", path])
    return result.return_code == 0

def _resolve_path(repository_ctx, relative_path):
    """Resolve a relative path to absolute using the workspace root."""
    workspace_root = repository_ctx.path(Label("@@//:MODULE.bazel")).dirname
    return str(workspace_root) + "/" + relative_path

def _nix_rust_repo_impl(repository_ctx):
    """Creates a Rust toolchain repository by symlinking to a Nix store path."""
    path = _resolve_path(repository_ctx, repository_ctx.attr.path)

    build_file = path + "/BUILD.bazel"
    if not _file_exists(repository_ctx, build_file):
        fail("BUILD.bazel not found at {}. Run 'nix develop' first.".format(build_file))
    repository_ctx.symlink(build_file, "BUILD.bazel")

    bin_dir = path + "/bin"
    if _file_exists(repository_ctx, bin_dir):
        repository_ctx.symlink(bin_dir, "bin")

    lib_dir = path + "/lib"
    if _file_exists(repository_ctx, lib_dir):
        repository_ctx.symlink(lib_dir, "lib")

_nix_rust_repo = repository_rule(
    implementation = _nix_rust_repo_impl,
    attrs = {"path": attr.string(mandatory = True)},
    local = True,
)

def _stub_rust_repo_impl(repository_ctx):
    """Creates a stub repository for unavailable Rust toolchains."""
    name = repository_ctx.attr.toolchain_name
    repository_ctx.file("BUILD.bazel", """
# Stub Rust toolchain '{name}' - not available in current shell
# Run 'nix develop' to set up the Rust toolchain
package(default_visibility = ["//visibility:public"])
""".format(name = name))

_stub_rust_repo = repository_rule(
    implementation = _stub_rust_repo_impl,
    attrs = {"toolchain_name": attr.string(mandatory = True)},
    local = True,
)

def _get_nix_deps_path(module_ctx):
    """Get the absolute path to the .nix-bazel-deps directory."""
    workspace_root = module_ctx.path(Label("@@//:MODULE.bazel")).dirname
    return str(workspace_root) + "/" + _NIX_DEPS_DIR

def _path_exists(module_ctx, path):
    """Check if a path exists."""
    result = module_ctx.execute(["test", "-e", path])
    return result.return_code == 0

def _dir_exists(module_ctx, path):
    """Check if a directory exists."""
    result = module_ctx.execute(["test", "-d", path])
    return result.return_code == 0

def _nix_rust_extension_impl(module_ctx):
    """Module extension that creates Rust toolchain repositories."""
    nix_deps = _get_nix_deps_path(module_ctx)

    if not _dir_exists(module_ctx, nix_deps):
        fail("Nix dependencies not found at {}. Run 'nix develop' first.".format(nix_deps))

    marker_path = nix_deps + "/.toolchain-marker"
    if _path_exists(module_ctx, marker_path):
        module_ctx.read(marker_path)

    requested_toolchains = []
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            requested_toolchains.append(tag.name)

    toolchains_dir = nix_deps + "/toolchains"
    toolchains_dir_rel = _NIX_DEPS_DIR + "/toolchains"

    for name in requested_toolchains:
        rust_path = toolchains_dir + "/" + name + "/rust"
        rust_path_rel = toolchains_dir_rel + "/" + name + "/rust"

        if _dir_exists(module_ctx, rust_path):
            _nix_rust_repo(name = "local_config_rust_" + name, path = rust_path_rel)
        else:
            _stub_rust_repo(name = "local_config_rust_" + name, toolchain_name = name)

_toolchain_tag = tag_class(
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the Rust toolchain (e.g., 'default')",
        ),
    },
    doc = "Declares a Rust toolchain to be provided by Nix.",
)

nix_rust = module_extension(
    implementation = _nix_rust_extension_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
    },
)
