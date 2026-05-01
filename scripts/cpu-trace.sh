#!/usr/bin/env bash
# scripts/cpu-trace.sh — capture a CPU sampling trace from aspnet-minimal
# while h2load / h2load-h3 generates load against the baseline-h2 / baseline-h3
# endpoint.
#
# Output: traces/<profile>.nettrace + traces/<profile>.speedscope.json
#
# Usage:
#   ./scripts/cpu-trace.sh baseline-h2
#   ./scripts/cpu-trace.sh baseline-h3
#
# Notes:
#  - Requires the aspnet-minimal image already built (with dotnet-trace).
#  - Requires h2load / h2load-h3 images already built.
#  - The framework runs with --cap-add SYS_PTRACE so dotnet-trace can attach.
#  - .nettrace opens in PerfView / Visual Studio. .speedscope.json drag-drops
#    onto https://www.speedscope.app/ for a shareable view.

set -euo pipefail

PROFILE="${1:-baseline-h2}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/traces"
mkdir -p "$OUT_DIR"

APP_IMG=httparena-aspnet-minimal
APP_NAME=httparena-trace-app
H2LOAD_IMG=h2load:latest
H2LOAD_H3_IMG=h2load-h3:local

case "$PROFILE" in
    baseline-h2)
        LOADGEN_IMG="$H2LOAD_IMG"
        # Match scripts/lib/tools/h2load.sh `h2)` — c=1024 m=100 t=64 (high end)
        LOADGEN_ARGS=("https://localhost:8443/baseline2?a=1&b=1" -c 1024 -m 100 -t 64 -D 60s)
        ;;
    baseline-h3)
        LOADGEN_IMG="$H2LOAD_H3_IMG"
        # Drastically reduced from canonical c=64 m=64 — kestrel+msquic
        # emits an extreme volume of transport EventPipe events under H3
        # load, deadlocking dotnet-trace's writer. c=8 m=8 keeps H3 active
        # at sub-saturation rate so the trace still captures hot paths
        # but the diagnostic channel doesn't overflow.
        LOADGEN_ARGS=(--alpn-list=h3 "https://localhost:8443/baseline2?a=1&b=1" -c 8 -m 8 -t 8 -D 30s)
        ;;
    *)
        echo "usage: $0 {baseline-h2|baseline-h3}" >&2
        exit 2
        ;;
esac

cleanup() {
    docker rm -f "$APP_NAME" "${APP_NAME}-load" 2>/dev/null || true
}
trap cleanup EXIT

cleanup

echo "[1/5] Starting aspnet-minimal container..."
# SYS_PTRACE + PERFMON: ptrace lets dotnet-trace attach via IPC; PERFMON
# enables `dotnet-trace collect-linux` which records kernel perf_events
# (real CPU samples — managed-only sampling deadlocks under heavy QUIC
# load on aspnet-minimal/h3).
docker run -d --name "$APP_NAME" --network host \
    --cap-add SYS_PTRACE \
    --cap-add PERFMON \
    --security-opt seccomp=unconfined \
    -v "$ROOT_DIR/certs:/certs:ro" \
    "$APP_IMG" >/dev/null

echo "[2/5] Waiting for server ready..."
for i in $(seq 1 30); do
    if curl -sk --max-time 2 -o /dev/null --http2 "https://localhost:8443/baseline2?a=1&b=1" 2>/dev/null; then
        break
    fi
    sleep 1
    [ "$i" -eq 30 ] && { echo "FAIL: server not ready"; exit 1; }
done
echo "      ready"

echo "[3/5] Starting load generator ($LOADGEN_IMG, 60s)..."
docker run -d --name "${APP_NAME}-load" --network host \
    "$LOADGEN_IMG" "${LOADGEN_ARGS[@]}" >/dev/null
sleep 5  # warmup before sampling

echo "[4/5] Capturing CPU trace (10s)..."
# `dotnet-sampled-thread-time` samples thread stacks at ~100 Hz and works
# under `collect` with just SYS_PTRACE. `collect-linux` would give true
# kernel cpu-sampling but requires tracefs which Docker doesn't expose.
#
# `--rundown false` is critical for the H3 case — by default dotnet-trace
# emits rundown events at session end so PerfView can resolve method
# names. Under H3 load, msquic's transport EventSources keep firing
# through the same EventPipe, so the rundown drain never completes and
# the session deadlocks. Skipping rundown gives up some method metadata
# but lets the trace actually finalize. CPU sample stacks (the load-
# bearing data) are unaffected.
docker exec "$APP_NAME" sh -c \
    "dotnet-trace collect -p 1 --profile dotnet-sampled-thread-time --duration 00:00:10 -o /tmp/cpu.nettrace --rundown false" \
    >/dev/null

echo "[5/5] Copying out + converting to speedscope..."
docker cp "$APP_NAME:/tmp/cpu.nettrace" "$OUT_DIR/$PROFILE.nettrace"
# `dotnet-trace convert` always appends `.speedscope.json` to whatever -o is.
docker exec "$APP_NAME" sh -c \
    "dotnet-trace convert /tmp/cpu.nettrace --format speedscope -o /tmp/cpu" \
    >/dev/null
docker cp "$APP_NAME:/tmp/cpu.speedscope.json" "$OUT_DIR/$PROFILE.speedscope.json"

# Print load generator summary so we know the bench was actually under load
echo ""
echo "── load generator summary ──"
docker logs "${APP_NAME}-load" 2>&1 | tail -25 || true

echo ""
echo "── trace files ──"
ls -lh "$OUT_DIR/$PROFILE.nettrace" "$OUT_DIR/$PROFILE.speedscope.json"
