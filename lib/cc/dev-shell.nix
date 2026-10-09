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

  # One tree per destination, merged HERE rather than in the dev shell hook, because
  # the contents are a pure function of the toolchain set. Assembling them per entry
  # cost a subprocess per file per entry (a basename and a readlink each, ~160
  # subprocesses and ~360ms on a two-toolchain consumer) and needed the hook to prune
  # names the configuration had dropped. A store path needs neither: swapping the one
  # symlink below replaces the whole set at once, and what it replaced is collected.
  #
  # `ln -sfn` is right inside a derivation, where nothing can observe the output until
  # it is complete, and is what makes a later toolchain win a name several provide.
  # Attribute order decides that, as it did when this loop ran in the hook.
  mergedToolchains = pkgs.runCommand "flazel-cc-toolchains" { } ''
    mkdir -p $out
    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (
        name: cfg: "ln -sfn ${cfg.bazelNixDeps}/toolchains/${name} $out/${name}"
      ) toolchains
    )}
  '';

  # Each bazelNixDeps already carries both the suffixed and the unsuffixed name (e.g.
  # boost and boost_default), so merging is what gives one unsuffixed winner.
  mergedLibs = pkgs.runCommand "flazel-cc-libs" { } ''
    mkdir -p $out
    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: cfg: ''
        for lib in ${cfg.bazelNixDeps}/libs/*; do
          ln -sfn "$lib" "$out/$(basename "$lib")"
        done
      '') toolchains
    )}
  '';

  # Two symlinks, each skipped when it already points where it should. This is the
  # same shape the build derivation uses, which links one toolchain's libs directly:
  # the two paths differed only because this one had several toolchains to merge.
  ccDepsSetup = ''
    flazel_link ${mergedToolchains} ${nixDepsDir}/toolchains
    flazel_link ${mergedLibs} ${nixDepsDir}/libs
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
