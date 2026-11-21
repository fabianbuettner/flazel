# Bazel platform constraint mapping
#
# Maps CPU and OS names to @platforms// constraint values, and each OS to its
# object format and whether it loads shared objects.
# Used by cc and rust toolchain modules.
# Keep the constraints in sync with _CPU_CONSTRAINTS/_OS_CONSTRAINTS in bazel/nix_cc.bzl.
let
  cpuMap = {
    x86_64 = "@platforms//cpu:x86_64";
    i686 = "@platforms//cpu:x86_32";
    aarch64 = "@platforms//cpu:aarch64";
    mips64 = "@platforms//cpu:mips64";
    arm = "@platforms//cpu:arm";
    riscv32 = "@platforms//cpu:riscv32";
    riscv64 = "@platforms//cpu:riscv64";
  };
  # format: what the linker writes. dynamic: whether the OS loads shared objects.
  osMap = {
    linux = {
      constraint = "@platforms//os:linux";
      format = "elf";
      dynamic = true;
    };
    none = {
      constraint = "@platforms//os:none";
      format = "elf";
      dynamic = false;
    };
    macos = {
      constraint = "@platforms//os:macos";
      format = "macho";
      dynamic = true;
    };
    darwin = {
      constraint = "@platforms//os:macos";
      format = "macho";
      dynamic = true;
    };
    ios = {
      constraint = "@platforms//os:ios";
      format = "macho";
      dynamic = true;
    };
    windows = {
      constraint = "@platforms//os:windows";
      format = "pe";
      dynamic = true;
    };
  };
  supported = map: builtins.concatStringsSep ", " (builtins.attrNames map);
  osInfo = os: osMap.${os} or (throw "Unsupported OS '${os}'. Supported: ${supported osMap}");
in
{
  cpuConstraint =
    cpu: cpuMap.${cpu} or (throw "Unsupported CPU '${cpu}'. Supported: ${supported cpuMap}");

  osConstraint = os: (osInfo os).constraint;
  objectFormat = os: (osInfo os).format;
  loadsSharedObjects = os: (osInfo os).dynamic;
}
