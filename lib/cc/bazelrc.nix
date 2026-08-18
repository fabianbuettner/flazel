# .bazelrc.nix lines that select the CC toolchains.
#
# Written out identically by the cc dev shell and derivation and by the rust
# ones, which register the CC toolchains too because Rust links through them.
{
  lib,
  # Every CC toolchain to register.
  names,
}:
lib.concatMapStrings (
  name: "build --extra_toolchains=@local_config_cc_${name}//:cc_toolchain\n"
) names
