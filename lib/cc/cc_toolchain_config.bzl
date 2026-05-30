"""Flazel CC toolchain config rule.

Checked-in (so buildifier and `bazel`/parse can see it) instead of embedded as a
Nix string. The dynamic, per-toolchain values (target identifiers, include
directories, isystem/link flags, std versions, compiler flavor) come in as rule
attributes; everything else is static. lib/cc/toolchain.nix copies this file into
each generated toolchain repo and instantiates the rule with the right attrs.
"""

load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "ACTION_NAMES")
load(
    "@bazel_tools//tools/cpp:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
    "with_feature_set",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

_COMPILE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.linkstamp_compile,
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
]
_CXX_ACTIONS = [
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.linkstamp_compile,
]
_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
]

# Clang-only features: emitted only for clang toolchains (see is_clang attr).
def _clang_features():
    return [
        feature(
            name = "template_diagnostics",
            flag_sets = [flag_set(
                actions = _CXX_ACTIONS,
                flag_groups = [flag_group(flags = [
                    "-fdiagnostics-show-template-tree",
                    "-ftemplate-backtrace-limit=0",
                ])],
            )],
        ),
        feature(
            name = "module_maps",
            enabled = True,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = [
                    "-fmodule-map-file=%{module_map_file}",
                ])],
            )],
        ),
        feature(
            name = "layering_check",
            flag_sets = [flag_set(
                actions = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile],
                flag_groups = [flag_group(flags = [
                    "-fmodules-strict-decluse",
                    "-Wprivate-header",
                ])],
            )],
        ),
        feature(
            name = "parse_headers",
            flag_sets = [flag_set(
                actions = [ACTION_NAMES.cpp_header_parsing],
                flag_groups = [flag_group(flags = ["-fsyntax-only"])],
            )],
        ),
    ]

def _impl(ctx):
    features = [
        feature(
            name = "compile_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ctx.attr.compile_isystem_flags)],
            )],
        ),
        feature(
            name = "cxx_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = _CXX_ACTIONS,
                flag_groups = [flag_group(flags = ["-std=" + ctx.attr.cxx_standard])],
            )],
        ),
        feature(
            name = "c_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = [ACTION_NAMES.c_compile],
                flag_groups = [flag_group(flags = ["-std=" + ctx.attr.c_standard])],
            )],
        ),
        feature(
            name = "link_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = _LINK_ACTIONS,
                flag_groups = [flag_group(flags = ctx.attr.link_flags)],
            )],
        ),
        feature(
            name = "opt",
            flag_sets = [flag_set(
                actions = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile],
                flag_groups = [flag_group(flags = ["-O2", "-DNDEBUG"])],
            )],
        ),
        feature(
            name = "dbg",
            flag_sets = [flag_set(
                actions = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile],
                flag_groups = [flag_group(flags = ["-g", "-O0"])],
            )],
        ),
        feature(
            name = "warnings",
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = [
                    "-Wall",
                    "-Wextra",
                ])],
            )],
        ),
        feature(
            name = "warnings_pedantic",
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = [
                    "-Wpedantic",
                    "-Wconversion",
                    "-Wshadow",
                    "-Wnon-virtual-dtor",
                    "-Wold-style-cast",
                    "-Wcast-align",
                    "-Woverloaded-virtual",
                    "-Wdouble-promotion",
                    "-Wformat=2",
                ])],
            )],
        ),
        feature(
            name = "treat_warnings_as_errors",
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ["-Werror"])],
            )],
        ),
        feature(
            name = "glibcxx_assertions",
            enabled = True,
            flag_sets = [flag_set(
                actions = _CXX_ACTIONS,
                flag_groups = [flag_group(flags = ["-D_GLIBCXX_ASSERTIONS"])],
            )],
        ),
        feature(
            # _FORTIFY_SOURCE is a no-op without optimization: at -O0 glibc
            # disables it and warns. Gate it on the opt feature (the only one
            # that adds -O) so it applies exactly where it works, like
            # gc_sections and split_debug below.
            name = "fortify_source",
            enabled = True,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ["-D_FORTIFY_SOURCE=3"])],
                with_features = [with_feature_set(features = ["opt"])],
            )],
        ),
        feature(
            name = "stack_protector_strong",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = ["-fstack-protector-strong"])],
                ),
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = ["-fstack-protector-strong"])],
                ),
            ],
        ),
        feature(
            name = "asan",
            provides = ["sanitizer"],
            flag_sets = [
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = [
                        "-fsanitize=address",
                        "-fno-omit-frame-pointer",
                        "-fno-sanitize-recover=all",
                    ])],
                ),
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = ["-fsanitize=address"])],
                ),
            ],
        ),
        feature(
            name = "ubsan",
            flag_sets = [
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = [
                        "-fsanitize=undefined",
                        "-fno-sanitize-recover=undefined",
                    ])],
                ),
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = ["-fsanitize=undefined"])],
                ),
            ],
        ),
        feature(
            name = "tsan",
            provides = ["sanitizer"],
            flag_sets = [
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = [
                        "-fsanitize=thread",
                        "-fno-omit-frame-pointer",
                    ])],
                ),
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = ["-fsanitize=thread"])],
                ),
            ],
        ),
        feature(
            name = "thin_lto",
            flag_sets = [
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = [ctx.attr.lto_flag])],
                ),
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = [ctx.attr.lto_flag])],
                ),
            ],
        ),
        feature(
            name = "gc_sections",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile],
                    flag_groups = [flag_group(flags = [
                        "-ffunction-sections",
                        "-fdata-sections",
                    ])],
                    with_features = [with_feature_set(features = ["opt"])],
                ),
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = ["-Wl,--gc-sections"])],
                    with_features = [with_feature_set(features = ["opt"])],
                ),
            ],
        ),
        feature(
            name = "hidden_visibility",
            flag_sets = [flag_set(
                actions = _CXX_ACTIONS,
                flag_groups = [flag_group(flags = [
                    "-fvisibility=hidden",
                    "-fvisibility-inlines-hidden",
                ])],
            )],
        ),
        feature(
            name = "split_debug",
            enabled = True,
            flag_sets = [flag_set(
                actions = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile],
                flag_groups = [flag_group(flags = ["-gsplit-dwarf"])],
                with_features = [with_feature_set(features = ["dbg"])],
            )],
        ),
        feature(
            # -Wl,--gdb-index requires gold, lld, or mold; ld.bfd does not support it.
            # Off by default so projects that link with bfd (or run `bazel coverage`,
            # which forces dbg mode) do not break. Opt in via `--features=gdb_index`.
            name = "gdb_index",
            enabled = False,
            flag_sets = [flag_set(
                actions = _LINK_ACTIONS,
                flag_groups = [flag_group(flags = ["-Wl,--gdb-index"])],
                with_features = [with_feature_set(features = ["dbg"])],
            )],
        ),
        feature(
            name = "colored_diagnostics",
            enabled = True,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ["-fdiagnostics-color=always"])],
            )],
        ),
        feature(
            name = "debug_prefix_map",
            enabled = True,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = [
                    "-ffile-prefix-map=/proc/self/cwd=.",
                ])],
            )],
        ),
        feature(
            name = "frame_pointer",
            enabled = True,
            flag_sets = [flag_set(
                actions = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile],
                flag_groups = [flag_group(flags = ["-fno-omit-frame-pointer"])],
                with_features = [with_feature_set(features = ["dbg"])],
            )],
        ),
    ] + (_clang_features() if ctx.attr.is_clang else [])

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "local_" + ctx.attr.target_system_name,
        host_system_name = "local",
        target_system_name = ctx.attr.target_system_name,
        target_cpu = ctx.attr.target_cpu,
        target_libc = ctx.attr.target_libc,
        compiler = ctx.attr.compiler,
        abi_version = "local",
        abi_libc_version = "local",
        cxx_builtin_include_directories = ctx.attr.builtin_include_directories,
        tool_paths = [
            tool_path(name = "gcc", path = "bin/gcc"),
            tool_path(name = "g++", path = "bin/g++"),
            tool_path(name = "cpp", path = "bin/cpp"),
            tool_path(name = "ar", path = "bin/ar"),
            tool_path(name = "nm", path = "bin/nm"),
            tool_path(name = "objdump", path = "bin/objdump"),
            tool_path(name = "objcopy", path = "bin/objcopy"),
            tool_path(name = "strip", path = "bin/strip"),
            tool_path(name = "ld", path = "bin/ld"),
            tool_path(name = "gcov", path = "bin/gcov"),
            tool_path(name = "dwp", path = "bin/dwp"),
            tool_path(name = "llvm-profdata", path = "bin/llvm-profdata"),
        ],
        features = features,
    )

cc_toolchain_config = rule(
    implementation = _impl,
    attrs = {
        "builtin_include_directories": attr.string_list(mandatory = True),
        "c_standard": attr.string(mandatory = True),
        "compile_isystem_flags": attr.string_list(mandatory = True),
        "compiler": attr.string(mandatory = True),
        "cxx_standard": attr.string(mandatory = True),
        "is_clang": attr.bool(mandatory = True),
        "link_flags": attr.string_list(mandatory = True),
        "lto_flag": attr.string(mandatory = True),
        "target_cpu": attr.string(mandatory = True),
        "target_libc": attr.string(mandatory = True),
        "target_system_name": attr.string(mandatory = True),
    },
    provides = [CcToolchainConfigInfo],
)
