"""Repository rule to expose a Nix devshell tool to Bazel.

The tool is symlinked and invoked under its binary name, so argv[0] is the
applet name. That makes it work for standalone binaries (imagemagick, openssl,
glslc, ...) AND for multicall binaries that dispatch on argv[0] (coreutils,
busybox): e.g. nix_tool(name = "rev", binary_name = "tac") exposes coreutils'
tac correctly. Reference it as @<repo> (shorthand, via an alias when the repo
name differs from binary_name), @<repo>//:<binary_name>, or @<repo>//:bin (an
executable target for executable= rule attrs and aspects).
"""

def _nix_tool_impl(repository_ctx):
    """Creates a repository exposing a Nix tool under its binary name."""

    # Extract base repo name (strip bzlmod prefix like "_main~_repo_rules~")
    full_name = repository_ctx.name
    base_name = full_name.split("~")[-1] if "~" in full_name else full_name

    # Binary to find in PATH (defaults to base repo name)
    binary_name = repository_ctx.attr.binary_name or base_name

    # Find the tool in PATH (from Nix devshell)
    result = repository_ctx.execute(["which", binary_name])
    if result.return_code == 0:
        tool_path = result.stdout.strip()

        # Symlink under the binary (applet) name, not the repo name, so argv[0]
        # is the applet name. Do NOT readlink -f: that would resolve a multicall
        # applet symlink (e.g. tr) to its dispatcher (coreutils) and lose the
        # name. `which` already returns an absolute store path whose basename is
        # the applet.
        repository_ctx.symlink(tool_path, binary_name)

        # Wrapper execs the same applet-named path so @repo//:bin also keeps
        # argv[0] correct. We can't use sh_binary/native_binary because NixOS
        # patches bash to create argv[0]-based launchers that break when Bazel
        # renames binaries. /bin/sh (not /usr/bin/env bash): the body is POSIX
        # and a pure nix build sandbox provides /bin/sh but not /usr/bin/env.
        repository_ctx.file("wrapper.sh", """\
#!/bin/sh
exec {tool_path} "$@"
""".format(tool_path = tool_path), executable = True)
    else:
        # Tool not in PATH: create stubs that fail at execution time with a
        # helpful message. This allows the build to succeed for targets that
        # don't transitively depend on this tool.
        stub = """\
#!/bin/sh
echo "ERROR: Tool '{binary}' not found in PATH." >&2
echo "Make sure you're in a Nix devshell with the tool available:" >&2
echo "  nix develop" >&2
exit 1
""".format(binary = binary_name)
        repository_ctx.file(binary_name, stub, executable = True)
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

    # @repo shorthand resolves to @repo//:<base_name>; alias it to the
    # binary-named file when they differ so the applet name (argv[0]) is kept.
    alias_target = "" if base_name == binary_name else """\
# @{base_name} shorthand -> the binary-named file (preserves argv[0]).
alias(
    name = "{base_name}",
    actual = ":{binary_name}",
)
""".format(base_name = base_name, binary_name = binary_name)

    repository_ctx.file("BUILD.bazel", """\
load(":nix_executable.bzl", "nix_executable")

package(default_visibility = ["//visibility:public"])

# Raw symlink (named after the binary) for genrule $(location) usage.
exports_files(["{binary_name}"])

{alias_target}
# Executable target backed by a wrapper script that execs the applet-named
# Nix store path. Works with executable=True rule attrs and aspects.
nix_executable(
    name = "bin",
    src = "wrapper.sh",
)
""".format(binary_name = binary_name, alias_target = alias_target))

nix_tool = repository_rule(
    implementation = _nix_tool_impl,
    attrs = {
        "binary_name": attr.string(doc = "Binary name to find in PATH (defaults to repository name)"),
    },
    local = True,  # Re-run when environment changes
    doc = "Exposes a tool from the Nix devshell PATH as a Bazel target.",
)
