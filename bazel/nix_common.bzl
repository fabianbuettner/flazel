"""Common utilities for Nix-Bazel integration.

Shared helpers for repository rules and module extensions that interface
with .nix-bazel-deps/.
"""

NIX_DEPS_DIR = ".nix-bazel-deps"

def file_exists(repository_ctx, path):
    """Check if a file exists using test command (sandbox compatible)."""
    result = repository_ctx.execute(["test", "-e", path])
    return result.return_code == 0

def resolve_path(repository_ctx, relative_path):
    """Resolve a relative path to absolute using the workspace root."""
    workspace_root = repository_ctx.path(Label("@@//:MODULE.bazel")).dirname
    return str(workspace_root) + "/" + relative_path

def get_nix_deps_path(module_ctx):
    """Get the absolute path to the .nix-bazel-deps directory."""
    workspace_root = module_ctx.path(Label("@@//:MODULE.bazel")).dirname
    return str(workspace_root) + "/" + NIX_DEPS_DIR

def path_exists(module_ctx, path):
    """Check if a path exists."""
    result = module_ctx.execute(["test", "-e", path])
    return result.return_code == 0

def dir_exists(module_ctx, path):
    """Check if a directory exists."""
    result = module_ctx.execute(["test", "-d", path])
    return result.return_code == 0
