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
          bazelCommand = "build //:via_symlink //:via_bin";
          installPhase = ''
            for target in via_symlink via_bin; do
              got=$(cat "bazel-bin/$target.txt")
              echo "$target -> $got"
              [ "$got" = "flazel nix_tool OK" ] || {
                echo "FAIL: $target produced \"$got\"" >&2
                exit 1
              }
            done
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
