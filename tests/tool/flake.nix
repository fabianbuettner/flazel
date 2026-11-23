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
            # In a check, what the app passes its shells stays out of the
            # environment of any Bazel a shellHook runs, and the shell
            # EXIT_IN_SETUP names stops the shell sourcing its setup, with
            # SETUP_STATUS or 1, at its EXIT_AT_SOURCING-th sourcing or its
            # first. The shell BAZEL_EXITS names gets a bazel() that exits 7,
            # and the one SECOND_SHUTDOWN_EXITS names one whose second
            # shutdown exits 0 after it. With BLOCK_AT=shutdown the default
            # shell's second shutdown waits for a TERM to its process group.
            shellHook =
              let
                shell = if variant.suffix == "" then "default" else pkgs.lib.removePrefix "-" variant.suffix;
              in
              ''
                if [ -n "''${BUILD_TMP-}" ]; then
                  leaked=$(env | sed -n 's/^\(FLAZEL_[A-Za-z0-9_]*\)=.*/\1/p' | xargs)
                  [ -z "$leaked" ] || echo "shellHook: $leaked" >> "$BUILD_TMP/env-leaked"
                fi
                if [ "''${EXIT_IN_SETUP-}" = ${shell} ]; then
                  echo >> "$BUILD_TMP/sourcings"
                  [ "$(wc -l < "$BUILD_TMP/sourcings")" -ne "''${EXIT_AT_SOURCING-1}" ] || exit "''${SETUP_STATUS-1}"
                fi
                if [ "''${BAZEL_EXITS-}" = ${shell} ]; then
                  bazel() {
                    exit 7
                  }
                fi
                if [ "''${BLOCK_AT-}" = shutdown ] && [ ${shell} = default ]; then
                  bazel() {
                    if [ "$1" = shutdown ]; then
                      if [ -e "$BUILD_TMP/shut-down" ]; then
                        ${pkgs.coreutils}/bin/env --default-signal=TERM ${pkgs.bash}/bin/sh -c \
                          'trap "exit 0" TERM; echo "bazel: shutting down" >&2; echo > "$INTERRUPT"; sleep 30 & wait'
                      fi
                      : >"$BUILD_TMP/shut-down"
                    fi
                    command bazel "$@"
                  }
                fi
                if [ "''${SECOND_SHUTDOWN_EXITS-}" = ${shell} ]; then
                  bazel() {
                    local rc=0
                    command bazel "$@" || rc=$?
                    if [ "$1" = shutdown ]; then
                      [ ! -e "$BUILD_TMP/shut-down" ] || exit 0
                      : >"$BUILD_TMP/shut-down"
                    fi
                    return "$rc"
                  }
                fi
              '';
          };

        lockShells = builtins.attrNames (removeAttrs variants [ "default" ]);

        # The sandbox cannot run Nix; print each shell's setup as its hook.
        nixShim = pkgs.writeShellScriptBin "nix" ''
          [ "$(readlink /proc/self/ns/mnt)" = "$TREE_MNTNS" ] || {
            echo "nix shim: called in a variant's namespace: $*" >&2
            exit 2
          }
          # The default shell's setup, made before the app runs.
          if [ "$*" = "develop --command true" ]; then
            unset EXIT_IN_SETUP BAZEL_EXITS SECOND_SHUTDOWN_EXITS
            export PATH="${variants.default.bazel}/bin:$PATH"
            . ${pkgs.writeText "hook-default" (mkShell refreshArchives variants.default).shellHook} >/dev/null
            exit
          fi
          [ "$1" = print-dev-env ] || {
            echo "nix shim: unsupported: $*" >&2
            exit 2
          }
          if [ "$BLOCK_AT" = evaluation ] && [ $# = 2 ]; then
            ps -o pgid= $$ > "$BUILD_TMP/stand-in.pgid"
            echo "nix shim: evaluating" >&2
            echo > "$INTERRUPT"
            read -r _ < "$INTERRUPT.never"
          fi
          case "$*" in
          print-dev-env)
            if [ -n "''${UNEVALUABLE_DEFAULT-}" ]; then
              echo "error: the default shell does not evaluate" >&2
              exit 1
            fi
            echo 'export PATH="${variants.default.bazel}/bin:$PATH"'
            echo ". ${pkgs.writeText "hook-default" (mkShell refreshArchives variants.default).shellHook} >/dev/null"
            ;;
          ${pkgs.lib.concatMapStrings (shell: ''
            "print-dev-env .#${shell}")
              echo 'export PATH="${variants.${shell}.bazel}/bin:$PATH"'
              echo ". ${
                pkgs.writeText "hook-${shell}" (mkShell refreshArchives variants.${shell}).shellHook
              } >/dev/null"
              ;;
          '') lockShells}
          # A version whose Bazel picks another output user root.
          "print-dev-env .#elsewhere")
            echo 'export PATH="${variants.${lastShell}.bazel}/bin:$PATH" TEST_TMPDIR="$BUILD_TMP/elsewhere"'
            echo ". ${
              pkgs.writeText "hook-${lastShell}" (mkShell refreshArchives variants.${lastShell}).shellHook
            } >/dev/null"
            ;;
          *)
            # As Nix fails an attribute a flake lacks.
            echo "error: flake does not provide $2" >&2
            exit 1
            ;;
          esac
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
            runner,
            args,
            standIn,
            prepare,
            expect,
          }:
          let
            # "<signal>" or "<signal>@<shell>": the stand-in blocks in the
            # default shell, or in that variant's namespace;
            # "<signal>@evaluation": the first variant's evaluation blocks;
            # "<signal>@shutdown": the default shell's last bazel shutdown.
            # "fails" fails every run, "fails@<shell>" that variant's only.
            parsed = builtins.match "([a-z]+)(@(.*))?" standIn;
            kind = builtins.elemAt parsed 0;
            blockAt = if builtins.elemAt parsed 2 == null then "default" else builtins.elemAt parsed 2;
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
            signalled = signals ? ${kind};
            # Generous, as a loaded machine stretches the app's run to minutes.
            hangSeconds = 1200;
            # Only an app killed cannot wait for what it started to end.
            appWaits = kind != "killed";
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
            # As the tool fails a probe build, with the status a prepare may
            # export as FAILS_WITH.
            failing = ''
              echo "the observing build failed; check its arguments" >&2
              exit "''${FAILS_WITH-1}"
            '';
            # The probe needs the network; this stands in for it and records
            # the arguments it receives. A check compares the manifest with
            # the committed one.
            lockArchives = pkgs.writeShellScriptBin "flazel-lock-archives" (
              if standIn == "fails" then
                failing
              else
                pkgs.lib.optionalString (kind == "fails") ''
                  case " $* " in
                  *" locks/${blockAt}.archives.json "*) ${failing} ;;
                  esac
                ''
                + ''
                  printf '%s\n' "$*" >> "$RECORD"
                  # Where it runs, the tree or a variant's namespace, and which
                  # lock is live: the committed one it equals when checking,
                  # its format when updating.
                  where=ns
                  [ "$(readlink /proc/self/ns/mnt)" != "$TREE_MNTNS" ] || where=tree
                  # What the app passes its shells stays out of Bazel's client env.
                  leaked=$(env | sed -n 's/^\(FLAZEL_[A-Za-z0-9_]*\)=.*/\1/p' | xargs)
                  [ -z "$leaked" ] || echo "$where: $leaked" >> "$BUILD_TMP/env-leaked"
                  if [ "$1" = --check ]; then
                    live=other
                    cmp -s MODULE.bazel.lock "$PRISTINE/MODULE.bazel.lock" && live=default
                    for shell in ${toString lockShells}; do
                      cmp -s MODULE.bazel.lock "$PRISTINE/locks/$shell.lock" && live=$shell
                    done
                    printf '%s %s\n' $where $live >> "$LIVE"
                  else
                    # Updating, the shell is the one whose manifest it writes.
                    live=default
                    case "$1 $2" in
                    "--output locks/"*.archives.json)
                      live=''${2#locks/}
                      live=''${live%.archives.json}
                      ;;
                    esac
                    printf '%s v%s\n' $where "$(jq .lockFileVersion MODULE.bazel.lock)" >> "$LIVE"
                  fi
                  # No Bazel server holds the descriptor a runner may open or
                  # the app's stderr, and a command gets no descriptor above 2
                  # but 255, the script bash reads.
                  for pid in $(pgrep -f A-server.jar); do
                    for fd in /proc/$pid/fd/*; do
                      case $(readlink $fd) in
                      "$BUILD_TMP/fd-marker" | "$BUILD_TMP/stderr") echo "$where $pid ''${fd##*/}" >> "$BUILD_TMP/leaked" ;;
                      esac
                    done
                  done
                  for fd in /proc/$$/fd/*; do
                    [ ! -L "$fd" ] || [ "''${fd##*/}" -le 2 ] || [ "''${fd##*/}" = 255 ] \
                      || echo "$where command ''${fd##*/}" >> "$BUILD_TMP/leaked"
                  done
                  if [ $where = ns ]; then
                    readlink /proc/self/ns/pid > "$BUILD_TMP/stand-in.pidns"
                    # The variant's output base and install directory are tmpfs
                    # mounts of their own.
                    if bazel info output_base install_base > "$BUILD_TMP/stand-in.bases"; then
                      while read -r key base; do
                        [ "$key" != install_base: ] || base=''${base%/*}
                        [ "$(${pkgs.util-linux}/bin/findmnt -n -o FSTYPE --mountpoint "$base")" = tmpfs ] \
                          || echo "$key $base" >> "$BUILD_TMP/not-tmpfs"
                      done < "$BUILD_TMP/stand-in.bases"
                    else
                      echo "bazel info failed" >> "$BUILD_TMP/not-tmpfs"
                    fi
                  else
                    ps -o pgid= $$ > "$BUILD_TMP/stand-in.pgid"
                  fi
                  ${pkgs.lib.optionalString (kind == "interrupts") ''
                    # Like Bazel's client, the tool exits on a signal without
                    # dying of it.
                    trap 'exit 130' INT
                    trap 'exit 143' TERM
                  ''}
                  ${pkgs.lib.optionalString signalled ''
                    if [ $live = ${blockAt} ]; then
                      if [ $where = ns ]; then
                        # A process of a session of its own, which no TERM
                        # reaches, whose memory makes the namespace's end slow.
                        mkfifo "$TMPDIR/hog"
                        setsid ${pkgs.bash}/bin/bash -c 'printf -v hog "%*s" 200000000 ""; echo > "$0"; read -r _ < "$1"' \
                          "$TMPDIR/hog" "$INTERRUPT.never" </dev/null >/dev/null 2>&1 &
                        read -r _ < "$TMPDIR/hog"
                      fi
                      echo "flazel-lock-archives: observing" >&2
                      echo > "$INTERRUPT"
                      read -r _ < "$INTERRUPT.never"
                    fi
                  ''}
                  if [ "$1" = --check ]; then
                    # flazel-lock-archives' status for a manifest that differs.
                    cmp "$3" "$PRISTINE/$3" || exit 3
                  elif [ "$1" = --output ]; then
                    echo '[]' > "$2"
                  else
                    echo '[]' > flazel-archives.json
                  fi
                  # The next variant cannot make its .nix-bazel-deps.
                  if [ -n "''${DEPS_DIR_FILE-}" ] && [ $where = tree ]; then
                    rm -r .nix-bazel-deps
                    touch .nix-bazel-deps
                  fi
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
              # A variant's namespace has a TMPDIR of its own.
              export BUILD_TMP=$TMPDIR LIVE=$TMPDIR/live TREE_MNTNS=$(readlink /proc/self/ns/mnt)
              # Where the stand-in, or the nix shim's evaluation, blocks.
              export BLOCK_AT=${blockAt}
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
              # Every process of the stand-in's process group, or of the variant
              # namespace it ran in.
              left() {
                if [ -e $TMPDIR/stand-in.pidns ]; then
                  for proc in /proc/[0-9]*; do
                    [ "$(readlink $proc/ns/pid 2>/dev/null)" != "$(cat $TMPDIR/stand-in.pidns)" ] \
                      || echo "''${proc#/proc/}"
                  done
                elif [ -e $TMPDIR/stand-in.pgid ]; then
                  pgrep -g "$(tr -d ' ' < $TMPDIR/stand-in.pgid)" || true
                fi
              }
              ${pkgs.lib.optionalString signalled ''
                # The stand-in's block sends the signal, the app's return ends
                # the watcher; KILL to an app still running after the bound.
                export INTERRUPT=$TMPDIR/interrupt
                mkfifo $INTERRUPT $INTERRUPT.never ${pkgs.lib.optionalString (kind == "pty") "$TMPDIR/keys"}
                # Read-write and opened before the app runs, so no event is lost.
                exec {events}<> $INTERRUPT
                (
                  ${pkgs.lib.optionalString (kind == "pty") "exec 7>$TMPDIR/keys"}
                  deadline=$((SECONDS + ${toString hangSeconds}))
                  sent=
                  while remaining=$((deadline - SECONDS)) && [ $remaining -gt 0 ] && read -r -t $remaining event <&$events; do
                    if [ "$event" = returned ]; then
                      [ -n "$sent" ] || echo > $TMPDIR/not-ready
                      exit 0
                    fi
                    if [ -z "$sent" ]; then
                      app=$(cat $TMPDIR/app.pgid)
                      ${signals.${kind}}
                      sent=1
                    fi
                  done
                  echo > $TMPDIR/hung
                  kill -KILL "$(cat $TMPDIR/app.pgid)"
                ) &
                watcher=$!
                exec {events}<&-
              ''}
              ${
                if kind == "pty" then
                  ''
                    # The app as the foreground job of a terminal that stops a
                    # process writing to it from another process group.
                    script -qefc "echo \$\$ > $TMPDIR/app.pgid; stty tostop; exec ${app.program} ${args}" /dev/null \
                      < $TMPDIR/keys > $TMPDIR/stderr 2>&1 || status=$?
                  ''
                else
                  ''
                    # A process group of its own, as a terminal's foreground job has.
                    setsid -w sh -c 'echo $$ > $TMPDIR/app.pgid; exec "$@"' sh ${runner} ${app.program} ${args} \
                      2>$TMPDIR/stderr || status=$?
                  ''
              }
              # What the app left running as it returned, before anything could end.
              servers_at_return=$(pgrep -af A-server.jar || true)
              left_at_return=$(left | xargs)
              ${pkgs.lib.optionalString signalled ''
                echo returned 1<> $INTERRUPT
                wait $watcher || true
              ''}
              cat $TMPDIR/stderr >&2
              echo "update-locks ${args} exited $status"
              # No shell reports a command the app stopped as terminated.
              if grep -w Terminated $TMPDIR/stderr >/dev/null; then
                echo "FAIL: a shell reported a command as terminated" >&2
                failed=1
              fi
              if [ -e $TMPDIR/not-ready ]; then
                echo "FAIL: the stand-in did not block" >&2
                failed=1
              fi
              if [ -e $TMPDIR/hung ]; then
                echo "FAIL: the app hung" >&2
                failed=1
              fi
              # The app stops the Bazel server it started, also on a signal, and
              # unless killed returns only once it has.
              ${
                if appWaits then
                  ''
                    servers_running=$servers_at_return
                  ''
                else
                  ''
                    for _ in 1 2 3 4 5 6 7 8 9 10; do
                      pgrep -f A-server.jar >/dev/null || break
                      sleep 1
                    done
                    servers_running=$(pgrep -af A-server.jar || true)
                  ''
              }
              if [ -n "$servers_running" ]; then
                printf '%s\n' "$servers_running" >&2
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
              expect_no_stderr() {
                if tr -d '\r' < $TMPDIR/stderr | grep -Fx "$1" >/dev/null; then
                  echo "FAIL: unexpected on stderr: $1" >&2
                  failed=1
                fi
              }
              expect_stderr_like() {
                tr -d '\r' < $TMPDIR/stderr | grep -Ex "$1" >/dev/null || {
                  echo "FAIL: expected on stderr a line like: $1" >&2
                  failed=1
                }
              }
              # Each file is as prepared or replaced whole, never cut short.
              expect_whole() {
                for file in "$@"; do
                  cmp -s "$TMPDIR/prepared/$file" "$file" || jq -e . "$file" >/dev/null || {
                    echo "FAIL: $file is neither untouched nor whole" >&2
                    failed=1
                  }
                done
              }
              expect_nothing_left() {
                ${
                  if appWaits then
                    ''
                      left_running=$left_at_return
                    ''
                  else
                    ''
                      for _ in 1 2 3 4 5 6 7 8 9 10; do
                        [ -n "$(left)" ] || break
                        sleep 1
                      done
                      left_running=$(left | xargs)
                    ''
                }
                if [ -n "$left_running" ]; then
                  echo "FAIL: a command is left running: $left_running" >&2
                  left | xargs -r kill -KILL
                  failed=1
                fi
              }
              # Where each flazel-lock-archives run was and which lock was live.
              expect_live() {
                got=$(cat "$LIVE" 2>/dev/null || true)
                want=$(printf '%s\n' "$@")
                echo "live locks:"
                echo "$got"
                [ "$got" = "$want" ] || {
                  echo "FAIL: expected live locks:" >&2
                  echo "$want" >&2
                  failed=1
                }
              }
              expect_unchanged() {
                diff -r -x 'bazel-*' $TMPDIR/prepared . || {
                  echo "FAIL: the project changed" >&2
                  failed=1
                }
              }

              # The app refreshes the default lock on purpose; what no step may do is
              # leave it in another Bazel version's format.
              if [ -e $TMPDIR/prepared/MODULE.bazel.lock ]; then
                want=$(jq .lockFileVersion $TMPDIR/prepared/MODULE.bazel.lock)
                got=$(jq .lockFileVersion MODULE.bazel.lock)
                echo "MODULE.bazel.lock: format $got (committed: $want)"
                [ "$got" = "$want" ] || failed=1
              fi
              # Only the default Bazel uses its output user root, Bazel's own
              # or the one a test sets, on disk; a variant's output base and
              # install directory are on tmpfs. Bazel names the project by its
              # path with symlinks resolved.
              for root in $HOME/.cache/bazel/_bazel_* $TMPDIR/our; do
                for marker in $root/*/DO_NOT_BUILD_HERE; do
                  if [ -e "$marker" ] && [ "$(cat "$marker")" != "$(pwd -P)" ]; then
                    echo "FAIL: output base of $(cat "$marker") left behind" >&2
                    failed=1
                  fi
                done
              done
              installs=$(ls -d $HOME/.cache/bazel/_bazel_*/install/* $TMPDIR/our/install/* 2>/dev/null | wc -l)
              echo "install bases on disk: $installs"
              [ "$installs" -le 1 ] || {
                echo "FAIL: a variant's Bazel was installed on disk" >&2
                failed=1
              }
              if [ -e $TMPDIR/not-tmpfs ]; then
                echo "FAIL: a variant's Bazel used a base not on its own tmpfs: $(xargs < $TMPDIR/not-tmpfs)" >&2
                failed=1
              fi
              if [ -e $TMPDIR/leaked ]; then
                echo "FAIL: a Bazel server or a command holds a descriptor of the app's: $(xargs < $TMPDIR/leaked)" >&2
                failed=1
              fi
              if [ -e $TMPDIR/env-leaked ]; then
                echo "FAIL: FLAZEL_* variables reached a command: $(cat $TMPDIR/env-leaked)" >&2
                failed=1
              fi
              if [ -n "$(find . -name '*.tmp')" ]; then
                echo "FAIL: temporary files left behind" >&2
                failed=1
              fi
              ${expect}
              [ "$failed" = 0 ]
            '';
            installPhase = "echo ok > $out";
          };

        probeArgs = "-- //... --and -c opt //:via_bin";
        checkRunOf = manifest: "--check --output ${manifest} ${probeArgs}";
        checkRun = checkRunOf "flazel-archives.json";
        variantRuns = map (shell: checkRunOf "locks/${shell}.archives.json");
        variantLive = map (shell: "ns ${shell}");
        firstShell = builtins.head lockShells;
        lastShell = pkgs.lib.last lockShells;
        # A lock missing a registry file's checksum, as after a new bazel_dep.
        staleLock = lock: ''
          jq 'del(.registryFileHashes["https://bcr.bazel.build/modules/bazel_skylib/1.9.0/MODULE.bazel"])' \
            ${lock} > $TMPDIR/stale.lock
          mv $TMPDIR/stale.lock ${lock}
        '';
        # A lock missing every module extension, as after a new use_extension.
        staleExtensions = lock: ''
          jq 'del(.moduleExtensions)' ${lock} > $TMPDIR/stale.lock
          mv $TMPDIR/stale.lock ${lock}
        '';
        # A manifest missing a download the build makes.
        staleManifest = manifest: ''
          jq '.[1:]' ${manifest} > $TMPDIR/stale.json
          mv $TMPDIR/stale.json ${manifest}
        '';
        # A variant check that passes, with what is expected of it.
        passingVariantCheck =
          name: prepare:
          mkUpdateLocksCheck {
            inherit name prepare;
            shells = lockShells;
            runner = "";
            args = "--check";
            standIn = "records";
            expect = ''
              expect_status 0
              expect_reported
              expect_unchanged
              expect_runs ${quoted ([ checkRun ] ++ variantRuns lockShells)}
              expect_live ${quoted ([ "tree default" ] ++ variantLive lockShells)}
            '';
          };
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
              runner = "";
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
                expect_runs ${
                  quoted (
                    [ probeArgs ] ++ map (shell: "--output locks/${shell}.archives.json ${probeArgs}") lockShells
                  )
                }
                expect_live ${
                  quoted (
                    map (run: "${run.where} v$(jq .lockFileVersion $TMPDIR/prepared/${run.lock})") (
                      [
                        {
                          where = "tree";
                          lock = "MODULE.bazel.lock";
                        }
                      ]
                      ++ map (shell: {
                        where = "ns";
                        lock = "locks/${shell}.lock";
                      }) lockShells
                    )
                  )
                }
              '';
            };
            update-locks-failing = mkUpdateLocksCheck {
              name = "flazel-update-locks-failing";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "fails";
              prepare = "";
              expect = ''
                expect_status 8
                expect_stderr "the observing build failed; check its arguments"
                expect_stderr "update-locks: cannot update MODULE.bazel.lock and flazel-archives.json (the error above)"
              '';
            };
            # A command in a dev shell or a variant's namespace that fails with
            # a status of the app's own, Bazel's RUN_FAILURE, stops the update
            # with 8.
            update-locks-failing-run-failure = mkUpdateLocksCheck {
              name = "flazel-update-locks-failing-run-failure";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "fails";
              prepare = "export FAILS_WITH=6";
              expect = ''
                expect_status 8
                expect_runs
                expect_stderr "the observing build failed; check its arguments"
                expect_stderr "update-locks: cannot update MODULE.bazel.lock and flazel-archives.json (the error above)"
              '';
            };
            update-locks-variants-failing-run-failure = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-failing-run-failure";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "fails@${firstShell}";
              prepare = "export FAILS_WITH=6";
              expect = ''
                expect_status 8
                expect_runs ${quoted [ probeArgs ]}
                expect_whole MODULE.bazel.lock flazel-archives.json locks/*
                expect_stderr "the observing build failed; check its arguments"
                expect_stderr "update-locks: cannot update locks/${firstShell}.lock and locks/${firstShell}.archives.json (the error above)"
              '';
            };
            # A MODULE.bazel Bazel cannot parse stops the update with 8, not
            # Bazel's own status, and Bazel's error is shown.
            update-locks-syntax-error = mkUpdateLocksCheck {
              name = "flazel-update-locks-syntax-error";
              shells = [ ];
              runner = "";
              args = "";
              standIn = "records";
              prepare = ''
                rm -r locks
                echo "bazel_dep(name = " >> MODULE.bazel
              '';
              expect = ''
                expect_status 8
                expect_unchanged
                expect_runs
                expect_stderr_like "ERROR: .*/MODULE.bazel:[0-9]+:[0-9]+: syntax error at .*"
                expect_stderr "update-locks: cannot update MODULE.bazel.lock and flazel-archives.json (the error above)"
              '';
            };
            # Without Bazel-version shells there is nothing to put in locks/.
            update-locks-no-variants = mkUpdateLocksCheck {
              name = "flazel-update-locks-no-variants";
              shells = [ ];
              runner = "";
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
              runner = "";
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
              runner = "";
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
              runner = "";
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
            # A probe build that fails is no stale manifest: the check could
            # not run, and the tool's message names why.
            update-locks-check-probe-fails = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-probe-fails";
              shells = [ ];
              runner = "";
              args = "--check";
              standIn = "fails";
              prepare = "rm -r locks";
              expect = ''
                expect_status 8
                expect_reported ${
                  quoted [ "cannot check flazel-archives.json (flazel-lock-archives' error above)" ]
                }
                expect_unchanged
                expect_stderr "the observing build failed; check its arguments"
              '';
            };
            # Nor is a MODULE.bazel Bazel cannot parse a stale lock; Bazel's
            # error is shown.
            update-locks-check-syntax-error = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-syntax-error";
              shells = [ ];
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                rm -r locks
                echo "bazel_dep(name = " >> MODULE.bazel
              '';
              expect = ''
                expect_status 8
                expect_reported ${quoted [ "cannot check MODULE.bazel.lock (the error above)" ]}
                expect_unchanged
                expect_runs
                expect_stderr_like "ERROR: .*/MODULE.bazel:[0-9]+:[0-9]+: syntax error at .*"
              '';
            };
            # Nor is a registry Bazel cannot reach: an empty repository cache
            # sends it there, out of the sandbox.
            update-locks-check-no-registry = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-no-registry";
              shells = [ ];
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                rm -r locks
                echo "common --repository_cache=$TMPDIR/empty-cache" >> .bazelrc
              '';
              expect = ''
                expect_status 8
                expect_reported ${quoted [ "cannot check MODULE.bazel.lock (the error above)" ]}
                expect_unchanged
                expect_runs
                expect_stderr_like "ERROR: .*bcr.bazel.build.*"
              '';
            };
            update-locks-check-missing-manifest = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-missing-manifest";
              shells = [ ];
              runner = "";
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
            # A default dev shell that fails to evaluate stops either mode with
            # a status of its own.
            update-locks-check-unevaluable = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-unevaluable";
              shells = [ ];
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                rm -r locks
                export UNEVALUABLE_DEFAULT=1
              '';
              expect = ''
                expect_status 7
                expect_reported
                expect_unchanged
                expect_runs
                expect_stderr "update-locks: cannot evaluate the dev shell default (nix's error above)"
              '';
            };
            update-locks-unevaluable = mkUpdateLocksCheck {
              name = "flazel-update-locks-unevaluable";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "records";
              prepare = "export UNEVALUABLE_DEFAULT=1";
              expect = ''
                expect_status 7
                expect_unchanged
                expect_runs
                expect_stderr "update-locks: cannot evaluate the dev shell default (nix's error above)"
              '';
            };
            # Either mode stops with 8 if it cannot make its scratch directory.
            update-locks-check-no-tmpdir = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-no-tmpdir";
              shells = lockShells;
              runner = "env TMPDIR=/nonexistent";
              args = "--check";
              standIn = "records";
              prepare = "";
              expect = ''
                expect_status 8
                expect_reported
                expect_unchanged
                expect_runs
                expect_stderr "update-locks: cannot make a scratch directory"
              '';
            };
            update-locks-no-tmpdir = mkUpdateLocksCheck {
              name = "flazel-update-locks-no-tmpdir";
              shells = lockShells;
              runner = "env TMPDIR=/nonexistent";
              args = "";
              standIn = "records";
              prepare = "";
              expect = ''
                expect_status 8
                expect_unchanged
                expect_runs
                expect_stderr "update-locks: cannot make a scratch directory"
              '';
            };
            # Ctrl-C stops the check and its command, with nothing reported.
            update-locks-check-interrupted = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-interrupted";
              shells = [ ];
              runner = "";
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
              runner = "";
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
              runner = "";
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
            # A TERM during the last bazel shutdown does not stop it.
            update-locks-check-terminated-shutting-down = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-terminated-shutting-down";
              shells = [ ];
              runner = "";
              args = "--check";
              standIn = "terminates@shutdown";
              prepare = "rm -r locks";
              expect = ''
                expect_status 143
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_nothing_left
                expect_stderr "bazel: shutting down"
              '';
            };
            # Ctrl-C on a terminal with tostop set stops the check, and the
            # check's output reaches the terminal.
            update-locks-check-pty = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-pty";
              shells = [ ];
              runner = "";
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
            # Each Bazel version is checked in its namespace, against its own
            # lock and manifest.
            update-locks-check-variants = passingVariantCheck "flazel-update-locks-check-variants" "";
            # A stale lock fails, and its manifest is not derived from it.
            update-locks-check-variants-stale-lock = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-stale-lock";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = staleLock "MODULE.bazel.lock" + staleLock "locks/${lastShell}.lock";
              expect = ''
                expect_status 1
                expect_reported ${
                  quoted [
                    "MODULE.bazel.lock failed the check"
                    "locks/${lastShell}.lock failed the check"
                  ]
                }
                expect_unchanged
                expect_runs ${quoted (variantRuns (pkgs.lib.init lockShells))}
                expect_live ${quoted (variantLive (pkgs.lib.init lockShells))}
              '';
            };
            # Bazel names only the extension a lock lacks, with no hint to
            # update it.
            update-locks-check-variants-stale-extensions = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-stale-extensions";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = staleExtensions "MODULE.bazel.lock" + staleExtensions "locks/${firstShell}.lock";
              expect = ''
                expect_status 1
                expect_reported ${
                  quoted [
                    "MODULE.bazel.lock failed the check"
                    "locks/${firstShell}.lock failed the check"
                  ]
                }
                expect_unchanged
                expect_runs ${quoted (variantRuns (pkgs.lib.tail lockShells))}
                expect_live ${quoted (variantLive (pkgs.lib.tail lockShells))}
                expect_stderr_like "ERROR: .*does not exist in the lockfile.*"
              '';
            };
            update-locks-check-variants-stale-manifest = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-stale-manifest";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = staleManifest "flazel-archives.json" + staleManifest "locks/${firstShell}.archives.json";
              expect = ''
                expect_status 1
                expect_reported ${
                  quoted [
                    "flazel-archives.json failed the check"
                    "locks/${firstShell}.archives.json failed the check"
                  ]
                }
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns lockShells)}
              '';
            };
            # A missing lock is reported, and the other versions are checked.
            update-locks-check-variants-missing-lock = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-missing-lock";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = "rm locks/${firstShell}.lock";
              expect = ''
                expect_status 1
                expect_reported ${quoted [ "locks/${firstShell}.lock is missing" ]}
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns (pkgs.lib.tail lockShells))}
              '';
            };
            # Without MODULE.bazel.lock no version is checked, since its lock
            # is mounted there, and nothing is created in its place.
            update-locks-check-variants-missing-default-lock = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-missing-default-lock";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = "rm MODULE.bazel.lock";
              expect = ''
                expect_status 1
                expect_reported ${
                  quoted (
                    [ "MODULE.bazel.lock is missing" ]
                    ++ map (shell: "locks/${shell}.lock is not checked, since MODULE.bazel.lock is missing") lockShells
                  )
                }
                expect_unchanged
                expect_runs
              '';
            };
            # A dev shell that fails to evaluate stops the check with a status
            # of its own, not the 1 of a stale file, after it reports what
            # failed before.
            update-locks-check-variants-broken-shell = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-broken-shell";
              shells = lockShells ++ [ "broken" ];
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = staleManifest "flazel-archives.json" + ''
                cp locks/${lastShell}.lock locks/broken.lock
                cp locks/${lastShell}.archives.json locks/broken.archives.json
              '';
              expect = ''
                expect_status 7
                expect_reported ${quoted [ "flazel-archives.json failed the check" ]}
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns lockShells)}
                expect_stderr "update-locks: cannot evaluate the dev shell broken (nix's error above)"
              '';
            };
            # A local_path_override to a sibling of the project resolves for
            # every version.
            update-locks-check-variants-sibling-override = passingVariantCheck "flazel-update-locks-check-variants-sibling-override" ''
              mkdir ../dep
              echo 'module(name = "dep")' > ../dep/MODULE.bazel
              touch ../dep/BUILD.bazel
              printf '%s\n' 'bazel_dep(name = "dep")' \
                'local_path_override(module_name = "dep", path = "../dep")' >> MODULE.bazel
            '';
            # A '#' in the project's path is no flake reference's fragment.
            update-locks-check-variants-hash-path = passingVariantCheck "flazel-update-locks-check-variants-hash-path" ''
              mkdir '../a#b'
              cp -r . '../a#b/tool'
              cd '../a#b/tool'
            '';
            # Under a workspace's own output user root, a variant's output base
            # and install directory are on tmpfs, so only the default Bazel
            # uses it on disk.
            update-locks-check-variants-output-user-root = passingVariantCheck "flazel-update-locks-check-variants-output-user-root" ''
              echo "startup --output_user_root=$TMPDIR/our" >> .bazelrc
            '';
            # An output base a .bazelrc sets, outside the project's parent or
            # in it, is on tmpfs in a variant's namespace, and so is the
            # variant's install base under the default output user root.
            update-locks-check-variants-output-base = passingVariantCheck "flazel-update-locks-check-variants-output-base" ''
              echo "startup --output_base=$TMPDIR/elsewhere/obase" >> .bazelrc
            '';
            update-locks-check-variants-output-base-sibling = passingVariantCheck "flazel-update-locks-check-variants-output-base-sibling" ''
              echo "startup --output_base=''${PWD%/*}/obase" >> .bazelrc
            '';
            # A variant whose Bazel would use another output base or install
            # base than the tmpfs holds is refused, named.
            update-locks-check-variants-foreign-output-base = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-foreign-output-base";
              shells = lockShells ++ [ "elsewhere" ];
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                cp locks/${lastShell}.lock locks/elsewhere.lock
                cp locks/${lastShell}.archives.json locks/elsewhere.archives.json
              '';
              expect = ''
                expect_status 5
                expect_reported
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns lockShells)}
                expect_stderr_like "update-locks: the output base of elsewhere, $TMPDIR/elsewhere/.*, is not .* on tmpfs"
              '';
            };
            update-locks-check-variants-foreign-install-base = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-foreign-install-base";
              shells = lockShells ++ [ "elsewhere" ];
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                echo "startup --output_base=$TMPDIR/obase" >> .bazelrc
                cp locks/${lastShell}.lock locks/elsewhere.lock
                cp locks/${lastShell}.archives.json locks/elsewhere.archives.json
              '';
              expect = ''
                expect_status 5
                expect_reported
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns lockShells)}
                expect_stderr_like "update-locks: the install base of elsewhere, $TMPDIR/elsewhere/.*, is not under .* on tmpfs"
              '';
            };
            # A variant whose Bazel cannot say where its output base is cannot
            # be checked.
            update-locks-check-variants-bazel-info-fails = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-bazel-info-fails";
              shells = lockShells ++ [ "elsewhere" ];
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                touch $TMPDIR/elsewhere
                cp locks/${lastShell}.lock locks/elsewhere.lock
                cp locks/${lastShell}.archives.json locks/elsewhere.archives.json
              '';
              expect = ''
                expect_status 8
                expect_reported ${quoted [ "cannot check locks/elsewhere.lock (the error above)" ]}
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns lockShells)}
                expect_stderr "update-locks: cannot ask the Bazel of elsewhere for its output base"
              '';
            };
            # Nor can any variant if the default Bazel cannot say where its
            # output base is; only bazel info reads info lines.
            update-locks-check-variants-default-bazel-info-fails = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-default-bazel-info-fails";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                echo "info --flazel_no_such_option" >> .bazelrc
              '';
              expect = ''
                expect_status 8
                expect_reported ${quoted [ "cannot check locks/${firstShell}.lock (the error above)" ]}
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: cannot ask the default Bazel for its output base"
              '';
            };
            update-locks-variants-default-bazel-info-fails = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-default-bazel-info-fails";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "records";
              prepare = ''
                echo "info --flazel_no_such_option" >> .bazelrc
              '';
              expect = ''
                expect_status 8
                expect_runs ${quoted [ probeArgs ]}
                expect_stderr "update-locks: cannot ask the default Bazel for its output base"
                expect_stderr "update-locks: cannot update locks/${firstShell}.lock and locks/${firstShell}.archives.json (the error above)"
              '';
            };
            # No tmpfs may hide the project.
            update-locks-check-variants-install-base-holds-project = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-install-base-holds-project";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                echo "startup --install_base=''${PWD%/*}/install" >> .bazelrc
              '';
              expect = ''
                expect_status 5
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: the project is inside Bazel's ''${PWD%/*}"
              '';
            };
            # Nor may one reached through a symlink, whether Bazel's base or
            # the project's path holds it.
            update-locks-check-variants-install-base-symlink = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-install-base-symlink";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                ln -s . ../alias
                echo "startup --install_base=''${PWD%/*}/alias/install" >> .bazelrc
              '';
              expect = ''
                expect_status 5
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: the project is inside Bazel's ''${PWD%/*}/alias"
              '';
            };
            update-locks-check-variants-project-symlink = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-project-symlink";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = ''
                mkdir ../real
                cp -r . ../real/tool
                echo "startup --install_base=''${PWD%/*}/real/install" >> ../real/tool/.bazelrc
                ln -s real ../alias
                cd ../alias/tool
              '';
              expect = ''
                expect_status 5
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: the project is inside Bazel's ''${PWD%/*/*}/real"
              '';
            };
            # A dev shell setup that exits stops either mode with 7, not its
            # own status, after the check reports what failed before.
            update-locks-check-setup-exits = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-setup-exits";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = "export EXIT_IN_SETUP=default";
              expect = ''
                expect_status 7
                expect_reported
                expect_unchanged
                expect_runs
                expect_stderr "update-locks: the dev shell default setup exited 1 before its end"
              '';
            };
            update-locks-setup-exits = mkUpdateLocksCheck {
              name = "flazel-update-locks-setup-exits";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "records";
              prepare = "export EXIT_IN_SETUP=default";
              expect = ''
                expect_status 7
                expect_unchanged
                expect_runs
                expect_stderr "update-locks: the dev shell default setup exited 1 before its end"
              '';
            };
            update-locks-check-variants-setup-exits = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-setup-exits";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = staleManifest "flazel-archives.json" + "export EXIT_IN_SETUP=${firstShell}";
              expect = ''
                expect_status 7
                expect_reported ${quoted [ "flazel-archives.json failed the check" ]}
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: the dev shell ${firstShell} setup exited 1 before its end"
              '';
            };
            # A setup that exits 0 is no check that passed, even after
            # another shell's setup ran to its end.
            update-locks-check-variants-setup-exits-0 = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-setup-exits-0";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare =
                staleManifest "flazel-archives.json" + "export EXIT_IN_SETUP=${firstShell} SETUP_STATUS=0";
              expect = ''
                expect_status 7
                expect_reported ${quoted [ "flazel-archives.json failed the check" ]}
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: the dev shell ${firstShell} setup exited 0 before its end"
              '';
            };
            update-locks-variants-setup-exits = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-setup-exits";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "records";
              prepare = "export EXIT_IN_SETUP=${firstShell}";
              expect = ''
                expect_status 7
                expect_runs ${quoted [ probeArgs ]}
                expect_whole MODULE.bazel.lock flazel-archives.json locks/*
                expect_stderr "update-locks: the dev shell ${firstShell} setup exited 1 before its end"
              '';
            };
            # So does the default setup exiting when sourced again to ask
            # the default Bazel for its bases, before any variant.
            update-locks-check-variants-default-setup-exits-later = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-default-setup-exits-later";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = "export EXIT_IN_SETUP=default EXIT_AT_SOURCING=2";
              expect = ''
                expect_status 7
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: the dev shell default setup exited 1 before its end"
                expect_no_stderr "update-locks: cannot ask the default Bazel for its output base"
              '';
            };
            update-locks-variants-default-setup-exits-later = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-default-setup-exits-later";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "records";
              prepare = "export EXIT_IN_SETUP=default EXIT_AT_SOURCING=2";
              expect = ''
                expect_status 7
                expect_runs ${quoted [ probeArgs ]}
                expect_whole MODULE.bazel.lock flazel-archives.json locks/*
                expect_stderr "update-locks: the dev shell default setup exited 1 before its end"
                expect_no_stderr "update-locks: cannot ask the default Bazel for its output base"
              '';
            };
            # A function from a setup that exits, a bazel() wrapper say, stops
            # either mode with 8, not its own status.
            update-locks-check-bazel-exits = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-bazel-exits";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = "export BAZEL_EXITS=default";
              expect = ''
                expect_status 8
                expect_reported ${quoted [ "cannot check MODULE.bazel.lock (the error above)" ]}
                expect_unchanged
                expect_runs
                expect_stderr "update-locks: a command in the dev shell default exited 7, outside the statuses of the app"
              '';
            };
            # A function from a setup that exits 0 in the body's EXIT trap
            # cannot pass a failed check.
            update-locks-check-shutdown-exits = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-shutdown-exits";
              shells = [ ];
              runner = "";
              args = "--check";
              standIn = "records";
              prepare =
                "rm -r locks; " + staleManifest "flazel-archives.json" + "export SECOND_SHUTDOWN_EXITS=default";
              expect = ''
                expect_status 8
                expect_reported ${quoted [ "cannot check MODULE.bazel.lock (the error above)" ]}
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: a command in the dev shell default exited 0, outside the statuses of the app"
              '';
            };
            update-locks-check-variants-bazel-exits = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-bazel-exits";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = "export BAZEL_EXITS=${firstShell}";
              expect = ''
                expect_status 8
                expect_reported ${quoted [ "cannot check locks/${firstShell}.lock (the error above)" ]}
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: a command in the dev shell ${firstShell} exited 7, outside the statuses of the app"
              '';
            };
            update-locks-variants-bazel-exits = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-bazel-exits";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "records";
              prepare = "export BAZEL_EXITS=${firstShell}";
              expect = ''
                expect_status 8
                expect_runs ${quoted [ probeArgs ]}
                expect_whole MODULE.bazel.lock flazel-archives.json locks/*
                expect_stderr "update-locks: a command in the dev shell ${firstShell} exited 7, outside the statuses of the app"
                expect_stderr "update-locks: cannot update locks/${firstShell}.lock and locks/${firstShell}.archives.json (the error above)"
              '';
            };
            # A .nix-bazel-deps a variant cannot make stops either mode with 8.
            update-locks-check-variants-deps-dir-file = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-deps-dir-file";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "records";
              prepare = "export DEPS_DIR_FILE=1";
              expect = ''
                expect_status 8
                expect_reported ${quoted [ "cannot check locks/${firstShell}.lock (the error above)" ]}
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: cannot make $PWD/.nix-bazel-deps"
              '';
            };
            update-locks-variants-deps-dir-file = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-deps-dir-file";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "records";
              prepare = "export DEPS_DIR_FILE=1";
              expect = ''
                expect_status 8
                expect_runs ${quoted [ probeArgs ]}
                expect_stderr "update-locks: cannot make $PWD/.nix-bazel-deps"
                expect_stderr "update-locks: cannot update locks/${firstShell}.lock and locks/${firstShell}.archives.json (the error above)"
              '';
            };
            # Where no user namespace can be made, a variant fails, named.
            update-locks-check-variants-no-userns = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-no-userns";
              shells = lockShells;
              runner = ''
                ${pkgs.bubblewrap}/bin/bwrap --unshare-user --disable-userns --dev-bind / / --proc /proc -- \
                  sh -c 'export TREE_MNTNS=$(readlink /proc/self/ns/mnt); exec "$@"' sh'';
              args = "--check";
              standIn = "records";
              prepare = "";
              expect = ''
                expect_status 6
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr "update-locks: cannot enter ${firstShell}'s namespace (bwrap's error above)"
              '';
            };
            # Nor where the namespace is made but a mount in it fails: no proc
            # may be mounted where one is partly hidden.
            update-locks-check-variants-mount-fails = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-mount-fails";
              shells = lockShells;
              runner = ''
                ${pkgs.bubblewrap}/bin/bwrap --dev-bind / / --proc /proc --ro-bind /dev/null /proc/version -- \
                  sh -c 'export TREE_MNTNS=$(readlink /proc/self/ns/mnt); exec "$@"' sh'';
              args = "--check";
              standIn = "records";
              prepare = "";
              expect = ''
                expect_status 6
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_stderr_like "bwrap: Can't mount proc on .*"
                expect_stderr "update-locks: cannot enter ${firstShell}'s namespace (bwrap's error above)"
              '';
            };
            # A signal in a variant's namespace stops the check and everything
            # in the namespace, with nothing reported.
            update-locks-check-variants-interrupted = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-interrupted";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "interrupts@${firstShell}";
              prepare = "";
              expect = ''
                expect_status 130
                expect_reported
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns [ firstShell ])}
                expect_nothing_left
              '';
            };
            update-locks-check-variants-terminated = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-terminated";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "terminates@${firstShell}";
              prepare = "";
              expect = ''
                expect_status 143
                expect_reported
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns [ firstShell ])}
                expect_nothing_left
              '';
            };
            update-locks-check-variants-killed = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-killed";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "killed@${firstShell}";
              prepare = "";
              expect = ''
                expect_status 137
                expect_reported
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns [ firstShell ])}
                expect_nothing_left
              '';
            };
            # A TERM while Nix evaluates a variant's dev shell stops it.
            update-locks-check-variants-terminated-evaluating = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-terminated-evaluating";
              shells = lockShells;
              runner = "";
              args = "--check";
              standIn = "terminates@evaluation";
              prepare = "";
              expect = ''
                expect_status 143
                expect_reported
                expect_unchanged
                expect_runs ${quoted [ checkRun ]}
                expect_nothing_left
                expect_stderr "nix shim: evaluating"
              '';
            };
            # A variant needs no bash on PATH.
            update-locks-check-variants-no-bash = mkUpdateLocksCheck {
              name = "flazel-update-locks-check-variants-no-bash";
              shells = lockShells;
              runner = pkgs.writeShellScript "without-bash" ''
                path=
                IFS=:
                for dir in $PATH; do
                  [ -e "$dir/bash" ] || path=''${path:+$path:}$dir
                done
                PATH=$path exec "$@"
              '';
              args = "--check";
              standIn = "records";
              prepare = "";
              expect = ''
                expect_status 0
                expect_reported
                expect_unchanged
                expect_runs ${quoted ([ checkRun ] ++ variantRuns lockShells)}
              '';
            };
            # No Bazel the app starts keeps a descriptor the app inherited.
            update-locks-fds = mkUpdateLocksCheck {
              name = "flazel-update-locks-fds";
              shells = lockShells;
              runner = "sh -c 'exec 9>$TMPDIR/fd-marker; exec \"$@\"' sh";
              args = "";
              standIn = "records";
              prepare = "";
              expect = ''
                expect_status 0
                expect_runs ${
                  quoted (
                    [ probeArgs ] ++ map (shell: "--output locks/${shell}.archives.json ${probeArgs}") lockShells
                  )
                }
              '';
            };
            # A signal while updating, in the default shell or a variant's
            # namespace, stops the app and everything it started, and leaves
            # every file as it was or replaced whole.
            update-locks-terminated = mkUpdateLocksCheck {
              name = "flazel-update-locks-terminated";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "terminates";
              prepare = "";
              expect = ''
                expect_status 143
                expect_runs ${quoted ([ probeArgs ])}
                expect_nothing_left
                expect_whole MODULE.bazel.lock flazel-archives.json locks/*
              '';
            };
            update-locks-variants-interrupted = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-interrupted";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "interrupts@${firstShell}";
              prepare = "";
              expect = ''
                expect_status 130
                expect_runs ${
                  quoted ([
                    probeArgs
                    "--output locks/${firstShell}.archives.json ${probeArgs}"
                  ])
                }
                expect_nothing_left
                expect_whole MODULE.bazel.lock flazel-archives.json locks/*
              '';
            };
            update-locks-variants-terminated = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-terminated";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "terminates@${firstShell}";
              prepare = "";
              expect = ''
                expect_status 143
                expect_runs ${
                  quoted ([
                    probeArgs
                    "--output locks/${firstShell}.archives.json ${probeArgs}"
                  ])
                }
                expect_nothing_left
                expect_whole MODULE.bazel.lock flazel-archives.json locks/*
              '';
            };
            # Ctrl-C on a terminal with tostop set stops the update, and its
            # output reaches the terminal.
            update-locks-variants-pty = mkUpdateLocksCheck {
              name = "flazel-update-locks-variants-pty";
              shells = lockShells;
              runner = "";
              args = "";
              standIn = "pty@${firstShell}";
              prepare = "";
              expect = ''
                expect_status 130
                expect_runs ${
                  quoted ([
                    probeArgs
                    "--output locks/${firstShell}.archives.json ${probeArgs}"
                  ])
                }
                expect_nothing_left
                expect_whole MODULE.bazel.lock flazel-archives.json locks/*
                expect_stderr "flazel-lock-archives: observing"
              '';
            };
            update-locks-usage = mkUpdateLocksCheck {
              name = "flazel-update-locks-usage";
              shells = [ ];
              runner = "";
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
