{
  description = "flazel nix_tool integration test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flazel = {
      url = "path:../..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      flazel,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # The default Bazel and every other supported version, each with its own
        # lockfile (nix run .#update-locks regenerates locks/).
        variants = flazel.lib.bazelVariants {
          inherit pkgs;
          root = ./.;
        };
        cachesFor =
          variant:
          flazel.lib.mkBcrCaches {
            inherit pkgs;
            lockFile = flazel.lib.parseLockFile variant.lockFile;
          };

        # Builds two genrules driven by a Nix devshell tool (tr, exposed as
        # @upcase) through both nix_tool target shapes, then asserts their
        # output. Uses the generic mkFlazelDerivation: no language toolchain
        # is needed, just the host tool.
        mkToolCheck =
          variant:
          flazel.lib.mkFlazelDerivation {
            inherit pkgs;
            inherit (variant) bazel;
            caches = cachesFor variant;
            lockFile = variant.lockOverride;
            name = "flazel-nix-tool${variant.suffix}";
            src = ./.;
            # sed (standalone binary) must be on PATH for nix_tool's `which` to
            # resolve it inside the sandbox.
            nativeBuildInputs = [ pkgs.gnused ];
            bazelCommand = "build //:via_symlink //:via_bin //:multicall_symlink //:multicall_bin";
            installPhase = ''
              # Standalone tool (sed): s/ok/OK/. Multicall tool (coreutils tr):
              # a-z A-Z uppercases the whole line, which only works if argv[0] is
              # preserved as the applet name.
              check() {
                got=$(cat "bazel-bin/$1.txt")
                echo "$1 -> $got"
                [ "$got" = "$2" ] || {
                  echo "FAIL: $1 produced \"$got\"" >&2
                  exit 1
                }
              }
              check via_symlink "flazel nix_tool OK"
              check via_bin "flazel nix_tool OK"
              check multicall_symlink "FLAZEL NIX_TOOL OK"
              check multicall_bin "FLAZEL NIX_TOOL OK"
              mkdir -p "$out"
              echo ok > "$out/result"
            '';
          };

        mkShell =
          variant:
          flazel.lib.mkFlazelDevShell {
            inherit pkgs;
            inherit (variant) bazel lockfileMode;
            caches = cachesFor variant;
            packages = [ pkgs.gnused ];
          };
      in
      {
        checks = pkgs.lib.mapAttrs' (
          _: variant: pkgs.lib.nameValuePair "nix_tool${variant.suffix}" (mkToolCheck variant)
        ) variants;

        # Manual exploration: nix develop (or .#bazel8, ...), then `bazel build //...`.
        devShells = builtins.mapAttrs (_: mkShell) variants;

        # nix run .#update-locks regenerates locks/ (run in this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = builtins.attrNames (removeAttrs variants [ "default" ]);
        };
      }
    );
}
