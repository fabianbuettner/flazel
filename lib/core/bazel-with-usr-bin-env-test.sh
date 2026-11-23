# Runs bazelWithUsrBinEnv ($wrapper, around a fake Bazel that prints its user
# namespace, whether /usr/bin/env runs, and its arguments) in the build
# sandbox and in emulated roots built with bwrap. Needs $wrapper, $coreutilsEnv, $bwrap.
set -u
failed=0
fail() {
  echo "FAIL: $*" >&2
  failed=1
}
[ ! -e /usr ] || {
  echo "harness: the build sandbox has /usr" >&2
  exit 1
}

# A root holding every entry of this one, plus the bwrap arguments given.
root() {
  local binds=() entry
  for entry in /*; do
    binds+=(--dev-bind "$entry" "$entry")
  done
  "$bwrap" "${binds[@]}" "$@"
}

outer=$(readlink /proc/self/ns/user)
out=$("$wrapper" a b) || fail "no /usr: exit $?"
echo "no /usr: $out"
[ "$out" != "ns=$outer env=ok args=a b" ] || fail "no /usr: ran in the caller's namespace"
case $out in
"ns="*" env=ok args=a b") ;;
*) fail "no /usr: env did not run: $out" ;;
esac

out=$(FAKE_RC=3 "$wrapper" 2>&1)
rc=$?
echo "Bazel fails: $out"
case $out in
*flazel*) fail "Bazel fails: reported as bwrap's failure" ;;
esac
[ "$rc" = 3 ] || fail "Bazel fails: exit $rc, not Bazel's"

# A signal to the wrapper's pid ends Bazel too.
FAKE_PIDFILE=$TMPDIR/fake.pid "$wrapper" &
pid=$!
for _ in $(seq 100); do
  [ -s "$TMPDIR/fake.pid" ] && break
  sleep 0.1
done
[ -s "$TMPDIR/fake.pid" ] || {
  echo "harness: the fake Bazel never started" >&2
  exit 1
}
fake=$(cat "$TMPDIR/fake.pid")
kill -TERM "$pid"
wait "$pid"
rc=$?
for _ in $(seq 50); do
  kill -0 "$fake" 2>/dev/null || break
  sleep 0.1
done
echo "signal: wrapper exit $rc"
[ "$rc" = 143 ] || fail "signal: wrapper exit $rc, not 143"
! kill -0 "$fake" 2>/dev/null || fail "signal: Bazel outlived the wrapper"

out=$(root --ro-bind "$coreutilsEnv" /usr/bin/env sh -c \
  'echo "$(readlink /proc/self/ns/user)"; exec "$0" a b' "$wrapper") || fail "env present: exit $?"
echo "env present: $out"
caller=$(echo "$out" | sed -n 1p)
[ "$(echo "$out" | sed -n 2p)" = "ns=$caller env=ok args=a b" ] ||
  fail "env present: did not run Bazel directly"

# $1: case name, $2: expected message; the rest are bwrap arguments.
refuse() {
  local name=$1 want=$2
  shift 2
  out=$(root "$@" sh -c '"$0"; echo "rc=$? usr=[$(ls -A /usr/ 2>/dev/null)]"' "$wrapper" 2>&1)
  echo "$name: $out"
  case $out in
  *"$want"*) ;;
  *) fail "$name: no message naming the cause" ;;
  esac
  case $out in
  *"ns="*) fail "$name: Bazel ran" ;;
  esac
  case $out in
  *"rc=1 usr=[]") ;;
  *) fail "$name: did not exit 1 with /usr left as it was" ;;
  esac
}
mkdir -p "$TMPDIR/empty"
refuse "writable /usr" "/usr exists but has no /usr/bin/env" --tmpfs /usr
refuse "read-only /usr" "/usr exists but has no /usr/bin/env" --ro-bind "$TMPDIR/empty" /usr
refuse "dangling /usr" "/usr exists but has no /usr/bin/env" --symlink /nonexistent /usr

# $1: case name; $2: refused or runs; the rest: a command running a shell
# script that runs the wrapper.
namespaces() {
  local name=$1 want=$2
  shift 2
  out=$("$@" sh -c '"$W"; echo "rc=$?"' 2>&1)
  echo "$name: $out"
  case $want in
  refused)
    case $out in
    *"bwrap could not create a user namespace"*) ;;
    *) fail "$name: no message naming the cause" ;;
    esac
    case $out in
    *"rc=1"*) ;;
    *) fail "$name: did not exit 1" ;;
    esac
    ;;
  runs)
    case $out in
    "ns="*" env=ok args="*"rc=0") ;;
    *) fail "$name: Bazel did not run" ;;
    esac
    ;;
  esac
}
export W=$wrapper
# An unprivileged user under a limit its own namespace already uses up, then
# with room for one more.
limited() {
  LIMIT=$1 unshare -Ur sh -c 'echo "$LIMIT" > /proc/sys/user/max_user_namespaces &&
    exec unshare --user --map-user=1000 --map-group=100 "$0" "$@"' "${@:2}"
}
namespaces "user namespaces used up" refused limited 1
namespaces "one user namespace left" runs limited 2
# Root without capabilities, as in a container, then with them.
namespaces "root without capabilities" refused \
  unshare -Ur setpriv --bounding-set=-all --inh-caps=-all
namespaces "root with capabilities" runs unshare -Ur

[ "$failed" = 0 ]
