#!/bin/bash
# Prints the running herdr server's responsible process. Works without root.
set -euo pipefail

# Anchored to argv[0] so helper processes whose arguments mention "herdr server" don't match.
pid="$(pgrep -o -f '^[^ ]*/herdr server( |$)' || true)"
if [[ -z "${pid}" ]]; then
  echo "herdr server: not running"
  exit 2
fi

resp="$(python3 - "${pid}" <<'PY'
import ctypes, sys
f = ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
f.argtypes = [ctypes.c_int]
f.restype = ctypes.c_int
print(f(int(sys.argv[1])))
PY
)"
path="$(ps -o comm= -p "${resp}" 2>/dev/null || echo "<exited>")"
echo "herdr server pid=${pid} responsible pid=${resp} ${path}"
[[ "${path}" == *"/Herdr Server.app/"* ]]
