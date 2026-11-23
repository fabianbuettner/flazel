# The marker contract of update-locks' stopping: forwardTerm ($forwardTerm)
# creates its marker before it signals its group, and nsInit ($nsInit) does
# not start its command once the marker exists. Needs $coreutilsEnv.
set -u
failed=0
fail() {
  echo "FAIL: $*" >&2
  failed=1
}
cd "$TMPDIR" || exit

: >stopped
"$coreutilsEnv" --ignore-signal=TERM "$nsInit" stopped sh -c ': >ran'
rc=$?
echo "marker, TERM ignored: exit $rc"
[ "$rc" = 143 ] || fail "marker, TERM ignored: exit $rc, not 143"
[ ! -e ran ] || fail "marker, TERM ignored: the command ran"

"$nsInit" none sh -c ': >ran; exit 3'
rc=$?
echo "no marker: exit $rc"
[ "$rc" = 3 ] || fail "no marker: exit $rc, not the command's"
[ -e ran ] || fail "no marker: the command did not run"

rm -f ran
"$coreutilsEnv" --ignore-signal=TERM "$nsInit" none sh -c 'kill -TERM $$; : >ran'
rc=$?
echo "no marker, TERM ignored: exit $rc"
[ "$rc" = 143 ] || fail "no marker, TERM ignored: exit $rc, not 143"
[ ! -e ran ] || fail "no marker, TERM ignored: the command outlived a TERM"

# Whether PID has a TERM pending.
term_pending() {
  local key mask pending=0
  while read -r key mask; do
    case $key in
    SigPnd: | ShdPnd:) pending=$((pending | 0x$mask)) ;;
    esac
  done <"/proc/$1/status"
  [ $((pending & 1 << 14)) != 0 ]
}
# forward_term MARKER: forwardTerm in a session of its own, around a
# command that reports its pid in child.pid; sets ft and child.
forward_term() {
  rm -f child.pid
  setsid "$forwardTerm" "$1" sh -c 'echo $$ >child.tmp; mv child.tmp child.pid; exec sleep 1000' &
  ft=$!
  for _ in $(seq 100); do
    [ -s child.pid ] && break
    sleep 0.1
  done
  [ -s child.pid ] || {
    echo "harness: the command never started" >&2
    exit 1
  }
  child=$(cat child.pid)
}

forward_term marker
kill -TERM "$ft"
wait "$ft"
rc=$?
echo "TERM: exit $rc"
[ "$rc" = 143 ] || fail "TERM: exit $rc, not the command's 143"
[ -e marker ] || fail "TERM: no marker"

# A stopped command keeps a TERM pending, and a FIFO as the marker holds
# forwardTerm in its creation until it is read.
mkfifo fifo
forward_term fifo
kill -STOP "$child"
kill -TERM "$ft"
for _ in $(seq 100); do
  [ "$(cat "/proc/$ft/wchan" 2>/dev/null)" != wait_for_partner ] || break
  ! term_pending "$child" || break
  sleep 0.1
done
echo "TERM, marker not yet created: forwardTerm in $(cat "/proc/$ft/wchan" 2>/dev/null)"
! term_pending "$child" || fail "TERM: the group was signalled before the marker was created"
timeout 10 sh -c ': <"$0"' fifo || fail "TERM: forwardTerm did not create the marker"
for _ in $(seq 100); do
  term_pending "$child" && break
  sleep 0.1
done
term_pending "$child" || fail "TERM: the group was not signalled once the marker was created"
kill -CONT "$child"
wait "$ft"
echo "TERM, marker created: exit $?"

[ "$failed" = 0 ]
