#!/bin/bash
# leaks_analysis_ext.sh — EPP memory leak detector via pprof
#
# Captures heap and goroutine profiles at regular intervals during load,
# then produces a differential analysis report.
#
# Usage:
#   ./leaks_analysis_ext.sh [OPTIONS]
#
# Options:
#   -n NAMESPACE     Kubernetes namespace (default: $NAMESPACE env var)
#   -p EPP_POD       EPP pod name (default: auto-detect)
#   -i INTERVAL      Seconds between captures (default: 300)
#   -c COUNT         Number of captures (default: 12)
#   -o OUTPUT_DIR    Directory to store results (default: ./pprof_results)
#   -P LOCAL_PORT    Local port for port-forward (default: 9090)

set -euo pipefail

NAMESPACE="${NAMESPACE:-}"
EPP_POD=""
INTERVAL=300
COUNT=12
OUTPUT_DIR="./pprof_results"
LOCAL_PORT=9090
PF_PID=""

usage() {
    echo "Usage: $0 [-n NAMESPACE] [-p EPP_POD] [-i INTERVAL] [-c COUNT] [-o OUTPUT_DIR] [-P LOCAL_PORT]"
    exit 1
}

while getopts "n:p:i:c:o:P:h" opt; do
    case $opt in
        n) NAMESPACE="$OPTARG" ;;
        p) EPP_POD="$OPTARG" ;;
        i) INTERVAL="$OPTARG" ;;
        c) COUNT="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        P) LOCAL_PORT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$NAMESPACE" ]; then
    echo "ERROR: NAMESPACE not set. Use -n flag or export NAMESPACE."
    exit 1
fi

if ! command -v go &>/dev/null; then
    echo "ERROR: 'go' is not installed. Required for 'go tool pprof' analysis."
    exit 1
fi

if ! command -v kubectl &>/dev/null; then
    echo "ERROR: 'kubectl' is not installed."
    exit 1
fi

# Auto-detect EPP pod if not specified
if [ -z "$EPP_POD" ]; then
    EPP_POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=*epp* -o name 2>/dev/null | head -1 | sed 's|pod/||')
    if [ -z "$EPP_POD" ]; then
        EPP_POD=$(kubectl -n "$NAMESPACE" get pods -o name 2>/dev/null | grep epp | head -1 | sed 's|pod/||')
    fi
    if [ -z "$EPP_POD" ]; then
        echo "ERROR: Could not auto-detect EPP pod in namespace '$NAMESPACE'. Use -p flag."
        exit 1
    fi
    echo "Auto-detected EPP pod: $EPP_POD"
fi

ENDPOINT="localhost:${LOCAL_PORT}"
mkdir -p "$OUTPUT_DIR"

cleanup() {
    if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
        echo "Stopping port-forward (PID $PF_PID)..."
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Start port-forward
echo "Starting port-forward: pod/$EPP_POD port $LOCAL_PORT -> 9090"
kubectl -n "$NAMESPACE" port-forward "pod/$EPP_POD" "${LOCAL_PORT}:9090" &>/dev/null &
PF_PID=$!
sleep 2

# Verify pprof is accessible
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${ENDPOINT}/debug/pprof/heap")
if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: pprof endpoint returned HTTP $HTTP_CODE. Ensure metrics-endpoint-auth is disabled on the EPP."
    echo "Deploy with: inferenceExtension.flags.metrics-endpoint-auth=false"
    exit 1
fi
echo "pprof endpoint verified (HTTP 200)"

REPORT="$OUTPUT_DIR/leak_report.txt"
> "$REPORT"

echo "Starting leak analysis: $COUNT captures at ${INTERVAL}s intervals"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Initial warmup sleep
echo "Waiting ${INTERVAL}s for warmup before first capture..."
sleep "$INTERVAL"

FIRST_HEAP=""

for i in $(seq 1 "$COUNT"); do
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    HEAP_FILE="$OUTPUT_DIR/heap_${i}_${TIMESTAMP}.out"
    GOROUTINE_FILE="$OUTPUT_DIR/goroutine_${i}_${TIMESTAMP}.out"

    echo "Capturing profiles $i/$COUNT at $(date)"
    curl -s "http://${ENDPOINT}/debug/pprof/heap" > "$HEAP_FILE"
    curl -s "http://${ENDPOINT}/debug/pprof/goroutine" > "$GOROUTINE_FILE"

    if [ "$i" -eq 1 ]; then
        FIRST_HEAP="$HEAP_FILE"

        BASELINE_INUSE=$(go tool pprof -text "$FIRST_HEAP" 2>/dev/null | grep "Showing nodes accounting for" | awk '{print $8}')
        BASELINE_ALLOC=$(go tool pprof -sample_index=alloc_space -text "$FIRST_HEAP" 2>/dev/null | grep "Showing nodes accounting for" | awk '{print $8}')

        echo "========================================" >> "$REPORT"
        echo "BASELINE SNAPSHOT" >> "$REPORT"
        echo "========================================" >> "$REPORT"
        echo "Baseline heap file: $HEAP_FILE" >> "$REPORT"
        echo "Baseline memory in-use: $BASELINE_INUSE" >> "$REPORT"
        echo "Baseline total allocated: $BASELINE_ALLOC" >> "$REPORT"
        echo "Captured at: $(date)" >> "$REPORT"
        echo "" >> "$REPORT"
        echo "--- Baseline goroutine profile ---" >> "$REPORT"
        go tool pprof -text "$GOROUTINE_FILE" >> "$REPORT"
        echo "" >> "$REPORT"
        echo "========================================" >> "$REPORT"
        echo "" >> "$REPORT"
    else
        echo "=== Growth from snapshot 1 to $i ===" >> "$REPORT"
        echo "Current heap file: $HEAP_FILE" >> "$REPORT"
        echo "Current goroutine file: $GOROUTINE_FILE" >> "$REPORT"
        echo "" >> "$REPORT"
        echo "--- Differential analysis (growth since baseline) ---" >> "$REPORT"
        go tool pprof -base="$FIRST_HEAP" -text "$HEAP_FILE" >> "$REPORT"
        echo "" >> "$REPORT"
        echo "--- Current memory usage (absolute values) ---" >> "$REPORT"
        go tool pprof -text "$HEAP_FILE" >> "$REPORT"
        echo "" >> "$REPORT"
        echo "--- Goroutine profile ---" >> "$REPORT"
        go tool pprof -text "$GOROUTINE_FILE" >> "$REPORT"
        echo "" >> "$REPORT"
        echo "========================================" >> "$REPORT"
        echo "" >> "$REPORT"
    fi

    [ "$i" -lt "$COUNT" ] && sleep "$INTERVAL"
done

echo ""
echo "Analysis complete. Report: $REPORT"
echo "Profile files stored in: $OUTPUT_DIR"
