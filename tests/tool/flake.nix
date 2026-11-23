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
          servedArchives: variant:
          flazel.lib.mkBcrCaches {
            inherit pkgs;
            lockFile = flazel.lib.parseLockFile variant.lockFile;
            archives = flazel.lib.parseArchiveManifest variant.archives ++ servedArchives;
          };

        # Builds two genrules driven by a Nix devshell tool (tr, exposed as
        # @upcase) through both nix_tool target shapes, then asserts their
        # output, and tests a script that starts #!/usr/bin/env bash. Uses the
        # generic mkFlazelDerivation: no language toolchain is needed, just the
        # host tool.
        mkToolCheck =
          variant:
          flazel.lib.mkFlazelDerivation {
            inherit pkgs;
            inherit (variant) bazel;
            caches = cachesFor [ ] variant;
            lockFile = variant.lockOverride;
            name = "flazel-nix-tool${variant.suffix}";
            src = ./.;
            # sed (standalone binary) must be on PATH for nix_tool's `which` to
            # resolve it inside the sandbox.
            nativeBuildInputs = [ pkgs.gnused ];
            bazelCommand = "test --test_output=errors //:via_symlink //:via_bin //:multicall_symlink //:multicall_bin //:usr_bin_env_test";
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
          servedArchives: variant:
          flazel.lib.mkFlazelDevShell {
            inherit pkgs;
            inherit (variant) bazel lockfileMode;
            caches = cachesFor servedArchives variant;
            packages = [ pkgs.gnused ];
          };

        lockShells = builtins.attrNames (removeAttrs variants [ "default" ]);

        # The sandbox cannot run `nix develop`; enter each shell by its hook.
        nixShim = pkgs.writeShellScriptBin "nix" ''
          [ "$1" = develop ] || {
            echo "nix shim: unsupported: $*" >&2
            exit 2
          }
          if [ "$2" = --command ]; then
            export PATH="${variants.default.bazel}/bin:$PATH"
            . ${pkgs.writeText "hook-default" (mkShell refreshArchives variants.default).shellHook} >/dev/null
            shift 2
            exec "$@"
          fi
          [ "$3" = --command ] || {
            echo "nix shim: unsupported: $*" >&2
            exit 2
          }
          case "$2" in
          ${pkgs.lib.concatMapStrings (shell: ''
            ".#${shell}")
              export PATH="${variants.${shell}.bazel}/bin:$PATH"
              . ${
                pkgs.writeText "hook-${shell}" (mkShell refreshArchives variants.${shell}).shellHook
              } >/dev/null
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

        # A lock refresh fetches modules no build reads (rules_java, buildozer,
        # ...), so no manifest holds them: serve every module's downloads, as
        # the registry would online. Test-only: a sandbox cannot refresh a lock
        # any other way.
        refreshArchives =
          pkgs.lib.concatMap
            (
              url:
              let
                base = pkgs.lib.removeSuffix "/source.json" url;
                source = builtins.fromJSON (
                  builtins.readFile (
                    builtins.fetchurl {
                      inherit url;
                      sha256 = registryFiles.${url};
                    }
                  )
                );
                hex =
                  hash:
                  builtins.convertHash {
                    inherit hash;
                    toHashFormat = "base16";
                  };
                files =
                  subdir:
                  pkgs.lib.mapAttrsToList (name: hash: {
                    urls = [ "${base}/${subdir}/${name}" ];
                    sha256 = hex hash;
                    canonical_id = "";
                  }) (source.${subdir} or { });
              in
              [
                {
                  urls = [ source.url ];
                  sha256 = hex source.integrity;
                  canonical_id = "";
                }
              ]
              ++ files "patches"
              ++ files "overlay"
            )
            (
              builtins.filter (url: pkgs.lib.hasPrefix bcr url && pkgs.lib.hasSuffix "/source.json" url) (
                builtins.attrNames registryFiles
              )
            );

        # Runs the app with args in this project after prepare, then the expect
        # shell snippet. No step may leave MODULE.bazel.lock in another Bazel
        # version's format.
        mkUpdateLocksCheck =
          {
            name,
            shells,
            args,
            standIn,
            prepare,
            expect,
          }:
          let
            # How each signal reaches the app once the stand-in blocks.
            signals = {
              # Ctrl-C to the app's process group.
              interrupts = "kill -INT -- -$app";
              # TERM to the app alone.
              terminates = "kill -TERM $app";
              # SIGKILL to the app's process group.
              killed = "kill -KILL -- -$app";
              # Ctrl-C typed on the app's terminal.
              pty = "printf '\\003' >&7";
            };
            signalled = signals ? ${standIn};
            app = flazel.lib.mkUpdateLocksApp {
              inherit pkgs shells;
              probes = [
                [ "//..." ]
                [
                  "-c"
                  "opt"
                  "//:via_bin"
                ]
              ];
            };
            # The probe needs the network; this stands in for it and records
            # the arguments it receives. A check compares the manifest with
            # the committed one.
            lockArchives = pkgs.writeShellScriptBin "flazel-lock-archives" (
              if standIn == "fails" then
                "exit 1"
              else
                ''
                  printf '%s\n' "$*" >> "$RECORD"
                  if [ "$1" != --check ]; then
                    echo '[]' > flazel-archives.json
                    exit
                  fi
                  ps -o pgid= $$ > "$TMPDIR/stand-in.pgid"
                  ${pkgs.lib.optionalString (standIn == "interrupts") ''
                    # Like Bazel's client, the tool exits on a signal without
                    # dying of it.
                    trap 'exit 130' INT
                    trap 'exit 143' TERM
                  ''}
                  ${pkgs.lib.optionalString signalled ''
                    echo "flazel-lock-archives: observing" >&2
                    echo > "$INTERRUPT"
                    read -r _ < "$INTERRUPT.never"
                  ''}
                  cmp "$3" "$PRISTINE/$3"
                ''
            );
          in
          pkgs.stdenv.mkDerivation {
            inherit name;
            src = ./.;
            nativeBuildInputs = [
              nixShim
              variants.default.bazel
              pkgs.jq
              pkgs.procps
              pkgs.util-linux
              lockArchives
            ];
            buildPhase = ''
              export HOME=$TMPDIR RECORD=$TMPDIR/lock-archives-args PRISTINE=$TMPDIR/pristine
              # A refresh visits the registry; a check must not need one.
              ${pkgs.lib.optionalString (args == "") ''
                echo "common --registry=file://${localRegistry}" > $HOME/.bazelrc
              ''}
              cp -r . $PRISTINE
              ${prepare}
              # The default shell's setup, which is no change the app makes.
              nix develop --command true
              cp -r . $TMPDIR/prepared
              failed=0
              status=0
              ${pkgs.lib.optionalString signalled ''
                # KILL to the app if it has not ended 10 seconds after the signal.
                export INTERRUPT=$TMPDIR/interrupt
                mkfifo $INTERRUPT $INTERRUPT.never ${pkgs.lib.optionalString (standIn == "pty") "$TMPDIR/keys"}
                (
                  ${pkgs.lib.optionalString (standIn == "pty") "exec 7>$TMPDIR/keys"}
                  # Read-write, since opening a FIFO to read waits for a writer.
                  read -r -t 120 _ <> $INTERRUPT || echo > $TMPDIR/not-ready
                  app=$(cat $TMPDIR/app.pgid)
                  ${signals.${standIn}}
                  for _ in 1 2 3 4 5 6 7 8 9 10; do
                    kill -0 $app 2>/dev/null || exit 0
                    sleep 1
                  done
                  kill -KILL $app
                ) &
              ''}
              ${
                if standIn == "pty" then
                  ''
                    # The app as the foreground job of a terminal that stops a
                    # process writing to it from another process group.
                    script -qefc "echo \$\$ > $TMPDIR/app.pgid; stty tostop; exec ${app.program} ${args}" /dev/null \
                      < $TMPDIR/keys > $TMPDIR/stderr 2>&1 || status=$?
                  ''
                else
                  ''
                    # A process group of its own, as a terminal's foreground job has.
                    setsid -w sh -c 'echo $$ > $TMPDIR/app.pgid; exec "$@"' sh ${app.program} ${args} \
                      2>$TMPDIR/stderr || status=$?
                  ''
              }
              cat $TMPDIR/stderr >&2
              echo "update-locks ${args} exited $status"
              if [ -e $TMPDIR/not-ready ]; then
                echo "FAIL: the stand-in did not block" >&2
                failed=1
              fi
              # The app stops the Bazel server it started, also on a signal.
              for _ in 1 2 3 4 5 6 7 8 9 10; do
                pgrep -f A-server.jar >/dev/null || break
                sleep 1
              done
              if pgrep -af A-server.jar >&2; then
                echo "FAIL: a Bazel server is left running" >&2
                failed=1
              fi
              bazel shutdown

              expect_status() {
                case "$1:$status" in
                fail:[1-9]* | "$1:$1") ;;
                *)
                  echo "FAIL: expected exit $1" >&2
                  failed=1
                  ;;
                esac
              }
              # The flazel-lock-archives runs, one per line.
              expect_runs() {
                got=$(cat "$RECORD" 2>/dev/null || true)
                want=$(printf '%s\n' "$@")
                echo "flazel-lock-archives runs:"
                echo "$got"
                [ "$got" = "$want" ] || {
                  echo "FAIL: expected runs:" >&2
                  echo "$want" >&2
                  failed=1
                }
              }
              # What the check reports, in order.
              expect_reported() {
                got=$(tr -d '\r' < $TMPDIR/stderr | sed -n 's/^update-locks --check: //p')
                want=$(printf '%s\n' "$@")
                echo "reported:"
                echo "$got"
                [ "$got" = "$want" ] || {
                  echo "FAIL: expected reported:" >&2
                  echo "$want" >&2
                  failed=1
                }
              }
              expect_stderr() {
                tr -d '\r' < $TMPDIR/stderr | grep -Fx "$1" >/dev/null || {
                  echo "FAIL: expected on stderr: $1" >&2
                  failed=1
                }
              }
              # Every process of the stand-in's process group has ended.
              expect_nothing_left() {
                pg=$(tr -d ' ' < $TMPDIR/stand-in.pgid)
                for _ in 1 2 3 4 5 6 7 8 9 10; do
                  pgrep -g "$pg" >/dev/null || break
                  sleep 1
                done
                if pgrep -g "$pg" >&2; then
                  echo "FAIL: a command is left running" >&2
                  pkill -KILL -g "$pg"
                  failed=1
                fi
              }
              expect_unchanged() {
                diff -r -x 'bazel-*' $TMPDIR/prepared . || {
                  echo "FAIL: the project changed" >&2
                  failed=1
                }
              }

              # The app refreshes the default lock on purpose; what no step may do is
              # leave it in another Bazel version's format.
              want=$(jq .lockFileVersion $TMPDIR/prepared/MODULE.bazel.lock)
              got=$(jq .lockFileVersion MODULE.bazel.lock)
              echo "MODULE.bazel.lock: format $got (committed: $want)"
              [ "$got" = "$want" ] || failed=1
              ${expect}
              [ "$failed" = 0 ]
            '';
            installPhase = "echo ok > $out";
          };

        probeArgs = "-- //... --and -c opt //:via_bin";
        checkRun = "--check --output flazel-archives.json ${probeArgs}";
        quoted = pkgs.lib.concatMapStringsSep " " (s: ''"${s}"'');
      in
      {
        checks =
          pkgs.lib.mapAttrs' (
            _: variant: pkgs.lib.nameValuePair "nix_tool${variant.suffix}" (mkToolCheck variant)
          ) variants
          // {
            update-locks = mkUpdateLocksCheck {
              name = "flazel-update-locks";
              shells = lockShells;
              args = "";
              standIn = "records";
              prepare = "";
              expect = ''
                expect_status 0
                for shell in ${toString lockShells}; do
                  want=$(jq .lockFileVersion $TMPDIR/prepared/locks/$shell.lock)
                  got=$(jq .lockFileVersion locks/$shell.lock)
                  echo "locks/$shell.lock: format $got (committed: $want)"
                  [ "$got" = "$want" ] || failed=1
                done
                expect_runs ${quoted (map (_: probeArgs) ([ "default" ] ++ lockShells))}
              '';
            };
            update-locks-failing = mkUpdateLocksCheck {
              name = "flazel-update-locks-failing";
              shells = lockShells;
              args = "";
              standIn = "fails";
              prepare = "";
              expect = "expect_status fail";
            };
            # Without Bazel-version shells there is nothing to put in locks/.
            update-locks-no-variants = mkUpdateLocksCheck {
              name = "flazel-update-locks-no-variants";
              shells = [ ];
              args = "";
              standIn = "records";
              prepare = "rm -r locks";
              expect = ''
                expect_status 0
                expect_runs ${quoted [ probeArgs ]}
                [ ! -e locks ] || {
                  echo "FAIL: locks/ created" >&2
                  failed=1
                }
              '';
            };
            update-locks-check = mkUpdateLocksCheck {
              name = "flazel-update-locks-check";
              shells = [ ];
              args = "--check";
              standIn = "records";
              prepare = "rm -r locks";
              expect = ''
                expect_status 0
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
              '';
            };
            # A lock missing a registry file's checksum, as after a new
            # bazel_dep, fails, and no manifest is derived from it.
            update-locks-check-stale-lock = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-stale-lock";
              shells = [ ];
              args = "--check";
              standIn = "records";
              prepare = ''
                rm -r locks
                jq 'del(.registryFileHashes["https://bcr.bazel.build/modules/bazel_skylib/1.9.0/MODULE.bazel"])' \
                  MODULE.bazel.lock > $TMPDIR/stale.lock
                mv $TMPDIR/stale.lock MODULE.bazel.lock
              '';
              expect = ''
                expect_status 1
                expect_reported ${quoted [ "MODULE.bazel.lock failed the check" ]}
                expect_unchanged
                expect_runs
              '';
            };
            # A manifest missing a download the build makes.
            update-locks-check-stale-manifest = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-stale-manifest";
              shells = [ ];
              args = "--check";
              standIn = "records";
              prepare = ''
                rm -r locks
                jq '.[1:]' flazel-archives.json > $TMPDIR/stale.json
                mv $TMPDIR/stale.json flazel-archives.json
              '';
              expect = ''
                expect_status 1
                expect_reported ${quoted [ "flazel-archives.json failed the check" ]}
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
              '';
            };
            update-locks-check-missing-manifest = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-missing-manifest";
              shells = [ ];
              args = "--check";
              standIn = "records";
              prepare = "rm -r locks flazel-archives.json";
              expect = ''
                expect_status 1
                expect_reported ${quoted [ "flazel-archives.json is missing" ]}
                expect_unchanged
                expect_runs
              '';
            };
            # Ctrl-C stops the check and its command, with nothing reported.
            update-locks-check-interrupted = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-interrupted";
              shells = [ ];
              args = "--check";
              standIn = "interrupts";
              prepare = "rm -r locks";
              expect = ''
                expect_status 130
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_nothing_left
              '';
            };
            # A TERM to the app alone stops it at once, though a command
            # blocks, and stops that command too.
            update-locks-check-terminated = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-terminated";
              shells = [ ];
              args = "--check";
              standIn = "terminates";
              prepare = "rm -r locks";
              expect = ''
                expect_status 143
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_nothing_left
              '';
            };
            # The check dies with the app, though the app cannot stop it.
            update-locks-check-killed = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-killed";
              shells = [ ];
              args = "--check";
              standIn = "killed";
              prepare = "rm -r locks";
              expect = ''
                expect_status 137
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_nothing_left
              '';
            };
            # Ctrl-C on a terminal with tostop set stops the check, and the
            # check's output reaches the terminal.
            update-locks-check-pty = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-pty";
              shells = [ ];
              args = "--check";
              standIn = "pty";
              prepare = "rm -r locks";
              expect = ''
                expect_status 130
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_nothing_left
                expect_stderr "flazel-lock-archives: observing"
              '';
            };
            update-locks-check-with-shells = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-with-shells";
              shells = lockShells;
              args = "--check";
              standIn = "records";
              prepare = "";
              expect = ''
                expect_status 2
                expect_stderr "update-locks: --check does not support Bazel-version shells yet"
                expect_unchanged
                expect_runs
              '';
            };
            update-locks-usage = mkUpdateLocksCheck {
              name = "flazel-update-locks-usage";
              shells = [ ];
              args = "--chek";
              standIn = "records";
              prepare = "rm -r locks";
              expect = ''
                expect_status 2
                expect_stderr "usage: update-locks [--check]"
                expect_unchanged
                expect_runs
              '';
            };
          };

        # Manual exploration: nix develop (or .#bazel8, ...), then `bazel build //...`.
        devShells = builtins.mapAttrs (_: mkShell [ ]) variants;

        # nix run .#update-locks regenerates locks/ (run in this directory).
        apps.update-locks = flazel.lib.mkUpdateLocksApp {
          inherit pkgs;
          shells = lockShells;
          probes = [ [ "//..." ] ];
        };
      }
    );
}
