# A Bazel module named `verilator` built from a nixpkgs Verilator, for
# moduleOverrides. It stands in for the BCR module that rules_verilator
# depends on, which compiles Verilator from source, and provides the three
# targets rules_verilator uses: :verilator_executable, :verilated and :timing.
#
# Usage:
#   moduleOverrides.verilator = flazel.lib.hdl.mkVerilatorModule {
#     inherit pkgs;
#     verilator = pkgs.verilator;
#   };
{ pkgs, verilator }:
let
  root = "${verilator}/share/verilator";

  moduleBazel = pkgs.writeText "MODULE.bazel" ''
    module(name = "verilator")

    bazel_dep(name = "bazel_skylib", version = "1.9.0")
    bazel_dep(name = "platforms", version = "1.0.0")
    bazel_dep(name = "rules_cc", version = "0.2.27")
    bazel_dep(name = "lz4", version = "1.10.0.bcr.2")
    bazel_dep(name = "zlib", version = "1.3.2.bcr.3")
  '';

  # The runtime follows the BCR module's :verilated: C++17, or C++20 for the
  # coroutines of --timing, and the SystemC sources left out.
  buildBazel = pkgs.writeText "BUILD.bazel" ''
    load("@bazel_skylib//rules:common_settings.bzl", "bool_flag")
    load("@bazel_skylib//rules:native_binary.bzl", "native_binary")
    load("@rules_cc//cc:cc_library.bzl", "cc_library")

    # The warning policy is the consumer's, for their own code. The runtime's
    # sources are not theirs to fix.
    package(
        default_visibility = ["//visibility:public"],
        features = [
            "-treat_warnings_as_errors",
            "-warnings",
        ],
    )

    # verilator_bin, not the perl wrapper: it is what the BCR module builds.
    # It finds include/ through the store path compiled into it.
    native_binary(
        name = "verilator_executable",
        src = "bin/verilator_bin",
    )

    bool_flag(
        name = "timing",
        build_setting_default = False,
    )

    config_setting(
        name = "with_timing",
        flag_values = {":timing": "True"},
    )

    cc_library(
        name = "verilated",
        srcs = glob(
            ["include/verilated*.cpp"],
            exclude = [
                "include/verilated_*_sc.cpp",
                "include/verilated_timing.cpp",
            ],
        ) + select({
            ":with_timing": ["include/verilated_timing.cpp"],
            "//conditions:default": [],
        }),
        hdrs = glob(["include/**/*.h"]),
        copts = select({
            ":with_timing": ["-std=c++20"],
            "//conditions:default": ["-std=c++17"],
        }),
        # The sources in subdirectories are included by the top-level ones.
        textual_hdrs = glob(
            [
                "include/*/*.c",
                "include/*/*.cpp",
            ],
            allow_empty = True,
        ),
        includes = [
            "include",
            "include/vltstd",
        ],
        linkopts = ["-lpthread"],
        # The FST writer's compression.
        deps = [
            "@lz4",
            "@zlib",
        ],
    )
  '';
in
pkgs.runCommand "verilator-bazel-module-${verilator.version}" { } ''
  mkdir -p $out/bin
  ln -s ${root}/include $out/include
  ln -s ${verilator}/bin/verilator_bin $out/bin/verilator_bin
  cp ${moduleBazel} $out/MODULE.bazel
  cp ${buildBazel} $out/BUILD.bazel
''
