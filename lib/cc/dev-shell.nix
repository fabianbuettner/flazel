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
  # null lets flazel decide; see lib/cc/bazelrc.nix.
  defaultToolchain ? null,
  hostToolchain ? null,
  caches,
  # Bazel package to use (defaults to latest stable)
  bazel ? pkgs.bazel,
  # Bazel module name -> source path; see lib/core/derivation.nix.
  moduleOverrides ? { },
  # See lib/core/dev-shell.nix.
  lockfileMode ? null,
  extraPackages ? [ ],
  shellHook ? "",
}:
let
  coreDevShell = import ../core/dev-shell.nix;
  inherit (import ../core/constants.nix) nixDepsDir;

  ccSelection = import ./bazelrc.nix {
    inherit
      pkgs
      toolchains
      defaultToolchain
      hostToolchain
      ;
  };

  # PATH's gcc and binutils run here, so they are the host toolchain's.
  pathName = if ccSelection.host != null then ccSelection.host else ccSelection.default;
  pathPackages = pkgs.lib.optionals (pathName != null) [
    toolchains.${pathName}.gcc
    toolchains.${pathName}.binutils
  ];

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

  # Every entry is suffixed with its toolchain (boost_default), so none collide.
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
    ${ccSelection.setup}
  '';

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
    moduleOverrides
    lockfileMode
    ;

  toolchainLines = ccSelection.lines;
  extraDepsSetup = ccDepsSetup;

  packages = pathPackages ++ extraPackages;

  shellHook = ''
    echo "(CC toolchains: ${toolchainInfo}; default: ${toString ccSelection.default}, exec tools: ${
      if ccSelection.host != null then ccSelection.host else "none"
    })"
    echo "  Use --platforms=@local_config_cc_<name>//:platform to select another"
    ${shellHook}
  '';
}
