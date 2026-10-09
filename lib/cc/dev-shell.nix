# CC-specific Flazel development shell
#
# Wraps the core mkFlazelDevShell with C/C++ toolchain packages.
# Supports multiple toolchains for cross-compilation.
#
# Usage:
#   hostCfg = flazel.lib.cc.mkConfig { toolchainName = "host"; ... };
#   mips64Cfg = flazel.lib.cc.mkConfig { toolchainName = "mips64"; ... };
#   shell = flazel.lib.cc.mkDevShell {
#     inherit pkgs caches;
#     toolchains = {
#       host = hostCfg;
#       mips64 = mips64Cfg;
#     };
#   };
#
{
  pkgs,
  # Attrset of { name = cfg; } for each toolchain
  toolchains,
  caches,
  # Bazel package to use (defaults to latest stable)
  bazel ? pkgs.bazel,
  # Path to flazel source (auto-injected, used for --override_module in .bazelrc.nix)
  flazelPath ? null,
  extraPackages ? [ ],
  shellHook ? "",
}:
let
  coreDevShell = import ../core/dev-shell.nix;
  inherit (import ../core/constants.nix) nixDepsDir;

  # Get list of toolchain configs
  toolchainList = pkgs.lib.attrValues toolchains;
  toolchainNames = pkgs.lib.attrNames toolchains;

  # Use the first toolchain for PATH packages (gcc, binutils)
  # All toolchains should have compatible host tools
  primaryCfg = builtins.head toolchainList;

  # CC-specific setup: symlink toolchains and libs.
  #
  # flazel_link_dir, not `ln -s` / `ln -sfn`: this runs on every `nix develop` entry,
  # including the `nix develop --command bazel ...` form, so it runs while another
  # bazel is starting. `ln -sfn` unlinks before it symlinks, which left every library
  # in ${nixDepsDir}/libs briefly absent on each entry -- and that directory is where a
  # consumer's build resolves the headers of the libraries its toolchain names, so a
  # build landing in the window failed on a missing header. One call per directory
  # carrying every source, since the helper prunes what its arguments do not name.
  ccDepsSetup = ''
    flazel_link_dir ${nixDepsDir}/toolchains ${
      pkgs.lib.concatStringsSep " " (
        pkgs.lib.mapAttrsToList (name: cfg: "${cfg.bazelNixDeps}/toolchains/${name}") toolchains
      )
    }

    # Merge libs from all toolchains (each bazelNixDeps already has both suffixed and
    # unsuffixed symlinks, e.g., boost and boost_default). The globs expand in
    # attribute order, so a later toolchain still wins the unsuffixed name.
    flazel_link_dir ${nixDepsDir}/libs ${
      pkgs.lib.concatStringsSep " " (
        pkgs.lib.mapAttrsToList (name: cfg: "${cfg.bazelNixDeps}/libs/*") toolchains
      )
    }
  '';

  ccToolchainLines = import ./bazelrc.nix {
    inherit (pkgs) lib;
    names = toolchainNames;
  };

  # Generate toolchain info for shell hook
  toolchainInfo = pkgs.lib.concatStringsSep ", " (
    pkgs.lib.mapAttrsToList (
      name: cfg: "${name} (${if cfg.static then "static" else "dynamic"})"
    ) toolchains
  );
in
coreDevShell {
  inherit
    pkgs
    caches
    bazel
    flazelPath
    ;

  toolchainLines = ccToolchainLines;
  extraDepsSetup = ccDepsSetup;

  packages = [
    primaryCfg.gcc
    primaryCfg.binutils
  ]
  ++ extraPackages;

  shellHook = ''
    echo "(CC toolchains: ${toolchainInfo})"
    echo "  Use --platforms=@local_config_cc_<name>//:platform to select"
    ${shellHook}
  '';
}
