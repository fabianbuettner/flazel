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

        lockShells = builtins.attrNames (removeAttrs variants [ "default" ]);

        # The sandbox cannot run `nix develop`; enter each shell by its hook.
        nixShim = pkgs.writeShellScriptBin "nix" ''
          [ "$1" = develop ] && [ "$3" = --command ] || {
            echo "nix shim: unsupported: $*" >&2
            exit 2
          }
          case "$2" in
          ${pkgs.lib.concatMapStrings (shell: ''
            ".#${shell}")
              export PATH="${variants.${shell}.bazel}/bin:$PATH"
              . ${pkgs.writeText "hook-${shell}" (mkShell variants.${shell}).shellHook} >/dev/null
              ;;
          '') lockShells}
          *)
            echo "nix shim: no shell $2" >&2
            exit 2
            ;;
          esac
          shift 3
          exec "$@"
        '';

        # A version starting from another's lockfile asks the registry, which
        # the sandbox cannot reach: serve every registry file the locks name.
        bcr = "https://bcr.bazel.build/";
        registryFiles = pkgs.lib.foldl' (
          acc: lock: acc // (builtins.fromJSON (builtins.readFile lock)).registryFileHashes
        ) { } ([ ./MODULE.bazel.lock ] ++ map (shell: ./locks + "/${shell}.lock") lockShells);
        localRegistry = pkgs.linkFarm "bcr-mirror" (
          pkgs.lib.mapAttrsToList (url: sha256: {
            name = pkgs.lib.removePrefix bcr url;
            path = pkgs.fetchurl { inherit url sha256; };
          }) (pkgs.lib.filterAttrs (url: _: pkgs.lib.hasPrefix bcr url) registryFiles)
        );

        # Every lockfile keeps its format; a failing step fails the app and
        # leaves no server behind to rewrite one.
        mkUpdateLocksCheck =
          { name, failing }:
          let
            app = flazel.lib.mkUpdateLocksApp {
              inherit pkgs;
              shells = lockShells;
              archives = failing;
            };
            failingArchives = pkgs.writeShellScriptBin "flazel-lock-archives" "exit 1";
          in
          pkgs.stdenv.mkDerivation {
            inherit name;
            src = ./.;
            nativeBuildInputs = [
              nixShim
              variants.default.bazel
              pkgs.jq
            ]
            ++ pkgs.lib.optional failing failingArchives;
            buildPhase = ''
              export HOME=$TMPDIR
              echo "common --registry=file://${localRegistry}" > $HOME/.bazelrc
              ${pkgs.lib.optionalString failing "echo '[]' > flazel-archives.json"}
              cp MODULE.bazel.lock $TMPDIR/root.lock
              cp -r locks $TMPDIR/committed
              failed=0
              status=0
              ${app.program} || status=$?
              if [ "$status" ${if failing then "=" else "!="} 0 ]; then
                echo "FAIL: update-locks exited $status" >&2
                failed=1
              fi
              bazel shutdown

              if ! cmp -s MODULE.bazel.lock $TMPDIR/root.lock; then
                echo "FAIL: MODULE.bazel.lock rewritten, now format $(jq .lockFileVersion MODULE.bazel.lock)" >&2
                failed=1
              fi
              ${pkgs.lib.optionalString (!failing) ''
                for shell in ${toString lockShells}; do
                  want=$(jq .lockFileVersion $TMPDIR/committed/$shell.lock)
                  got=$(jq .lockFileVersion locks/$shell.lock)
                  echo "locks/$shell.lock: format $got (committed: $want)"
                  [ "$got" = "$want" ] || failed=1
                done
              ''}
              echo "MODULE.bazel.lock: format $(jq .lockFileVersion MODULE.bazel.lock) (committed: $(jq .lockFileVersion $TMPDIR/root.lock))"
              [ "$failed" = 0 ]
            '';
            installPhase = "echo ok > $out";
          };
      in
      {
        checks =
          pkgs.lib.mapAttrs' (
            _: variant: pkgs.lib.nameValuePair "nix_tool${variant.suffix}" (mkToolCheck variant)
          ) variants
          // {
            update-locks = mkUpdateLocksCheck {
              name = "flazel-update-locks";
              failing = false;
            };
            update-locks-failing = mkUpdateLocksCheck {
              name = "flazel-update-locks-failing";
              failing = true;
            };
          };

        # Manual exploration: nix develop (or .#bazel8, ...), then `bazel build //...`.
        devShells = builtins.mapAttrs (_: mkShell) variants;

        # nix run .#update-locks regenerates locks/ (run in this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = lockShells;
        };
      }
    );
}
