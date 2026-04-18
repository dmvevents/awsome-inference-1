#!/usr/bin/env bash
# dynamo-combined-efa backend selector
#
# DYNAMO_BACKEND=vllm   -> use the base vLLM runtime env (default)
# DYNAMO_BACKEND=trtllm -> switch PYTHONPATH/PATH to the /opt/trtllm overlay
#
# If DYNAMO_BACKEND is unset or unknown, default to vllm and log a warning.
set -euo pipefail

BACKEND="${DYNAMO_BACKEND:-vllm}"

case "$BACKEND" in
  vllm)
    # vLLM is the image's native Python environment. Nothing to remap.
    exec "$@"
    ;;
  trtllm)
    # TRT-LLM ships as a self-contained venv at /opt/trtllm-venv. Activate it
    # wholesale so its Python, tensorrt_llm, trtllm-serve, etc. all match the
    # versions that NVIDIA ships together.
    if [[ ! -x /opt/trtllm-venv/bin/python3 ]]; then
      echo "[entrypoint] ERROR: /opt/trtllm-venv/bin/python3 missing — image built incorrectly" >&2
      exit 2
    fi
    export VIRTUAL_ENV="/opt/trtllm-venv"
    export PATH="/opt/trtllm-venv/bin:${PATH}"
    # Drop any vLLM-venv PYTHONPATH leakage.
    unset PYTHONHOME
    exec "$@"
    ;;
  help|--help|-h|"")
    cat <<'HLP'
dynamo-combined-efa — runs NVIDIA Dynamo with either TRT-LLM or vLLM over EFA.

Usage:
  docker run ... -e DYNAMO_BACKEND=vllm   dynamo-combined-efa:v1 <cmd>
  docker run ... -e DYNAMO_BACKEND=trtllm dynamo-combined-efa:v1 <cmd>

Defaults to DYNAMO_BACKEND=vllm if unset.
HLP
    [[ "$BACKEND" == "" ]] && exit 0 || exit 0
    ;;
  *)
    echo "[entrypoint] ERROR: unknown DYNAMO_BACKEND='$BACKEND' (expected: vllm | trtllm)" >&2
    exit 2
    ;;
esac
