{
  description = "flazel nix_perl integration test";

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
        inherit (pkgs) lib;

        # The default Bazel and every other supported version, each with its own
        # lockfile (nix run .#update-locks regenerates locks/).
        variants = flazel.lib.bazelVariants {
          inherit pkgs;
          root = ./.;
        };
        otherVariants = removeAttrs variants [ "default" ];
        # The default Bazel without the opt-in, whose manifest update-locks
        # observes in the perl-off shell: it holds the perl rules_perl downloads.
        perlOff = variants.default // {
          lockFile = ./locks/perl-off.lock;
          archives = ./locks/perl-off.archives.json;
          lockOverride = ./locks/perl-off.lock;
          lockfileMode = "off";
        };
        cachesFor =
          variant:
          flazel.lib.mkBcrCaches {
            inherit pkgs;
            lockFile = flazel.lib.parseLockFile variant.lockFile;
            archives = flazel.lib.parseArchiveManifest variant.archives;
          };

        ccCfg = flazel.lib.cc.mkConfig { inherit pkgs; };

        # $] of pkgs.perl: 5.42.3 is 5.042003.
        perlNumericVersion =
          let
            parts = lib.splitVersion pkgs.perl.version;
            part = i: lib.fixedWidthNumber 3 (lib.toInt (builtins.elemAt parts i));
          in
          "${builtins.elemAt parts 0}.${part 1}${part 2}";

        targets = "//:via_binary //:via_make_var //:via_exec_make_var";

        # Each target's report is pkgs.perl's when withPerl, and some other
        # perl's otherwise.
        expectReports = withPerl: ''
          failed=0
          for target in via_binary via_make_var via_exec_make_var; do
            report=bazel-bin/$target.json
            # $^X is the path perl was started by, through Bazel's symlinks.
            exe=$(${pkgs.jq}/bin/jq -r .real $report)
            version=$(${pkgs.jq}/bin/jq -r .version $report)
            echo "$target: $(${pkgs.jq}/bin/jq -r .exe $report) -> $exe $version"
            nix=0
            case "$exe" in
            ${pkgs.perl}/bin/perl*) [ "$version" = ${perlNumericVersion} ] && nix=1 ;;
            esac
            ${
              if withPerl then
                ''
                  [ $nix = 1 ] || {
                    echo "FAIL: $target ran $exe $version, not ${pkgs.perl}/bin/perl ${perlNumericVersion}" >&2
                    failed=1
                  }
                ''
              else
                ''
                  [ $nix = 0 ] || {
                    echo "FAIL: $target ran the Nix perl without the opt-in" >&2
                    failed=1
                  }
                ''
            }
          done
          [ $failed = 0 ]
        '';

        mkCheck =
          {
            variant,
            withPerl,
          }:
          flazel.lib.cc.mkDerivation {
            inherit pkgs;
            inherit (variant) bazel;
            caches = cachesFor variant;
            lockFile = variant.lockOverride;
            cfg = ccCfg;
            perl = if withPerl then pkgs.perl else null;
            name = "flazel-perl${lib.optionalString (!withPerl) "-off"}${variant.suffix}";
            src = ./.;
            bazelCommand = "build ${targets}";
            installPhase = expectReports withPerl + ''
              echo ok > $out
            '';
          };

        mkShell =
          withPerl: variant:
          flazel.lib.cc.mkDevShell {
            inherit pkgs;
            inherit (variant) bazel lockfileMode;
            caches = cachesFor variant;
            toolchains.default = ccCfg;
            perl = if withPerl then pkgs.perl else null;
          };

        # Runs the hook of a dev shell in the sandbox, then builds and checks.
        mkShellCheck =
          withPerl:
          let
            variant = variants.default;
          in
          pkgs.stdenv.mkDerivation {
            name = "flazel-perl-shell${lib.optionalString (!withPerl) "-off"}";
            src = ./.;
            nativeBuildInputs = [
              (flazel.lib.bazelWithUsrBinEnv {
                inherit pkgs;
                inherit (variant) bazel;
              })
            ];
            buildPhase = ''
              export HOME=$TMPDIR
              ${(flazel.lib.cc.mkDevShell {
                inherit pkgs;
                inherit (variant) bazel lockfileMode;
                caches = cachesFor (if withPerl then variant else perlOff);
                toolchains.default = ccCfg;
                perl = if withPerl then pkgs.perl else null;
                startupOptions = [ "--output_user_root=$TMPDIR/bazel" ];
              }).shellHook
              }
              bazel build ${targets}
              ${expectReports withPerl}
              ${lib.optionalString (!withPerl) ''
                # Asked for anyway, the repo names what it lacks.
                if bazel build @nix_perl//:all 2>$TMPDIR/err; then
                  echo "FAIL: @nix_perl built without a perl" >&2
                  exit 1
                fi
                grep -F "No Nix perl at" $TMPDIR/err || {
                  echo "FAIL: @nix_perl does not say it lacks a perl" >&2
                  exit 1
                }
              ''}
              bazel shutdown
            '';
            installPhase = "echo ok > $out";
          };
      in
      {
        checks =
          lib.mapAttrs' (
            _: variant:
            lib.nameValuePair "perl${variant.suffix}" (mkCheck {
              inherit variant;
              withPerl = true;
            })
          ) variants
          // {
            shell = mkShellCheck true;
          }
          # perlOff's manifest records the generating host's perl (x86_64-linux),
          # so the off controls run there only.
          // lib.optionalAttrs (system == "x86_64-linux") {
            # The control: without the opt-in another perl runs, which the
            # same reports show.
            perl-off = mkCheck {
              variant = perlOff;
              withPerl = false;
            };
            shell-off = mkShellCheck false;
          };

        devShells = builtins.mapAttrs (_: mkShell true) variants // {
          perl-off = mkShell false perlOff;
        };

        # nix run .#update-locks regenerates locks/ (run in this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = builtins.attrNames otherVariants ++ [ "perl-off" ];
          probes = [ [ "//..." ] ];
        };
      }
    );
}
