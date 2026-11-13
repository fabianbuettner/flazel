"""A cc library whose sources are generated into a directory (tree artifact).

Code generators that cannot name their outputs in advance (Verilator, protoc
plugins) produce one. Its objects reach the linker as an object file group.
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _impl(ctx):
    srcs = ctx.actions.declare_directory(ctx.label.name + "_srcs")
    ctx.actions.run_shell(
        outputs = [srcs],
        command = """
cat > {dir}/message.cc <<'CC'
#include "tree/message.h"
const char* message() {{ return "{text}"; }}
CC
""".format(dir = srcs.path, text = ctx.attr.text),
        mnemonic = "GenerateSources",
    )
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    compilation_context, compilation_outputs = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = [srcs],
        public_hdrs = ctx.files.hdrs,
    )
    linking_context, _ = cc_common.create_linking_context_from_compilation_outputs(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
    )
    return [CcInfo(compilation_context = compilation_context, linking_context = linking_context)]

generated_cc_library = rule(
    implementation = _impl,
    attrs = {
        "hdrs": attr.label_list(allow_files = [".h"]),
        "text": attr.string(mandatory = True),
    },
    provides = [CcInfo],
    toolchains = use_cc_toolchain(),
    fragments = ["cpp"],
)
