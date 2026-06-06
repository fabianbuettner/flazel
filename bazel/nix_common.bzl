"""Common utilities for Nix-Bazel integration.

Shared helpers for repository rules and module extensions that interface
with .nix-bazel-deps/.
"""

# Single source of truth for the deps-dir layout. The Nix half
# (lib/core/constants.nix) reads it out of this file, so keep it on its own
# line in the form `NAME = "value"`.
NIX_DEPS_DIR = ".nix-bazel-deps"

def path_exists(ctx, path):
    """Check if a file/path exists (works with both repository_ctx and module_ctx).

    Bazel-native (ctx.path(...).exists) rather than shelling out to `test`: a
    subprocess inherits the ambient execution environment (PATH, signal
    dispositions, the systemd-service sandbox), which under a forgejo DynamicUser
    CI runner made this check spuriously report a present toolchain as absent and
    stub it. The native query runs no subprocess, so it has no such dependence.
    """
    return ctx.path(path).exists

def dir_exists(ctx, path):
    """Check if a directory exists (works with both repository_ctx and module_ctx).

    Native ctx.path(...).is_dir for the same reason as path_exists above.
    """
    return ctx.path(path).is_dir

def host_constraints(ctx):
    """Best-effort @platforms cpu/os constraints for the host running the build.

    Derived from repository_ctx.os so exec_compatible_with is not pinned to
    x86_64-linux. Unknown arches fall back to x86_64 (the common case).

    Args:
      ctx: repository_ctx (uses ctx.os).

    Returns:
      A (cpu_constraint, os_constraint) tuple of @platforms// labels.
    """
    if ctx.os.arch in ["aarch64", "arm64"]:
        cpu = "@platforms//cpu:aarch64"
    else:
        cpu = "@platforms//cpu:x86_64"
    if "mac" in ctx.os.name or "darwin" in ctx.os.name:
        os = "@platforms//os:macos"
    else:
        os = "@platforms//os:linux"
    return cpu, os

def symlink_if_exists(ctx, src, name):
    """Symlink src to name inside the repository if src exists.

    Args:
      ctx: repository_ctx or module_ctx.
      src: absolute source path to symlink.
      name: link name to create in the repository root.

    Returns:
      True if the symlink was created, False if src was absent.
    """
    if path_exists(ctx, src):
        ctx.symlink(src, name)
        return True
    return False

def resolve_path(ctx, relative_path = NIX_DEPS_DIR):
    """Resolve a relative path from the workspace root.

    Args:
      ctx: repository_ctx or module_ctx.
      relative_path: path relative to workspace root (defaults to .nix-bazel-deps).

    Returns:
      Absolute path string.
    """
    workspace_root = ctx.path(Label("@@//:MODULE.bazel")).dirname  # buildifier: disable=canonical-repository
    return str(workspace_root) + "/" + relative_path

def repo_source(repository_ctx):
    """Common preamble for the Nix toolchain/deps repository rules.

    Resolves the repo's Nix source dir (from its `path` attr) and reports whether
    it is present, using the BUILD.bazel as the presence marker. When absent the
    repo rule writes a stub instead of symlinking (see nix_cc.bzl / nix_rust.bzl),
    which is what keeps the generated repo specs portable across environments.

    Returns:
      A (path, present) tuple: the absolute source dir and whether it exists.
    """
    path = resolve_path(repository_ctx, repository_ctx.attr.path)
    return path, path_exists(repository_ctx, path + "/BUILD.bazel")

def init_extension(module_ctx):
    """Common preamble for Nix module extensions.

    Checks that .nix-bazel-deps exists. Does NOT read any machine-local state
    into the extension: the extensions emit repo specs that are a pure function
    of the declared toolchains/packages, and each repo rule decides real-vs-stub
    at fetch time (see nix_cc.bzl / nix_rust.bzl). That keeps MODULE.bazel.lock
    portable across environments that set up different toolchain subsets (e.g. a
    single-toolchain `nix build` vs a multi-toolchain dev shell), so no marker
    file is needed to force re-evaluation.

    Args:
      module_ctx: the module extension context.

    Returns:
      Absolute path to .nix-bazel-deps.
    """
    nix_deps = resolve_path(module_ctx)
    if not dir_exists(module_ctx, nix_deps):
        fail("Nix dependencies not found at {}. Run 'nix develop' first.".format(nix_deps))
    return nix_deps
