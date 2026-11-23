# How update-locks stops what it starts. A command that starts with TERM
# ignored, as in a variant's namespace, drops a TERM until it restores the
# default; the marker forwardTerm leaves before signalling stops it then.
{ pkgs }:
{
  # forward-term MARKER COMMAND...: COMMAND, which on TERM gets MARKER
  # created, then one TERM to its whole process group. The first wait
  # returns early when the trap runs; the second gets the command's status.
  forwardTerm = pkgs.writeShellScript "forward-term" ''
    stopped=$1
    shift
    trap ': >"$stopped"; trap "" TERM; kill -TERM 0' TERM
    "$@" &
    wait $! || true
    wait $!
  '';
  # ns-init MARKER COMMAND...: a variant namespace's pid 1. With bwrap's
  # own, bwrap ends with the command; the kernel reports this one's end
  # only once everything in the namespace has ended. As an init it ignores
  # TERM, so COMMAND, with TERM restored, gets it. TERM is restored before
  # MARKER is checked; once MARKER exists COMMAND does not start, and it
  # exits 143.
  nsInit = pkgs.writeShellScript "ns-init" ''
    ${pkgs.coreutils}/bin/env --default-signal=TERM ${pkgs.runtimeShell} -c '[ ! -e "$0" ] || exit 143; exec "$@"' "$@" &
    wait $!
  '';
}
