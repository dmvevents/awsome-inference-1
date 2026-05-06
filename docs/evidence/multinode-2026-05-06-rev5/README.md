# rev5 — Dynamo 1.1.0 validation on `dynamo-efa:9467d1460c71`

**STATUS: IN PROGRESS — populated during nemo2's validation run.**

Image: `058264135704.dkr.ecr.us-east-2.amazonaws.com/dynamo-efa:9467d1460c71`
Built from: commit `9467d14` on branch `feature/dynamo-combined-vllm-trtllm-efa`
CodeBuild ID: `dynamo-inference-public:4b18f907-8290-478a-abf5-e1cbe9685864`
Run date: `<YYYY-MM-DD HH:MM UTC>` → `<YYYY-MM-DD HH:MM UTC>`
Cluster: 2× p5.48xlarge H100 HyperPod (ip-10-1-3-30, ip-10-1-3-73)

## What changed from rev4

- `TRTLLM_IMAGE` bumped `nvcr.io/nvidia/ai-dynamo/tensorrtllm-runtime:1.0.1` → `:1.1.0` in `Dockerfile.dynamo-combined-efa`
- `VLLM_IMAGE` bumped `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1` → `:1.1.0`
- No changes to the rev3 canonical single-DGD layout
- No changes to the rev4 shared-`DYN_NAMESPACE` + empty `DYN_NAMESPACE_WORKER_SUFFIX` override

## Gate matrix

| Gate | Status | Evidence file |
|---|---|---|
| T1 — image present in ECR | TBD | `t1-ecr-describe.txt` |
| T2 — image size ≤ 24 GB | TBD | `t2-image-size.txt` |
| T3 — NCCL fat-binary sm_80..sm_120 | TBD | `t3-nccl-arches.txt` |
| T4 — EFA devices 96 in pod | TBD | `t4-fi-info.txt` |
| T5 — `/v1/models` 200 on opt-125m | TBD | `t5-models.log` |
| T6 — `/v1/completions` on opt-125m | TBD | `t6-completions.log` |
| T7 — RDMA hw_counters > 0 | TBD | `t7-hw-counters.txt` |
| T8 — no NCCL WARN | TBD | `t8-nccl-clean.log` |
| T9 — SBOM present | TBD | `t9-sbom-check.txt` |
| T10 — teardown ≤ 60 s | TBD | `t10-teardown.txt` |
| **T11** — 16-rank NCCL AllReduce cross-node | TBD | `t11-r0.log`, `t11-r1.log` |
| **T11b** — 8-GPU nccl-tests all_reduce_perf | TBD | `t11b-all-reduce-perf.log` |
| **T12a** — NIXL plugin load (no crash) | TBD | `t12-prefill-full.log`, `t12-decode-full.log` |
| **T12b** — `--kv-transfer-config` accepted | TBD | same logs |
| **T12c** — Worker + Frontend namespace alignment | TBD | `t12-dgds.txt`, `t12-kubediscovery.log` |
| **T12d — `/v1/completions` end-to-end on 1.1.0** | **THE KR 1.2 GATE** | `t12-completions.log` |

## T12d outcome (the critical one)

### If PASS

Next action: fire `pr72-rev5-PASS-draft.md` from gist `b1c8d9a376a12f3b0842c3c3fc335ffc` with the SHA, timing, and curl response filled in.

### If NO-GO (same `0 instances` symptom as rev4)

Next action: file upstream issue at `ai-dynamo/dynamo` using `ai-dynamo-upstream-issue-NOGO-draft.md` from the same gist. Then post a rev5-NOGO comment on PR #72 linking the upstream issue and framing 1.1.0 as "image side still green, upstream operator fix tracked."

## Artifacts to capture

```
docs/evidence/multinode-2026-05-06-rev5/
├── README.md                    — this file (populated with final status)
├── t1-ecr-describe.txt
├── t2-image-size.txt
├── t3-nccl-arches.txt
├── t4-fi-info.txt
├── t5-models.log
├── t6-completions.log
├── t7-hw-counters.txt
├── t8-nccl-clean.log
├── t9-sbom-check.txt
├── t10-teardown.txt
├── t11-r0.log
├── t11-r1.log
├── t11-torch-allreduce.py        — harness (copy from rev2)
├── t11b-all-reduce-perf.log
├── t12-prefill-full.log
├── t12-decode-full.log
├── t12-dgds.txt
├── t12-dgd-applied.yaml           — with HF token redacted
├── t12-pods.txt
├── t12-kubediscovery.log          — frontend's KubeDiscoveryClient output
└── t12-completions.log            — the T12d transcript (GO or NO-GO input)
```

## Constraints to honor (per CLAUDE.md + OKRs)

- H100 only (p5.48xlarge), do NOT touch P5en H200
- `~/.claude/cluster-lock-h100.json` held for the duration, released on completion
- `nvshmem-efa/deepep-nvshmem` scaled 2 → 0 for the run, restored to 2 on completion
- Image tag always explicit `9467d1460c71`, never `:latest`
- No edits to the rev4-era `DGD-dynamo-combined-vllm.yaml` namespace overrides — keep them so we're testing the runtime change in isolation

## Repro commands (for the next person)

```bash
# 1. Claim the H100 lock
python3 -c "
import json, datetime, uuid
p = '$HOME/.claude/cluster-lock-h100.json'
d = json.load(open(p))
d['holder'] = 'rev5-validation-' + str(uuid.uuid4())[:8]
d['claimed_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
d['purpose'] = 'rev5 — Dynamo 1.1.0 T12 validation'
d['timeout_minutes'] = 60
d['released_at'] = None
json.dump(d, open(p,'w'), indent=2)
print('claimed', d['holder'])
"

# 2. Scale nvshmem-efa to 0
kubectl scale -n nvshmem-efa statefulset deepep-nvshmem --replicas=0
kubectl wait --for=delete pod -n nvshmem-efa --all --timeout=120s

# 3. Apply the DGD with 9467d14 image
sed -i 's|dynamo-efa:a1725d43e5c0|dynamo-efa:9467d1460c71|g' \
    2.projects/dynamo-inference/k8s/dgd-dynamo-combined-vllm.yaml
kubectl apply -f 2.projects/dynamo-inference/k8s/dgd-dynamo-combined-vllm.yaml

# 4. Wait for pods ready
kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/part-of=dynamo-combined-vllm \
    --timeout=600s

# 5. The T12d test — THIS is the KR 1.2 gate
kubectl port-forward svc/dynamo-combined-vllm-frontend 8000:8000 &
FW_PID=$!
sleep 5

curl -s -X POST http://localhost:8000/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"Hello","max_tokens":20}' \
    | tee t12-completions.log

kill $FW_PID

# 6. Cleanup + restore
kubectl delete dgd dynamo-combined-vllm
kubectl scale -n nvshmem-efa statefulset deepep-nvshmem --replicas=2
python3 -c "
import json, datetime
p = '$HOME/.claude/cluster-lock-h100.json'
d = json.load(open(p))
d['holder'] = None
d['claimed_at'] = None
d['purpose'] = None
d['released_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
d['queue'] = []
json.dump(d, open(p,'w'), indent=2)
"
```
