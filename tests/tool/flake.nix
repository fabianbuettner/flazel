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

        caches = flazel.lib.mkBcrCaches {
          inherit pkgs;
          lockFile = flazel.lib.parseLockFile ./MODULE.bazel.lock;
        };
      in
      {
        # Builds two genrules driven by a Nix devshell tool (tr, exposed as
        # @upcase) through both nix_tool target shapes, then asserts their
        # output. Uses the generic mkFlazelDerivation: no language toolchain
        # is needed, just the host tool.
        checks.nix_tool = flazel.lib.mkFlazelDerivation {
          inherit pkgs caches;
          name = "flazel-nix-tool";
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

        # Manual exploration: nix develop, then `bazel build //...`.
        devShells.default = flazel.lib.mkFlazelDevShell {
          inherit pkgs caches;
          packages = [ pkgs.gnused ];
        };
      }
    );
}
