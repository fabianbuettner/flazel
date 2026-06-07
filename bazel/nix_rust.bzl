"""Module extension for Nix-provided Rust toolchains.

This extension creates Rust toolchain repositories from .nix-bazel-deps/,
which is set up by `nix develop` or during `nix build`. The Nix store
provides rustc, cargo, clippy, rustfmt, and rust-std. Pre-built binaries
from rules_rust do not run on NixOS.

Usage in MODULE.bazel:
    bazel_dep(name = "rules_rust", version = "0.56.0")

    nix_rust = use_extension("@flazel//bazel:nix_rust.bzl", "nix_rust")
    nix_rust.toolchain(name = "default")
    use_repo(nix_rust, "local_config_rust_default")
    inject_repo(nix_rust, "rules_rust")

The inject_repo line is required: the generated toolchain repo loads
@rules_rust, but flazel deliberately has no rules_rust dep (C++-only consumers
must not inherit it), so the consumer hands its own rules_rust to the
extension. Without it, analysis fails with "No repository visible as
'@rules_rust'".
"""

load(":nix_common.bzl", "NIX_DEPS_DIR", "dir_exists", "init_extension", "repo_source", "resolve_path", "symlink_if_exists")

def _write_rust_stub(repository_ctx, name):
    """Writes a stub repo for an absent Rust toolchain (a bare, empty package)."""
    repository_ctx.file("BUILD.bazel", """
# Stub Rust toolchain '{name}' - not available in current environment
# Run 'nix develop' to set up the Rust toolchain
package(default_visibility = ["//visibility:public"])
""".format(name = name))

def _nix_rust_repo_impl(repository_ctx):
    """Creates a Rust toolchain repository.

    Symlinks the Nix store path when the toolchain is present, or writes a stub
    when it is absent. The real-vs-stub decision is made here, at fetch time,
    NOT in the module extension at eval time, so the extension's generated repo
    specs stay a pure function of the declared toolchains and MODULE.bazel.lock
    is portable across environments. An absent toolchain is only ever fetched
    if a target actually selects it.
    """
    name = repository_ctx.attr.toolchain_name
    path, present = repo_source(repository_ctx)
    if not present:
        _write_rust_stub(repository_ctx, name)
        return
    repository_ctx.symlink(path + "/BUILD.bazel", "BUILD.bazel")

    symlink_if_exists(repository_ctx, path + "/bin", "bin")
    symlink_if_exists(repository_ctx, path + "/lib", "lib")

_nix_rust_repo = repository_rule(
    implementation = _nix_rust_repo_impl,
    attrs = {
        "path": attr.string(mandatory = True),
        "toolchain_name": attr.string(mandatory = True),
    },
    local = True,
)

def _nix_rust_extension_impl(module_ctx):
    """Module extension that creates Rust toolchain repositories.

    Repo specs are a pure function of the declared toolchains: no filesystem
    probing here. Each repo rule decides real-vs-stub at fetch time, keeping
    MODULE.bazel.lock portable across environments.
    """
    init_extension(module_ctx)

    requested_toolchains = []
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            requested_toolchains.append(tag.name)

    toolchains_dir_rel = NIX_DEPS_DIR + "/toolchains"
    for name in requested_toolchains:
        _nix_rust_repo(
            name = "local_config_rust_" + name,
            path = toolchains_dir_rel + "/" + name + "/rust",
            toolchain_name = name,
        )

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

def _nix_rust_host_tools_impl(repository_ctx):
    """Exposes the Nix rust toolchain as @rust_host_tools.

    crate_universe runs a host cargo/rustc at repo-eval to resolve the crate
    graph, which rules_rust supplies by downloading a prebuilt rustc that does
    not run on NixOS. Point it at the Nix toolchain instead by overriding the
    rust_host_tools repo in MODULE.bazel:

        host_tools = use_extension("@rules_rust//rust:extensions.bzl", "rust_host_tools")
        nix_host = use_repo_rule("@flazel//bazel:nix_rust.bzl", "nix_rust_host_tools")
        nix_host(name = "nix_rust_host_tools")
        override_repo(host_tools, rust_host_tools = "nix_rust_host_tools")

    Do NOT add a host_tools.host_tools(...) tag: rules_rust declares the
    default repo itself (a duplicate-name error since 0.70), and the override
    discards the downloaded toolchain anyway.

    crate_universe only references @rust_host_tools//:bin/{cargo,rustc}; rustc and
    cargo find their sysroot via their real Nix store path, so only the binaries
    are exposed here.
    """
    rust = resolve_path(repository_ctx, repository_ctx.attr.path)
    if not dir_exists(repository_ctx, rust + "/bin"):
        fail("Nix rust toolchain not found at {}/bin. Run 'nix develop' first.".format(rust))
    for tool in ["cargo", "rustc"]:
        repository_ctx.symlink(rust + "/bin/" + tool, "bin/" + tool)
    repository_ctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

exports_files([
    "bin/cargo",
    "bin/rustc",
])
""")

nix_rust_host_tools = repository_rule(
    implementation = _nix_rust_host_tools_impl,
    attrs = {
        "path": attr.string(
            default = NIX_DEPS_DIR + "/toolchains/default/rust",
            doc = "Path (relative to workspace root) to the Nix rust toolchain dir.",
        ),
    },
    local = True,
    doc = "Exposes the Nix rust toolchain as @rust_host_tools for crate_universe.",
)
