#!/bin/bash
# Smoke test for the launcher against a fake `herdr` that listens on the API socket.
# Verifies: the child is attributed to the launcher, crashed children are respawned, a
# foreign server on the socket puts the launcher in standby, and SIGTERM is forwarded.
#
#   tests/smoke.sh build/Herdr\ Server.app/Contents/MacOS/herdr-server-launcher

set -euo pipefail

launcher="${1:?launcher binary}"
tmp="$(mktemp -d)"
cleanup() {
  local job
  for job in $(jobs -p); do
    kill "${job}" 2>/dev/null || true
  done
  rm -rf "${tmp}"
}
trap cleanup EXIT

export HERDR_SOCKET_PATH="${tmp}/herdr.sock"
export HERDR_SERVER_BIN="${tmp}/herdr"
log="${tmp}/launcher.log"

# Fake herdr: `herdr server` binds the socket and idles; anything else fails.
cat >"${HERDR_SERVER_BIN}" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "server" ]] || exit 64
exec python3 - "${HERDR_SOCKET_PATH}" <<'PY'
import os, signal, socket, sys, time
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(4)
s.settimeout(0.5)
def bye(*_):
    try:
        os.unlink(path)
    finally:
        sys.exit(0)
signal.signal(signal.SIGTERM, bye)
while True:
    try:
        c, _ = s.accept()
        c.close()
    except socket.timeout:
        pass
PY
EOF
chmod +x "${HERDR_SERVER_BIN}"

responsible() {
  python3 -c 'import ctypes,sys
f=ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
f.argtypes=[ctypes.c_int]; f.restype=ctypes.c_int; print(f(int(sys.argv[1])))' "$1"
}

child_of() {
  pgrep -P "$1" | head -n1
}

wait_for() {
  local tries="$1"
  shift
  for ((i = 0; i < tries; i++)); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

fail() {
  echo "FAIL: $*" >&2
  echo "--- launcher log ---" >&2
  cat "${log}" >&2
  exit 1
}

echo "1. launcher spawns a server that inherits its attribution"
# Responsibility is inherited, so the child resolves to whatever the launcher resolves to:
# under launchd that is the launcher itself; under this shell it is the terminal app.
"${launcher}" 2>"${log}" &
lpid=$!
wait_for 50 test -S "${HERDR_SOCKET_PATH}" || fail "socket never appeared"
cpid="$(child_of "${lpid}")"
[[ -n "${cpid}" ]] || fail "no child"
resp="$(responsible "${cpid}")"
expected="$(responsible "${lpid}")"
[[ "${resp}" == "${expected}" ]] || fail "child ${cpid} responsible=${resp}, launcher ${lpid} responsible=${expected}"
echo "   ok: child ${cpid} and launcher ${lpid} both responsible=${resp}"

echo "2. a crashed server is respawned"
kill -KILL "${cpid}"
rm -f "${HERDR_SOCKET_PATH}"
wait_for 50 bash -c "[[ -n \"\$(pgrep -P ${lpid})\" && \"\$(pgrep -P ${lpid})\" != ${cpid} ]]" || fail "not respawned"
wait_for 50 test -S "${HERDR_SOCKET_PATH}" || fail "socket after respawn"
cpid2="$(child_of "${lpid}")"
echo "   ok: respawned as ${cpid2}"

echo "3. SIGTERM is forwarded and the launcher exits"
kill -TERM "${lpid}"
wait_for 50 bash -c "! kill -0 ${lpid} 2>/dev/null" || fail "launcher still running"
wait "${lpid}" && true
kill -0 "${cpid2}" 2>/dev/null && fail "child ${cpid2} survived SIGTERM"
grep -q "exiting" "${log}" || fail "no exit log"
echo "   ok"

echo "4. a foreign server on the socket puts the launcher in standby"
"${HERDR_SERVER_BIN}" server &
foreign=$!
wait_for 50 test -S "${HERDR_SOCKET_PATH}" || fail "foreign socket"
"${launcher}" 2>>"${log}" &
lpid=$!
wait_for 25 grep -q "standing by" "${log}" || fail "no standby"
[[ -z "$(child_of "${lpid}")" ]] || fail "spawned despite foreign server"
echo "   ok: standing by behind pid ${foreign}"

echo "5. once the foreign server is gone, the launcher spawns its own"
kill -TERM "${foreign}"
wait "${foreign}" 2>/dev/null || true
# Standby polls every 15s; allow up to ~20s.
wait_for 110 bash -c "[[ -n \"\$(pgrep -P ${lpid})\" ]]" || fail "no spawn after foreign exit"
kill -TERM "${lpid}"
wait "${lpid}" || true
echo "   ok"

echo "smoke: all passed"
