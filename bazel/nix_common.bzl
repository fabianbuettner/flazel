"""Common utilities for Nix-Bazel integration.

Shared helpers for repository rules and module extensions that interface
with .nix-bazel-deps/.
"""

NIX_DEPS_DIR = ".nix-bazel-deps"

def file_exists(ctx, path):
    """Check if a file/path exists (works with both repository_ctx and module_ctx)."""
    result = ctx.execute(["test", "-e", path])
    return result.return_code == 0

def dir_exists(ctx, path):
    """Check if a directory exists (works with both repository_ctx and module_ctx)."""
    result = ctx.execute(["test", "-d", path])
    return result.return_code == 0

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
    if file_exists(ctx, src):
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

def init_extension(module_ctx):
    """Common preamble for Nix module extensions.

    Checks that .nix-bazel-deps exists and reads the marker file to force
    re-evaluation when the toolchain set changes.

    Args:
      module_ctx: the module extension context.

    Returns:
      Absolute path to .nix-bazel-deps.
    """
    nix_deps = resolve_path(module_ctx)
    if not dir_exists(module_ctx, nix_deps):
        fail("Nix dependencies not found at {}. Run 'nix develop' first.".format(nix_deps))
    marker_path = nix_deps + "/.toolchain-marker"
    if file_exists(module_ctx, marker_path):
        module_ctx.read(marker_path)
    return nix_deps
