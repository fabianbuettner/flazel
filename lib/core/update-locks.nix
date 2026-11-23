# An app that refreshes MODULE.bazel.lock with the default dev shell's Bazel,
# writes locks/<shell>.lock with the Bazel of each named dev shell, and the
# matching flazel-archives.json and locks/<shell>.archives.json via
# flazel-lock-archives, observing one build per entry of probes (a list of
# Bazel argument lists). With --check, for a project without shells, it
# writes none of them and fails naming each that is stale. Run it in the
# project directory.
{
  pkgs,
  shells,
  probes,
}:
let
  inherit (pkgs) lib;
  # Runs a command and, on TERM, sends one TERM to its whole process group.
  # The first wait returns early when the trap runs; the second gets the
  # command's status.
  forwardTerm = pkgs.writeShellScript "forward-term" ''
    trap 'trap "" TERM; kill -TERM 0' TERM
    "$@" &
    wait $! || true
    wait $!
  '';
  # A session of its own, out of reach of the terminal's job control, whose
  # leader passes a TERM to every process in it. On Linux the leader gets
  # one when the app dies.
  detached = lib.concatStringsSep " " (
    [ "${pkgs.util-linux}/bin/setsid" ]
    ++ lib.optional pkgs.stdenv.hostPlatform.isLinux "${pkgs.util-linux}/bin/setpriv --pdeathsig TERM"
    ++ [ "${forwardTerm}" ]
  );
  lockArchives = pkgs.writeShellScript "lock-archives" ''
    exec flazel-lock-archives "$@" -- ${lib.concatMapStringsSep " --and " lib.escapeShellArgs probes}
  '';

  update = ''
    ${lib.optionalString (shells != [ ]) "mkdir -p locks"}
    # Every lock is refreshed before its manifest is derived, because
    # flazel-lock-archives reads the lock and refuses a stale one.
    nix develop --command sh -ec '
      bazel shutdown
      trap "bazel shutdown" EXIT
      bazel mod deps --lockfile_mode=update >/dev/null
      ${lockArchives}
    '
    ${lib.optionalString (shells != [ ]) ''
      # Each iteration below starts from the refreshed lock and replaces the
      # live file, and overwrites the default manifest; the trap puts both
      # back, also when a run dies partway.
      trap '[ -f MODULE.bazel.lock.saved ] \
        && mv MODULE.bazel.lock.saved MODULE.bazel.lock || true
        [ -f flazel-archives.json.default ] \
        && mv flazel-archives.json.default flazel-archives.json || true' EXIT
      cp MODULE.bazel.lock MODULE.bazel.lock.saved
      cp flazel-archives.json flazel-archives.json.default
      ${lib.concatMapStrings (shell: ''
        # Bazel rewrites the lockfile in its own format; the default one stays
        # in place because dev shells evaluate it. A server left running
        # rewrites it again when another version's client stops it.
        nix develop .#${shell} --command sh -ec '
          bazel shutdown
          trap "bazel shutdown" EXIT
          cp MODULE.bazel.lock.saved MODULE.bazel.lock
          bazel mod deps --lockfile_mode=update >/dev/null
          ${lockArchives}
        '
        mv flazel-archives.json locks/${shell}.archives.json
        mv MODULE.bazel.lock locks/${shell}.lock
      '') shells}
    ''}
  '';

  check =
    if shells != [ ] then
      ''
        echo "update-locks: --check does not support Bazel-version shells yet" >&2
        exit 2
      ''
    else
      ''
        # bash runs a trap only once the foreground command returns, so each
        # command runs in the background, detached, and the trap stops it.
        # Nothing is reported as stale on a signal.
        child=
        stop() {
          [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
          wait || true
          exit "$1"
        }
        trap 'stop 130' INT
        trap 'stop 143' TERM
        failed=
        nl=$'\n'
        fail() {
          failed="$failed''${failed:+$nl}update-locks --check: $1"
        }
        report() {
          [ -z "$failed" ] || printf '%s\n' "$failed" >&2
        }

        # check_one LOCK MANIFEST: the manifest is checked only against a
        # current lock, since flazel-lock-archives refuses a stale one.
        check_one() {
          [ -f "$1" ] || fail "$1 is missing"
          [ -f "$2" ] || fail "$2 is missing"
          [ -f "$1" ] || return 0
          # Without job control setsid does not fork, so $! is the session.
          ${detached} nix develop --command sh -ec '
            bazel shutdown
            trap "bazel shutdown" EXIT
            bazel mod deps --lockfile_mode=error >/dev/null || exit 3
            [ -f "$1" ] || exit 0
            ${lockArchives} --check --output "$1" || exit 4
          ' sh "$2" </dev/null &
          child=$!
          status=0
          wait "$child" || status=$?
          child=
          case $status in
          0) ;;
          3) fail "$1 failed the check" ;;
          4) fail "$2 failed the check" ;;
          *)
            report
            exit "$status"
            ;;
          esac
        }

        check_one MODULE.bazel.lock flazel-archives.json
        report
        [ -z "$failed" ] || exit 1
      '';
in
assert lib.assertMsg (
  probes != [ ] && builtins.all (p: p != [ ]) probes
) "mkUpdateLocksApp: probes needs at least one non-empty Bazel argument list";
{
  type = "app";
  program = toString (
    pkgs.writeShellScript "update-locks" ''
      set -eu
      if [ $# = 0 ]; then
        ${update}
      elif [ $# = 1 ] && [ "$1" = --check ]; then
        ${check}
      else
        echo "usage: update-locks [--check]" >&2
        exit 2
      fi
    ''
  );
}
