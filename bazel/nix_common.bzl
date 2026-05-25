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
