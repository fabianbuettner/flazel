"""Flazel CC toolchain config rule.

Checked-in (so buildifier and `bazel`/parse can see it) instead of embedded as a
Nix string. The dynamic, per-toolchain values (target identifiers, include
directories, isystem/link flags, std versions, compiler flavor) come in as rule
attributes; everything else is static. lib/cc/toolchain.nix copies this file into
each generated toolchain repo and instantiates the rule with the right attrs.
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "action_config",
    "artifact_name_pattern",
    "feature",
    "feature_set",
    "flag_group",
    "flag_set",
    "tool",
    "tool_path",
    "with_feature_set",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

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

# The C++ actions, header parsing included unless it parses C
# (parse_headers_as_c); every C++-only flag goes through this.
def _cxx_flag_sets(flags):
    return [
        flag_set(
            actions = [a for a in _CXX_ACTIONS if a != ACTION_NAMES.cpp_header_parsing],
            flag_groups = [flag_group(flags = flags)],
        ),
        flag_set(
            actions = [ACTION_NAMES.cpp_header_parsing],
            flag_groups = [flag_group(flags = flags)],
            with_features = [with_feature_set(not_features = ["parse_headers_as_c"])],
        ),
    ]

# Header parsing gets the compile's -O and -D flags, as in rules_cc, whose opt
# and dbg flags cover all_compile_actions (unix_cc_toolchain_config.bzl).
_SOURCE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.cpp_header_parsing,
]

# Actions that read module maps, as in rules_cc's layering_check_features.
_MODULE_MAP_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
]
_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
]

# -fPIC for objects linked into shared libraries; executables still link
# statically (no supports_dynamic_linker). Not on Windows, where -fPIC only
# warns.
def _pic_features():
    return [
        feature(name = "supports_pic", enabled = True),
        feature(
            name = "pic",
            enabled = True,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(
                    flags = ["-fPIC"],
                    expand_if_available = "pic",
                )],
            )],
        ),
    ]

# Windows: .exe and .dll names, and DLLs copied beside the binaries
# that load them.
def _windows_features():
    return [
        feature(name = "targets_windows", enabled = True),
        feature(name = "copy_dynamic_libraries_to_binary", enabled = True),
    ]

_WINDOWS_ARTIFACT_NAMES = [
    artifact_name_pattern(category_name = "executable", prefix = "", extension = ".exe"),
    artifact_name_pattern(category_name = "dynamic_library", prefix = "", extension = ".dll"),
]

# Clang-only features: emitted only for clang toolchains (see is_clang attr).
def _clang_features():
    return [
        feature(
            name = "template_diagnostics",
            flag_sets = _cxx_flag_sets([
                "-fdiagnostics-show-template-tree",
                "-ftemplate-backtrace-limit=0",
            ]),
        ),
        # As rules_cc's layering_check_features (unix_cc_toolchain_config.bzl).
        # module_maps only has a .cppmap written per target; it adds no flag.
        feature(name = "module_maps", enabled = True),
        feature(
            name = "use_module_maps",
            requires = [feature_set(features = ["module_maps"])],
            flag_sets = [flag_set(
                actions = _MODULE_MAP_ACTIONS,
                flag_groups = [flag_group(flags = [
                    "-fmodule-name=%{module_name}",
                    "-fmodule-map-file=%{module_map_file}",
                    # C++20 and later enable C++ modules, which Bazel's module
                    # maps are not; rules_cc adds this for clang 14+.
                    "-Xclang",
                    "-fno-cxx-modules",
                ])],
            )],
        ),
        feature(
            name = "layering_check",
            implies = ["use_module_maps"],
            flag_sets = [flag_set(
                actions = _MODULE_MAP_ACTIONS,
                flag_groups = [
                    flag_group(flags = [
                        "-fmodules-strict-decluse",
                        "-Wprivate-header",
                    ]),
                    flag_group(
                        iterate_over = "dependent_module_map_files",
                        flags = ["-fmodule-map-file=%{dependent_module_map_files}"],
                    ),
                ],
            )],
        ),
    ]

# As rules_cc's parse_headers_support: a wrapper creates the .h.processed
# that the compiler does not write under -fsyntax-only, and parse_headers_as_c
# parses a target's headers as C.
def _parse_headers(ctx):
    if not ctx.attr.supports_header_parsing:
        return [], []
    flags = ["-fsyntax-only"] + ctx.attr.parse_headers_flags
    action_configs = [action_config(
        action_name = ACTION_NAMES.cpp_header_parsing,
        tools = [tool(path = "bin/parse_headers")],
        flag_sets = [
            flag_set(
                flag_groups = [flag_group(flags = ["-xc++-header"] + flags)],
                with_features = [with_feature_set(not_features = ["parse_headers_as_c"])],
            ),
            flag_set(
                flag_groups = [flag_group(flags = ["-xc-header"] + flags)],
                with_features = [with_feature_set(features = ["parse_headers_as_c"])],
            ),
        ],
        implies = [
            "legacy_compile_flags",
            "user_compile_flags",
            "sysroot",
            "unfiltered_compile_flags",
            "compiler_input_flags",
            "compiler_output_flags",
        ],
    )]
    features = [
        feature(name = "parse_headers"),
        feature(name = "parse_headers_as_c"),
    ]
    return action_configs, features

# @DEPS@ in flags is the deps repo's execroot path, known only here under
# bzlmod.
def _with_deps_root(ctx, flags):
    root = ctx.attr.deps.label.workspace_root
    return [flag.replace("@DEPS@", root) for flag in flags]

def _impl(ctx):
    parse_headers_action_configs, parse_headers_features = _parse_headers(ctx)
    features = [
        feature(
            # Headers of external repositories (every nixpkgs library) are system
            # headers, on every Bazel version: Bazel 9's cc_library passes its
            # `includes` with -I, earlier versions with -isystem.
            name = "external_include_paths",
            enabled = True,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(
                    flags = ["-isystem", "%{external_include_paths}"],
                    iterate_over = "external_include_paths",
                    expand_if_available = "external_include_paths",
                )],
            )],
        ),
        feature(
            name = "compile_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                # mcfgthread's atomic.h includes __FILE__, an execroot-relative path;
                # Bazel adds "-iquote ." only for the main repository.
                flag_groups = [flag_group(flags = ["-iquote", "."] + _with_deps_root(ctx, ctx.attr.compile_isystem_flags))],
            )],
        ),
        feature(
            # -ffreestanding asserts a freestanding environment (no hosted libc
            # semantics, program entry need not be main, __STDC_HOSTED__ == 0).
            # Compile-side counterpart to the bare-metal -nostdlib link posture;
            # driven by target.freestanding, not normally toggled per build.
            name = "freestanding",
            enabled = ctx.attr.freestanding,
            flag_sets = [flag_set(
                actions = _COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ["-ffreestanding"])],
            )],
        ),
        feature(
            name = "cxx_flags",
            enabled = True,
            flag_sets = _cxx_flag_sets(["-std=" + ctx.attr.cxx_standard]),
        ),
        feature(
            name = "c_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = [ACTION_NAMES.c_compile],
                    flag_groups = [flag_group(flags = ["-std=" + ctx.attr.c_standard])],
                ),
                flag_set(
                    actions = [ACTION_NAMES.cpp_header_parsing],
                    flag_groups = [flag_group(flags = ["-std=" + ctx.attr.c_standard])],
                    with_features = [with_feature_set(features = ["parse_headers_as_c"])],
                ),
            ],
        ),
        feature(
            name = "link_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = _LINK_ACTIONS,
                flag_groups = [flag_group(flags = _with_deps_root(ctx, ctx.attr.link_flags))],
            )],
        ),
        feature(
            name = "opt",
            flag_sets = [flag_set(
                actions = _SOURCE_ACTIONS,
                flag_groups = [flag_group(flags = ["-O2", "-DNDEBUG"])],
            )],
        ),
        feature(
            name = "dbg",
            flag_sets = [flag_set(
                actions = _SOURCE_ACTIONS,
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
            flag_sets = _cxx_flag_sets(["-D_GLIBCXX_ASSERTIONS"]),
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
                    actions = _SOURCE_ACTIONS,
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
            flag_sets = _cxx_flag_sets([
                "-fvisibility=hidden",
                "-fvisibility-inlines-hidden",
            ]),
        ),
        feature(
            # ELF only; for PE, gcc would call an unprefixed objcopy.
            name = "split_debug",
            enabled = not ctx.attr.targets_windows,
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
                actions = _SOURCE_ACTIONS,
                flag_groups = [flag_group(flags = ["-fno-omit-frame-pointer"])],
                with_features = [with_feature_set(features = ["dbg"])],
            )],
        ),
    ] + (_windows_features() if ctx.attr.targets_windows else _pic_features()) + (_clang_features() if ctx.attr.is_clang else []) + parse_headers_features

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
        action_configs = parse_headers_action_configs,
        artifact_name_patterns = _WINDOWS_ARTIFACT_NAMES if ctx.attr.targets_windows else [],
    )

cc_toolchain_config = rule(
    implementation = _impl,
    attrs = {
        "builtin_include_directories": attr.string_list(mandatory = True),
        "c_standard": attr.string(mandatory = True),
        "compile_isystem_flags": attr.string_list(mandatory = True),
        "compiler": attr.string(mandatory = True),
        "cxx_standard": attr.string(mandatory = True),
        # The toolchain's deps repo, for the @DEPS@ substitution.
        "deps": attr.label(mandatory = True),
        "freestanding": attr.bool(mandatory = True),
        "is_clang": attr.bool(mandatory = True),
        "link_flags": attr.string_list(mandatory = True),
        "lto_flag": attr.string(mandatory = True),
        # Appended to the header-parse action's own flags.
        "parse_headers_flags": attr.string_list(mandatory = True),
        "target_cpu": attr.string(mandatory = True),
        "target_libc": attr.string(mandatory = True),
        "target_system_name": attr.string(mandatory = True),
        "supports_header_parsing": attr.bool(mandatory = True),
        "targets_windows": attr.bool(mandatory = True),
    },
    provides = [CcToolchainConfigInfo],
)
