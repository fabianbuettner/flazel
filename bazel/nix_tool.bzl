"""Repository rule to expose Nix tools to Bazel."""

def _nix_tool_impl(repository_ctx):
    """Creates a repository with a symlink to a Nix tool.

    The symlink is named after the repository, enabling shorthand references:
        @magick instead of @magick//:magick
        @openssl-bin instead of @openssl-bin//:openssl
    """

    # Extract base repo name (strip bzlmod prefix like "_main~_repo_rules~")
    full_name = repository_ctx.name
    base_name = full_name.split("~")[-1] if "~" in full_name else full_name

    # Binary to find in PATH (defaults to base repo name)
    binary_name = repository_ctx.attr.binary_name or base_name

    # Find the tool in PATH (from Nix devshell)
    result = repository_ctx.execute(["which", binary_name])
    if result.return_code == 0:
        tool_path = result.stdout.strip()

        # Resolve the real binary path (follows all symlinks)
        real_result = repository_ctx.execute(["readlink", "-f", tool_path])
        real_path = real_result.stdout.strip() if real_result.return_code == 0 else tool_path

        # Symlink named after base repo name (so @repo shorthand works in genrules)
        repository_ctx.symlink(tool_path, base_name)

        # Wrapper script that invokes the tool by its resolved absolute path.
        # We can't use sh_binary or native_binary because NixOS patches bash to
        # create argv[0]-based launchers that break when Bazel renames binaries.
        repository_ctx.file("wrapper.sh", """\
#!/usr/bin/env bash
exec {real_path} "$@"
""".format(real_path = real_path), executable = True)
    else:
        # Tool not in PATH — create stubs that fail at execution time with a
        # helpful message. This allows the build to succeed for targets that
        # don't transitively depend on this tool.
        stub = """\
#!/bin/sh
echo "ERROR: Tool '{binary}' not found in PATH." >&2
echo "Make sure you're in a Nix devshell with the tool available:" >&2
echo "  nix develop" >&2
exit 1
""".format(binary = binary_name)
        repository_ctx.file(base_name, stub, executable = True)
        repository_ctx.file("wrapper.sh", stub, executable = True)

    # A custom rule that provides an executable without NixOS wrapper issues.
    # sh_binary and native_binary both create launchers that look for
    # <argv0>-unwrapped, which breaks for symlinked Nix binaries.
    repository_ctx.file("nix_executable.bzl", '''\
def _nix_executable_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = ctx.file.src, is_executable = True)
    return [DefaultInfo(
        files = depset([out]),
        executable = out,
    )]

nix_executable = rule(
    implementation = _nix_executable_impl,
    attrs = {"src": attr.label(allow_single_file = True)},
    executable = True,
)
''')

    repository_ctx.file("BUILD.bazel", """\
load(":nix_executable.bzl", "nix_executable")

package(default_visibility = ["//visibility:public"])

# Raw symlink for genrule $(location @repo) usage
exports_files(["{name}"])

# Executable target backed by a wrapper script that execs the resolved
# Nix store path. Works with executable=True rule attrs and aspects.
nix_executable(
    name = "bin",
    src = "wrapper.sh",
)
""".format(name = base_name))

nix_tool = repository_rule(
    implementation = _nix_tool_impl,
    attrs = {
        "binary_name": attr.string(doc = "Binary name to find in PATH (defaults to repository name)"),
    },
    local = True,  # Re-run when environment changes
    doc = "Exposes a tool from the Nix devshell PATH as a Bazel target.",
)
