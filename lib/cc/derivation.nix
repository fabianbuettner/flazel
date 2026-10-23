# CC-specific Flazel derivation builder
#
# Wraps the core mkFlazelDerivation with C/C++ toolchain configuration.
#
# Usage:
#   cfg = flazel.lib.cc.mkConfig { toolchainName = "default"; ... };
#   build = flazel.lib.cc.mkDerivation {
#     inherit pkgs cfg caches;
#     name = "my-project";
#     src = ./.;
#     bazelCommand = "build --config=nix //...";
#     installPhase = "cp -rL bazel-bin/* $out/";
#   };
#
{
  pkgs,
  name,
  cfg,
  caches,
  src,
  bazelCommand,
  installPhase,
  # Bazel package to use (defaults to latest stable)
  bazel ? pkgs.bazel,
  # Path to flazel source (auto-injected, used for --override_module in .bazelrc.nix)
  flazelPath ? null,
  extraNativeBuildInputs ? [ ],
  extraBuildInputs ? [ ],
}:
let
  coreDeriv = import ../core/derivation.nix;
  inherit (import ../core/constants.nix) nixDepsDir;

  # CC-specific setup: symlink toolchain and libs
  # Uses new directory structure: toolchains/<name>/cc, toolchains/<name>/deps
  ccDepsSetup = ''
    mkdir -p ${nixDepsDir}/toolchains
    # flazel_link, not `ln -s`: the core setup no longer wipes the deps directory, so
    # a bare `ln -s` would fail on the second entry with the link already there. It
    # also must not unlink first -- ${nixDepsDir}/libs is where a consumer's build
    # resolves its headers, and removing it mid-build is the failure the core comment
    # describes. See mkFlazelDepsSetup for the helper and the reasoning.
    flazel_link ${cfg.bazelNixDeps}/toolchains/${cfg.toolchainName} ${nixDepsDir}/toolchains/${cfg.toolchainName}
    flazel_link ${cfg.bazelNixDeps}/libs ${nixDepsDir}/libs
  '';
in
coreDeriv.mkFlazelDerivation {
  inherit
    pkgs
    name
    src
    caches
    bazel
    flazelPath
    bazelCommand
    installPhase
    ;

  toolchainLines = import ./bazelrc.nix {
    inherit (pkgs) lib;
    names = [ cfg.toolchainName ];
  };
  extraDepsSetup = ccDepsSetup;

  nativeBuildInputs = [
    cfg.gcc
    cfg.binutils
  ]
  ++ pkgs.lib.optional (!cfg.static) pkgs.autoPatchelfHook
  ++ extraNativeBuildInputs;

  buildInputs = [
    cfg.libc
    cfg.libcDev
    cfg.gcc.cc
  ]
  ++ (if cfg.static then [ ] else builtins.attrValues cfg.nixpkgsLibs)
  ++ extraBuildInputs;

  # The output holding the libraries, as nixpkgs-repo.nix links them: `lib`
  # when split out, else `out` (for clang that would be the compiler).
  runtimeDependencies =
    if cfg.static then
      [ ]
    else
      map (pkg: pkg.lib or pkg.out or pkg) (builtins.attrValues cfg.nixpkgsLibs);
}
