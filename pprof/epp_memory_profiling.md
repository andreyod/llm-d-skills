
### EPP Memory Leak Detection via pprof

#### Prerequisites

Deploy the EPP with pprof enabled and metrics authentication disabled. Add these helm values:

```yaml
inferenceExtension:
  flags:
    metrics-endpoint-auth: "false"
    secure-serving: "false"
```

Example helm upgrade:
```bash
helm -n $NAMESPACE upgrade <release-name> <chart> \
  --reuse-values \
  --set 'inferenceExtension.flags.metrics-endpoint-auth=false' \
  --set 'inferenceExtension.flags.secure-serving=false'
```

Required local tools: `kubectl`, `curl`, `go` (for `go tool pprof`)

#### Run leak detection

a) Verify pprof is accessible via port-forward:
```bash
kubectl -n $NAMESPACE port-forward pod/<EPP_POD> 9090 &
curl -s -o /dev/null -w "%{http_code}" localhost:9090/debug/pprof/heap
# Should return 200
```

b) Run the leak analysis script:
```bash
./leaks_analysis_ext.sh -n $NAMESPACE -p <EPP_POD> -i 300 -c 12 -o ./pprof_results
```

Options:
- `-n` — Kubernetes namespace
- `-p` — EPP pod name (auto-detected if omitted)
- `-i` — interval between captures in seconds (default: 300)
- `-c` — number of captures (default: 12)
- `-o` — output directory (default: ./pprof_results)
- `-P` — local port for port-forward (default: 9090)

c) Start the benchmark run to produce load. Use the `run-llm-d-benchmark` skill or `run_only.sh` with `inference-perf` harness.

d) After completion, review `pprof_results/leak_report.txt` for memory growth patterns.
