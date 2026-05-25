# Bazel platform constraint mapping
#
# Maps CPU and OS names to @platforms// constraint values.
# Used by cc and rust toolchain modules.
{
  cpuConstraint =
    cpu:
    {
      x86_64 = "@platforms//cpu:x86_64";
      aarch64 = "@platforms//cpu:aarch64";
      mips64 = "@platforms//cpu:mips64";
      arm = "@platforms//cpu:arm";
      riscv64 = "@platforms//cpu:riscv64";
    }
    .${cpu} or (throw "Unsupported CPU '${cpu}'. Supported: x86_64, aarch64, arm, mips64, riscv64");

  osConstraint =
    os:
    {
      linux = "@platforms//os:linux";
      none = "@platforms//os:none";
      macos = "@platforms//os:macos";
      darwin = "@platforms//os:macos";
      ios = "@platforms//os:ios";
    }
    .${os} or (throw "Unsupported OS '${os}'. Supported: linux, macos, darwin, ios, none");
}
