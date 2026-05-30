# Bazel platform constraint mapping
#
# Maps CPU and OS names to @platforms// constraint values.
# Used by cc and rust toolchain modules.
# Keep in sync with _CPU_CONSTRAINTS/_OS_CONSTRAINTS in bazel/nix_cc.bzl.
let
  cpuMap = {
    x86_64 = "@platforms//cpu:x86_64";
    aarch64 = "@platforms//cpu:aarch64";
    mips64 = "@platforms//cpu:mips64";
    arm = "@platforms//cpu:arm";
    riscv32 = "@platforms//cpu:riscv32";
    riscv64 = "@platforms//cpu:riscv64";
  };
  osMap = {
    linux = "@platforms//os:linux";
    none = "@platforms//os:none";
    macos = "@platforms//os:macos";
    darwin = "@platforms//os:macos";
    ios = "@platforms//os:ios";
  };
  supported = map: builtins.concatStringsSep ", " (builtins.attrNames map);
in
{
  cpuConstraint =
    cpu: cpuMap.${cpu} or (throw "Unsupported CPU '${cpu}'. Supported: ${supported cpuMap}");

  osConstraint = os: osMap.${os} or (throw "Unsupported OS '${os}'. Supported: ${supported osMap}");
}
