# .bazelrc.nix lines that select the CC toolchains.
#
# Registration and target platform belong together. The platform each toolchain
# repo emits is what carries that toolchain's constraints (cpu, os, and the C
# environment), so leaving --platforms to Bazel's host detection lets a declared
# freestanding or cross toolchain build against a platform that contradicts it.
# Select a different one per invocation with
# --platforms=@local_config_cc_<name>//:platform.
{
  lib,
  # Every CC toolchain to register.
  names,
}:
let
  # "default" is the name the toolchain extension and every example use for the
  # toolchain a plain `bazel build` should get. Attribute order would otherwise
  # decide this alphabetically, which is arbitrary.
  primary = if lib.elem "default" names then "default" else lib.head names;
in
lib.concatMapStrings (
  name: "build --extra_toolchains=@local_config_cc_${name}//:cc_toolchain\n"
) names
+ lib.optionalString (names != [ ]) "build --platforms=@local_config_cc_${primary}//:platform\n"
