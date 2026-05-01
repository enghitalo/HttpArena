#!/usr/bin/env bash
# scripts/perf-trace.sh — host-side `perf record` against aspnet-minimal.
#
# Bypasses dotnet-trace / EventPipe entirely (which deadlocks under H3
# load because msquic floods the same diagnostic pipe). Linux perf
# samples via the kernel and can't be blocked by the runtime.
#
# Output:
#   traces/<profile>.perf.data        — raw perf.data (binary)
#   traces/<profile>.perf.folded.txt  — folded stacks (speedscope.app accepts)
#
# Usage:
#   ./scripts/perf-trace.sh baseline-h2
#   ./scripts/perf-trace.sh baseline-h3
#
# Requires sudo (perf_event_paranoid=4 on this host). You'll be prompted
# for your password when perf record / perf script fire.
#
# Notes:
#  - The container runs with --pid=host so dotnet's PID inside the container
#    matches the host PID — important because DOTNET_PerfMapEnabled writes
#    /tmp/perf-<PID>.map using the runtime's view of its own PID. perf on
#    the host wants the file at /tmp/perf-<host-PID>.map.
#  - Host /tmp is bind-mounted into the container at /tmp so the perf map
#    lands directly on the host where perf can resolve it.

set -euo pipefail

PROFILE="${1:-baseline-h2}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/traces"
mkdir -p "$OUT_DIR"

APP_IMG=httparena-aspnet-minimal
APP_NAME=httparena-perf-app
H2LOAD_IMG=h2load:latest
H2LOAD_H3_IMG=h2load-h3:local

case "$PROFILE" in
    baseline-h2)
        LOADGEN_IMG="$H2LOAD_IMG"
        # c=256 m=100 — the lower of the two canonical baseline-h2 conn
        # counts (the 1024 setting overflows h2load's internal client
        # tracking when kestrel can't accept fast enough alongside the
        # perf attach, asserting and starving the framework).
        LOADGEN_ARGS=("https://localhost:8443/baseline2?a=1&b=1" -c 256 -m 100 -t 32 -D 60s)
        ;;
    baseline-h3)
        LOADGEN_IMG="$H2LOAD_H3_IMG"
        LOADGEN_ARGS=(--alpn-list=h3 "https://localhost:8443/baseline2?a=1&b=1" -c 64 -m 64 -t 64 -D 60s)
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

echo "[1/6] Starting aspnet-minimal..."
# No --pid=host — that broke load gen (msquic/kestrel startup observed
# host PID-1 != dotnet, leading to "client could not connect" floods).
# Instead we leave the container in its own PID namespace (dotnet is
# PID 1 inside), DOTNET_PerfMapEnabled writes /tmp/perf-1.map, and we
# copy that file to host /tmp/perf-<HOST_PID>.map below — what perf
# script wants.
docker run -d --name "$APP_NAME" \
    --network host \
    --cap-add SYS_PTRACE \
    --security-opt seccomp=unconfined \
    -v "$ROOT_DIR/certs:/certs:ro" \
    "$APP_IMG" >/dev/null

echo "[2/6] Waiting for server ready..."
for i in $(seq 1 30); do
    if curl -sk --max-time 2 -o /dev/null --http2 "https://localhost:8443/baseline2?a=1&b=1" 2>/dev/null; then
        break
    fi
    sleep 1
    [ "$i" -eq 30 ] && { echo "FAIL: server not ready"; exit 1; }
done

# Host PID of the dotnet process. Container's namespaced PID for dotnet
# is 1; perf records using host PID, so we'll rename the map below.
DOTNET_PID=$(docker inspect -f '{{.State.Pid}}' "$APP_NAME")
echo "      ready, dotnet host PID = $DOTNET_PID (container PID = 1)"

echo "[3/6] Starting load generator ($LOADGEN_IMG, 60s)..."
docker run -d --name "${APP_NAME}-load" --network host \
    "$LOADGEN_IMG" "${LOADGEN_ARGS[@]}" >/dev/null
sleep 5

echo "[4/6] Recording perf data (15s, 99 Hz, with stacks)..."
# --call-graph fp uses frame-pointer unwinding (cheap, ~no overhead vs
# dwarf which can drop 90%+ of samples on a busy process). .NET emits
# FP-walkable frames so this resolves managed callstacks correctly when
# combined with the perf-PID.map produced by DOTNET_PerfMapEnabled=1.
PERF_DATA="$OUT_DIR/$PROFILE.perf.data"
sudo perf record -F 99 -p "$DOTNET_PID" --call-graph fp \
    -o "$PERF_DATA" -- sleep 15

echo "[5/6] Pulling perf map + folding stacks..."
# .NET wrote /tmp/perf-1.map inside the container (it's PID 1 there).
# perf script on the host wants /tmp/perf-<HOST_PID>.map. Copy + rename.
sudo docker cp "$APP_NAME:/tmp/perf-1.map" "/tmp/perf-${DOTNET_PID}.map" 2>/dev/null && \
    sudo chown "$USER:$USER" "/tmp/perf-${DOTNET_PID}.map" || \
    echo "  (no perf map produced — managed frames will show as anon)"
PERF_FOLDED="$OUT_DIR/$PROFILE.perf.folded.txt"
sudo perf script -i "$PERF_DATA" > "$PERF_FOLDED"
sudo chown "$USER:$USER" "$PERF_DATA" "$PERF_FOLDED"

echo "[6/6] Load generator summary:"
docker logs "${APP_NAME}-load" 2>&1 | tail -20 || true

echo ""
echo "── output ──"
ls -lh "$PERF_DATA" "$PERF_FOLDED"
echo ""
echo "Drag $PROFILE.perf.folded.txt onto https://www.speedscope.app/"
echo "Or open the .perf.data with: perf report -i $PERF_DATA"
