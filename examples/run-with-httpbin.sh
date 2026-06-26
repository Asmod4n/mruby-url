#!/bin/sh
# Run examples/error_handling.rb against a local go-httpbin container — the same
# server httpbingo.org runs — so the demo never depends on a flaky public
# instance (httpbin.org regularly stalls for minutes).
#
#   examples/run-with-httpbin.sh [path/to/mruby]
#
# Knobs (env): RUNNER (default: podman), PORT (default: 8080), MRUBY.
# The httpbin routes (status/delay/get) are served locally; the TLS case (#5,
# badssl.com) and DNS case (#3, *.invalid) still reach the network / resolver.
set -eu

RUNNER="${RUNNER:-podman}"
PORT="${PORT:-8080}"
IMAGE="docker.io/mccutchen/go-httpbin:latest"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if   [ -n "${1:-}" ];                                          then MRUBY="$1"
elif [ -n "${MRUBY:-}" ];                                      then MRUBY="$MRUBY"
elif [ -x "${SCRIPT_DIR}/../mruby/build/host/bin/mruby" ];     then MRUBY="${SCRIPT_DIR}/../mruby/build/host/bin/mruby"
else                                                                MRUBY="mruby"
fi

command -v "$RUNNER" >/dev/null 2>&1 || { echo "need '$RUNNER' (set RUNNER=docker to use docker)" >&2; exit 1; }

cid="$("$RUNNER" run -d --rm -p "${PORT}:8080" "$IMAGE")"
trap '"$RUNNER" rm -f "$cid" >/dev/null 2>&1 || true' EXIT INT TERM

# Wait for go-httpbin to answer before running the examples.
i=0
until curl -sf "http://localhost:${PORT}/status/200" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 100 ] && { echo "go-httpbin did not come up on :${PORT}" >&2; exit 1; }
  sleep 0.1
done

"$MRUBY" "${SCRIPT_DIR}/error_handling.rb" "http://localhost:${PORT}"
