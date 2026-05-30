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

load(":nix_common.bzl", "NIX_DEPS_DIR", "dir_exists", "file_exists", "init_extension", "resolve_path", "symlink_if_exists")

def _nix_rust_repo_impl(repository_ctx):
    """Creates a Rust toolchain repository by symlinking to a Nix store path."""
    path = resolve_path(repository_ctx, repository_ctx.attr.path)

    build_file = path + "/BUILD.bazel"
    if not file_exists(repository_ctx, build_file):
        fail("BUILD.bazel not found at {}. Run 'nix develop' first.".format(build_file))
    repository_ctx.symlink(build_file, "BUILD.bazel")

    symlink_if_exists(repository_ctx, path + "/bin", "bin")
    symlink_if_exists(repository_ctx, path + "/lib", "lib")

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

def _nix_rust_extension_impl(module_ctx):
    """Module extension that creates Rust toolchain repositories."""
    nix_deps = init_extension(module_ctx)

    requested_toolchains = []
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            requested_toolchains.append(tag.name)

    toolchains_dir = nix_deps + "/toolchains"
    toolchains_dir_rel = NIX_DEPS_DIR + "/toolchains"

    for name in requested_toolchains:
        rust_path = toolchains_dir + "/" + name + "/rust"
        rust_path_rel = toolchains_dir_rel + "/" + name + "/rust"

        if dir_exists(module_ctx, rust_path):
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
