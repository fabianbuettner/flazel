# An app that refreshes MODULE.bazel.lock with the default dev shell's Bazel,
# writes locks/<shell>.lock with the Bazel of each named dev shell, and the
# matching flazel-archives.json and locks/<shell>.archives.json via
# flazel-lock-archives, observing one build per entry of probes (a list of
# Bazel argument lists). With --check it writes none of them and fails
# naming each that is stale. Run it in the project directory.
{
  pkgs,
  shells,
  probes,
}:
let
  inherit (pkgs) lib;
  inherit (import ./constants.nix) nixDepsDir;
  inherit (import ./stop-marker.nix { inherit pkgs; }) forwardTerm nsInit;
  # What forwardTerm creates once the app stops a command.
  stopMarker = "$scratch/stopped";
  # A session of its own, out of reach of the terminal's job control, whose
  # leader passes a TERM to every process in it. On Linux the leader gets
  # one when the app dies.
  detached = lib.concatStringsSep " " (
    [ "${pkgs.util-linux}/bin/setsid" ]
    ++ lib.optional pkgs.stdenv.hostPlatform.isLinux "${pkgs.util-linux}/bin/setpriv --pdeathsig TERM"
    ++ [ "${forwardTerm} \"${stopMarker}\"" ]
  );
  lockArchives = pkgs.writeShellScript "lock-archives" ''
    exec flazel-lock-archives "$@" -- ${lib.concatMapStringsSep " --and " lib.escapeShellArgs probes}
  '';
  sh = pkgs.runtimeShell;
  realpath = "${pkgs.coreutils}/bin/realpath -m";
  # What a dev shell creates once its setup has run to its end.
  setUpMarker = "$scratch/set-up";
  # Bazel's server redirects fds 0-2 but keeps every other inherited one
  # open, so none above 2 may be open when Bazel starts.
  closeFds = ''
    for fd in /dev/fd/*; do
      fd=''${fd##*/}
      [ "$fd" -le 2 ] || exec {fd}>&-
    done
  '';
  # read_bases < FILE: output_base and install_base from what
  # `bazel info output_base install_base` printed.
  readBases = ''
    read_bases() {
      output_base=
      install_base=
      while IFS= read -r line; do
        case $line in
        "output_base: "*) output_base=''${line#output_base: } ;;
        "install_base: "*) install_base=''${line#install_base: } ;;
        esac
      done
    }
  '';

  # flazel-lock-archives --check's status for a manifest that differs.
  manifestDiffers =
    let
      m = builtins.match ".*\nDIFFERS = ([0-9]+)\n.*" (builtins.readFile ./archive_manifest.py);
    in
    if m == null then throw "update-locks.nix: no DIFFERS in archive_manifest.py" else builtins.head m;

  # $1: the manifest. A missing one is reported, not derived. A stale lock
  # exits 3 and a lock Bazel cannot check 8; a manifest that differs exits 4
  # and one the tool cannot check 9.
  checkBody = ''
    if ! bazel mod deps --lockfile_mode=error >/dev/null 2>"$TMPDIR/mod-deps.err"; then
      # Bazel exits 2 or 37 for a stale lock and for other errors alike, so
      # a stale lock is told by the messages of its lockfile checks.
      lock_status=8
      while IFS= read -r line || [ -n "$line" ]; do
        printf "%s\n" "$line" >&2
        case $line in
        *"ERROR: "*"--lockfile_mode=update"*"to update your lockfile"* | *"ERROR: "*"does not exist in the lockfile"*)
          lock_status=3
          ;;
        esac
      done <"$TMPDIR/mod-deps.err"
      ns_exit "$lock_status"
    fi
    [ -f "$1" ] || ns_exit 0
    status=0
    ${lockArchives} --check --output "$1" || status=$?
    case $status in
    0) ;;
    ${manifestDiffers}) ns_exit 4 ;;
    *) ns_exit 9 ;;
    esac
  '';
  # $1: the manifest; $2: where the refreshed lock goes, replaced whole.
  variantUpdateBody = ''
    bazel mod deps --lockfile_mode=update >/dev/null
    ${lockArchives} --output "$1"
    cp MODULE.bazel.lock "$2.tmp"
    mv "$2.tmp" "$2"
  '';
  # A shell that sources the dev shell setup Nix evaluated into
  # $FLAZEL_DEV_ENV, creates $FLAZEL_SET_UP once that setup has run to its
  # end, then runs body in a subshell, in which a failing command exits 8.
  # Only a status body passes to ns_exit leaves the shell, so a setup
  # function that exits ends it with 8 too, and only the app's own code
  # exits 5, 6 or 7. The FLAZEL_* variables the app passes are taken into
  # ns_* first, so no Bazel a shellHook runs sees them.
  inShell = body: "${sh} -c '\n${inShellScript body}'";
  inShellScript = body: ''
    ${closeFds}
    ${takeEnv}
    ns_exited=$TMPDIR/exited
    . "$ns_dev_env"
    : >"$ns_set_up"
    : >"$ns_exited"
    ns_exit() {
      echo "$1" >"$ns_exited"
      exit "$1"
    }
    # A TERM reaches the body too, which dies of it after its EXIT trap;
    # this shell waits for that, with no stderr to report the death on.
    trap "exit 143" TERM
    exec {ns_stderr}>&2 2>/dev/null
    # Not in a list, which would disable the ERR trap in it.
    (
      trap "ns_exit 8" ERR
      ${body}
      ns_exit 0
    ) 2>&$ns_stderr {ns_stderr}>&-
    ns_status=$?
    exec 2>&$ns_stderr {ns_stderr}>&-
    read -r ns_passed <"$ns_exited" || ns_passed=
    [ "$ns_status" = "$ns_passed" ] || {
      echo "update-locks: a command in the dev shell $ns_shell exited $ns_status, outside the statuses of the app" >&2
      exit 8
    }
    exit "$ns_status"
  '';
  takeEnv = ''
    ns_dev_env=$FLAZEL_DEV_ENV
    ns_set_up=$FLAZEL_SET_UP
    ns_shell=$FLAZEL_SHELL
    ns_output_base=''${FLAZEL_OUTPUT_BASE-}
    ns_install_root=''${FLAZEL_INSTALL_ROOT-}
    unset FLAZEL_DEV_ENV FLAZEL_SET_UP FLAZEL_SHELL FLAZEL_OUTPUT_BASE FLAZEL_INSTALL_ROOT
  '';
  # The shell running the last shutdown ignores TERM, so it outlives the
  # group's TERM and the shutdown completes.
  shutdownOnExit = ''trap "trap \"\" TERM; bazel shutdown" EXIT'';
  # The default dev shell, evaluated once into $scratch/default-env.
  inDefault =
    body:
    "in_dev_shell default true env FLAZEL_DEV_ENV=\"$scratch/default-env\" FLAZEL_SET_UP=\"${setUpMarker}\" FLAZEL_SHELL=default TMPDIR=\"$scratch\" ${inShell body}";
  # In a variant's namespace, as its pid 1: Bazel's output base and install
  # base on their tmpfs, or nothing. A Bazel that cannot report them exits 8.
  inVariant = body: "${nsInit} \"${stopMarker}\" ${inShell "${variantPrologue}${body}"}";
  variantPrologue = ''
    ${readBases}
    bazel info output_base install_base >"$TMPDIR/bases" || {
      echo "update-locks: cannot ask the Bazel of $ns_shell for its output base" >&2
      ns_exit 8
    }
    read_bases <"$TMPDIR/bases"
    case $output_base in
    "$ns_output_base") ;;
    *)
      echo "update-locks: the output base of $ns_shell, $output_base, is not $ns_output_base on tmpfs" >&2
      ns_exit 5
      ;;
    esac
    case $install_base in
    "$ns_install_root"/*) ;;
    *)
      echo "update-locks: the install base of $ns_shell, $install_base, is not under $ns_install_root on tmpfs" >&2
      ns_exit 5
      ;;
    esac
  '';

  # bash runs a trap only once the foreground command returns, so each
  # long command runs in the background, detached, and the trap stops it.
  # The job table holds a command from the moment it starts, so a signal
  # that lands before run() reaches wait still finds it.
  stopping = ''
    stop() {
      kill -TERM $(jobs -p) 2>/dev/null || true
      wait || true
      exit "$1"
    }
    trap 'stop 130' INT
    trap 'stop 143' TERM
    # run COMMAND...: COMMAND detached, with its status. Without job control
    # setsid does not fork, so the job is the session.
    run() {
      local rc=0
      ${detached} "$@" </dev/null &
      wait $! || rc=$?
      return "$rc"
    }
  '';

  # Every dev shell is evaluated on its own first, so a failing evaluation
  # has a status of its own. Each scratch file lives in $scratch, and
  # $scratch/ns is the variants' TMPDIR.
  evaluating = ''
    scratch_failed() {
      echo "update-locks: cannot make a scratch directory" >&2
      exit 8
    }
    scratch=$(mktemp -d) || scratch_failed
    trap 'rm -rf "$scratch"' EXIT
    ${lib.optionalString (shells != [ ]) ''mkdir "$scratch/ns" || scratch_failed''}
    # evaluate NAME FILE INSTALLABLE...: the setup of dev shell NAME in FILE,
    # or status 7.
    evaluate() {
      run nix print-dev-env "''${@:3}" >"$2" || {
        echo "update-locks: cannot evaluate the dev shell $1 (nix's error above)" >&2
        return 7
      }
    }
    # in_dev_shell NAME ENTERED COMMAND...: COMMAND, which sources the setup
    # of dev shell NAME, with its status; 6 if ENTERED NAME fails after it,
    # else 7 unless the setup ran to its end, which a shellHook's exit
    # prevents.
    in_dev_shell() {
      local name=$1 entered=$2 rc=0
      shift 2
      rm -f "${setUpMarker}"
      run "$@" || rc=$?
      "$entered" "$name" || return 6
      [ -e "${setUpMarker}" ] || {
        echo "update-locks: the dev shell $name setup exited $rc before its end" >&2
        return 7
      }
      return "$rc"
    }
  '';

  # variant_ns SHELL BWRAP_ARGS... COMMAND: COMMAND in SHELL's dev shell, in a
  # mount and pid namespace over the tree where BWRAP_ARGS put the variant's
  # lock at MODULE.bazel.lock. Nix evaluates outside, so it sees the tree as
  # it is. The dev shell setup, the default Bazel's output base, its install
  # bases and temporary files are on tmpfs, unseen outside, and all in it,
  # Bazel's server too, dies with it. bwrap ignores the TERM that stops the
  # command, so it ends only after the namespace has.
  variantNs = ''
    ${readBases}
    output_base=
    variant_ns() {
      shell=$1
      shift
      if [ -z "$output_base" ]; then
        ${inDefault ''
          ${shutdownOnExit}
          bazel info output_base install_base
        ''} >"$scratch/bases" || case $? in
          7) return 7 ;;
          *)
            echo "update-locks: cannot ask the default Bazel for its output base" >&2
            return 8
            ;;
          esac
        read_bases <"$scratch/bases"
        install_root=''${install_base%/*}
        # Bazel resolves symlinks in some bases and not in others, and $PWD
        # may hold them too.
        project=$(${realpath} "$PWD")
        for mount in "$output_base" "$install_root"; do
          case $project/ in
          "$(${realpath} "$mount")"/*)
            echo "update-locks: the project is inside Bazel's $mount" >&2
            return 5
            ;;
          esac
        done
      fi
      evaluate "$shell" "$scratch/dev-env" ".#$shell" || return
      mkdir -p ${nixDepsDir} || {
        echo "update-locks: cannot make $PWD/${nixDepsDir}" >&2
        return 8
      }
      in_dev_shell "$shell" ns_entered ${pkgs.coreutils}/bin/env --ignore-signal=TERM \
        ${pkgs.bubblewrap}/bin/bwrap --json-status-fd 3 \
        --dev-bind / / --proc /proc --unshare-pid --as-pid-1 --die-with-parent \
        --tmpfs "$PWD/${nixDepsDir}" --tmpfs "$output_base" \
        --tmpfs "$install_root" --tmpfs "$scratch/ns" \
        --ro-bind-data 6 "$scratch/ns/dev-env" \
        --setenv FLAZEL_DEV_ENV "$scratch/ns/dev-env" \
        --setenv FLAZEL_SET_UP "${setUpMarker}" \
        --setenv FLAZEL_SHELL "$shell" \
        --setenv FLAZEL_OUTPUT_BASE "$output_base" \
        --setenv FLAZEL_INSTALL_ROOT "$install_root" \
        --setenv TMPDIR "$scratch/ns" "$@" \
        3>"$scratch/status" 6<"$scratch/dev-env"
    }
    # ns_entered SHELL: whether bwrap started the command, which it reports
    # with an exit-code only after every mount.
    ns_entered() {
      grep -q '"exit-code"' "$scratch/status" || {
        echo "update-locks: cannot enter $1's namespace (bwrap's error above)" >&2
        return 1
      }
    }
  '';

  update = ''
    # update_failed FILES STATUS: 1 is a stale file's and 2 a wrong
    # argument's, so whatever else stops an update exits 8.
    update_failed() {
      case $2 in
      5 | 6 | 7 | 130 | 143) exit "$2" ;;
      esac
      echo "update-locks: cannot update $1 (the error above)" >&2
      exit 8
    }
    ${lib.optionalString (shells != [ ]) "mkdir -p locks || update_failed locks/ $?"}
    # Every lock is refreshed before its manifest is derived, because
    # flazel-lock-archives reads the lock and refuses a stale one.
    evaluate default "$scratch/default-env"
    ${inDefault ''
      bazel shutdown
      ${shutdownOnExit}
      bazel mod deps --lockfile_mode=update >/dev/null
      ${lockArchives}
    ''} || update_failed "MODULE.bazel.lock and flazel-archives.json" $?
    ${lib.optionalString (shells != [ ]) ''
      ${variantNs}
      # Each version starts from the refreshed default lock.
      ${lib.concatMapStrings (shell: ''
        variant_ns ${shell} --bind-data 5 "$PWD/MODULE.bazel.lock" \
          ${inVariant variantUpdateBody} sh locks/${shell}.archives.json locks/${shell}.lock \
          5<MODULE.bazel.lock || update_failed "locks/${shell}.lock and locks/${shell}.archives.json" $?
      '') shells}
    ''}
  '';

  check = ''
    ${lib.optionalString (shells != [ ]) variantNs}
    failed=
    nl=$'\n'
    fail() {
      failed="$failed''${failed:+$nl}update-locks --check: $1"
    }
    report() {
      [ -z "$failed" ] || printf '%s\n' "$failed" >&2
    }

    # check_one LOCK MANIFEST: the manifest is checked only against a current
    # lock, since flazel-lock-archives refuses a stale one.
    ${lib.optionalString (
      shells != [ ]
    ) "# A third argument, SHELL, checks in that variant's namespace."}
    check_one() {
      [ -f "$1" ] || fail "$1 is missing"
      [ -f "$2" ] || fail "$2 is missing"
      [ -f "$1" ] || return 0
      status=0
      ${lib.optionalString (shells != [ ]) ''
        if [ $# = 3 ]; then
          # bwrap would make the mount point of the variant's lock in the tree.
          [ -f MODULE.bazel.lock ] || {
            fail "$1 is not checked, since MODULE.bazel.lock is missing"
            return 0
          }
          variant_ns "$3" --ro-bind "$1" "$PWD/MODULE.bazel.lock" \
            ${inVariant checkBody} sh "$2" || status=$?
        else
      ''}
      ${inDefault ''
        bazel shutdown
        ${shutdownOnExit}
        ${checkBody}
      ''} sh "$2" || status=$?
      ${lib.optionalString (shells != [ ]) "fi"}
      # Status 1 is a stale or missing file's only, so whatever else stops a
      # check exits 8.
      case $status in
      0) ;;
      3) fail "$1 failed the check" ;;
      4) fail "$2 failed the check" ;;
      5 | 6 | 7)
        report
        exit "$status"
        ;;
      8) cannot_check "$1 (the error above)" ;;
      9) cannot_check "$2 (flazel-lock-archives' error above)" ;;
      *) cannot_check "$1: its check exited $status" ;;
      esac
    }
    cannot_check() {
      fail "cannot check $1"
      report
      exit 8
    }

    evaluate default "$scratch/default-env"
    check_one MODULE.bazel.lock flazel-archives.json
    ${lib.concatMapStrings (shell: ''
      check_one locks/${shell}.lock locks/${shell}.archives.json ${shell}
    '') shells}
    report
    [ -z "$failed" ] || exit 1
  '';

  # The variants' namespaces need bubblewrap.
  unsupported = pkgs.writeShellScript "update-locks" ''
    echo "update-locks: Bazel-version shells need Linux, for bubblewrap" >&2
    exit 6
  '';
in
assert lib.assertMsg (
  probes != [ ] && builtins.all (p: p != [ ]) probes
) "mkUpdateLocksApp: probes needs at least one non-empty Bazel argument list";
{
  type = "app";
  program = toString (
    if shells != [ ] && !pkgs.stdenv.hostPlatform.isLinux then
      unsupported
    else
      pkgs.writeShellScript "update-locks" ''
        set -eu
        ${stopping}
        ${evaluating}
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
