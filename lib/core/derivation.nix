# Generic Flazel derivation builder (language-agnostic)
#
# Provides a minimal Bazel build derivation without any language-specific
# assumptions. Language-specific modules (cc, rust, etc.) can wrap this
# and add their own configuration.
#
# Usage:
#   build = flazel.lib.mkFlazelDerivation {
#     inherit pkgs;
#     name = "my-project";
#     src = ./.;
#     caches = flazel.lib.mkBcrCaches { ... };
#     bazelCommand = "build //...";
#     installPhase = "cp -rL bazel-bin/* $out/";
#   };
#
rec {
  # Generate .bazelrc.nix lines for flazel module override and non-BCR deps
  mkBazelrcFooter =
    {
      flazelPath ? null,
      caches,
    }:
    (if flazelPath != null then "build --override_module=flazel=${flazelPath}\n" else "")
    + (
      if caches ? nonBcrOverrideFlags && caches.nonBcrOverrideFlags != "" then
        caches.nonBcrOverrideFlags + "\n"
      else
        ""
    );

  # Generate shell script to set up .nix-bazel-deps directory (core setup)
  mkFlazelDepsSetup =
    {
      caches,
      # Path to flazel source (auto-injected, used for --override_module in .bazelrc.nix)
      flazelPath ? null,
      # Optional: additional setup for toolchain/libs (provided by language modules)
      extraSetup ? "",
    }:
    ''
      # Create .nix-bazel-deps with writable caches
      rm -rf .nix-bazel-deps
      mkdir -p .nix-bazel-deps
      cp -rL ${caches.bazelRepoCache} .nix-bazel-deps/repo-cache
      cp -rL ${caches.bazelRegistryCache} .nix-bazel-deps/registry
      chmod -R u+w .nix-bazel-deps/repo-cache .nix-bazel-deps/registry
      ${extraSetup}
    '';

  # Generic Bazel build derivation
  mkFlazelDerivation =
    {
      pkgs,
      name,
      src,
      caches,
      bazelCommand,
      installPhase,
      # Bazel package to use (defaults to latest stable)
      bazel ? pkgs.bazel,
      # Path to flazel source (auto-injected, used for --override_module in .bazelrc.nix)
      flazelPath ? null,
      # Optional: extra setup script (for language-specific toolchain/libs)
      extraDepsSetup ? "",
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      runtimeDependencies ? [ ],
      bazelOutputBase ? "$TMPDIR/bazel-out",
    }:
    pkgs.stdenv.mkDerivation {
      inherit
        name
        src
        installPhase
        runtimeDependencies
        ;

      nativeBuildInputs = [
        bazel
        pkgs.coreutils
      ]
      ++ nativeBuildInputs;

      inherit buildInputs;

      buildPhase = ''
        export HOME=$TMPDIR
        ${mkFlazelDepsSetup {
          inherit caches flazelPath;
          extraSetup = extraDepsSetup;
        }}
        # Point Bazel at pre-fetched caches (no network in Nix sandbox)
        echo "build --registry=file://$(pwd)/.nix-bazel-deps/registry" >> .nix-bazel-deps/.bazelrc.nix
        echo "build --repository_cache=$(pwd)/.nix-bazel-deps/repo-cache" >> .nix-bazel-deps/.bazelrc.nix
        bazel --output_user_root=${bazelOutputBase} ${bazelCommand}
      '';
    };
}
