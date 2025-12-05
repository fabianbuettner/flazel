"""Module extension for Nix-provided CC toolchains and libraries.

This extension automatically discovers toolchains and libraries from .nix-bazel-deps/,
which is created by `nix develop` or during `nix build`. The only source of truth
for which toolchains/libraries to include is flake.nix.

Directory structure:
  .nix-bazel-deps/
    toolchains/
      <name>/
        cc/       -> local_config_cc_<name>
        deps/     -> local_config_cc_<name>_deps
    libs/
      libtiff/
      openssl/
      ...

To add a new toolchain:
1. Add it to toolchains in flake.nix mkDevShell call
2. Add local_config_cc_<name> and local_config_cc_<name>_deps to use_repo() in MODULE.bazel

To add a new library:
1. Add it to nixpkgsLibs in flake.nix
2. Add it to use_repo() in MODULE.bazel
"""

# Path to the Nix-provided dependencies directory (created by nix develop/build)
_NIX_DEPS_DIR = ".nix-bazel-deps"

def _resolve_path(repository_ctx):
    """Resolve relative path to absolute using workspace root."""
    return str(repository_ctx.workspace_root) + "/" + repository_ctx.attr.path

def _nix_cc_repo_impl(repository_ctx):
    """Creates a repository by symlinking to a Nix store path."""
    path = _resolve_path(repository_ctx)

    # Symlink all contents from the Nix store path
    repository_ctx.symlink(path + "/BUILD.bazel", "BUILD.bazel")
    repository_ctx.symlink(path + "/cc_toolchain_config.bzl", "cc_toolchain_config.bzl")

    # Symlink bin directory if it exists
    result = repository_ctx.execute(["test", "-d", path + "/bin"])
    if result.return_code == 0:
        repository_ctx.symlink(path + "/bin", "bin")

_nix_cc_repo = repository_rule(
    implementation = _nix_cc_repo_impl,
    attrs = {"path": attr.string(mandatory = True)},
    local = True,
)

def _nix_cc_deps_repo_impl(repository_ctx):
    """Creates the toolchain deps repository."""
    path = _resolve_path(repository_ctx)
    repository_ctx.symlink(path + "/BUILD.bazel", "BUILD.bazel")

    # Symlink all the dependency directories
    for dep in ["gcc", "gcc-lib", "libc", "libc-dev", "binutils"]:
        result = repository_ctx.execute(["test", "-e", path + "/" + dep])
        if result.return_code == 0:
            repository_ctx.symlink(path + "/" + dep, dep)

_nix_cc_deps_repo = repository_rule(
    implementation = _nix_cc_deps_repo_impl,
    attrs = {"path": attr.string(mandatory = True)},
    local = True,
)

def _nix_lib_repo_impl(repository_ctx):
    """Creates a repository for a nixpkgs library."""
    path = _resolve_path(repository_ctx)
    repository_ctx.symlink(path + "/BUILD.bazel", "BUILD.bazel")
    repository_ctx.symlink(path + "/MODULE.bazel", "MODULE.bazel")

    result = repository_ctx.execute(["test", "-d", path + "/include"])
    if result.return_code == 0:
        repository_ctx.symlink(path + "/include", "include")

    result = repository_ctx.execute(["test", "-d", path + "/lib"])
    if result.return_code == 0:
        repository_ctx.symlink(path + "/lib", "lib")

_nix_lib_repo = repository_rule(
    implementation = _nix_lib_repo_impl,
    attrs = {"path": attr.string(mandatory = True)},
    local = True,
)

def _get_nix_deps_path(module_ctx):
    """Get the absolute path to the .nix-bazel-deps directory (for checking existence)."""
    workspace_root = module_ctx.path(Label("//:MODULE.bazel")).dirname
    return str(workspace_root) + "/" + _NIX_DEPS_DIR

def _discover_directories(module_ctx, dir_path):
    """Discover subdirectories by scanning a directory."""
    result = module_ctx.execute(["ls", "-1", dir_path])
    if result.return_code != 0:
        return []
    return [e.strip() for e in result.stdout.split("\n") if e.strip()]

def _nix_toolchain_extension_impl(module_ctx):
    """Module extension that creates repositories from .nix-bazel-deps directory."""
    nix_deps = _get_nix_deps_path(module_ctx)

    # Check if the deps directory exists
    result = module_ctx.execute(["test", "-d", nix_deps])
    if result.return_code != 0:
        fail("Nix dependencies not found at {}. Run 'nix develop' or 'nix build' first.".format(nix_deps))

    # Discover all toolchains from toolchains/ subdirectory
    toolchains_dir = nix_deps + "/toolchains"
    result = module_ctx.execute(["test", "-d", toolchains_dir])
    if result.return_code == 0:
        toolchain_names = _discover_directories(module_ctx, toolchains_dir)

        for name in toolchain_names:
            # CC toolchain repo (from toolchains/<name>/cc/)
            cc_path_rel = _NIX_DEPS_DIR + "/toolchains/" + name + "/cc"
            cc_path_abs = nix_deps + "/toolchains/" + name + "/cc"

            result = module_ctx.execute(["test", "-d", cc_path_abs])
            if result.return_code == 0:
                _nix_cc_repo(name = "local_config_cc_" + name, path = cc_path_rel)

            # CC toolchain deps repo (from toolchains/<name>/deps/)
            deps_path_rel = _NIX_DEPS_DIR + "/toolchains/" + name + "/deps"
            deps_path_abs = nix_deps + "/toolchains/" + name + "/deps"

            result = module_ctx.execute(["test", "-d", deps_path_abs])
            if result.return_code == 0:
                _nix_cc_deps_repo(name = "local_config_cc_" + name + "_deps", path = deps_path_rel)

    # Discover and create library repos from libs/ subdirectory (shared across toolchains)
    libs_dir = nix_deps + "/libs"
    libraries = _discover_directories(module_ctx, libs_dir)
    for lib_name in libraries:
        lib_path_rel = _NIX_DEPS_DIR + "/libs/" + lib_name
        _nix_lib_repo(name = lib_name, path = lib_path_rel)

nix_toolchain = module_extension(implementation = _nix_toolchain_extension_impl)
