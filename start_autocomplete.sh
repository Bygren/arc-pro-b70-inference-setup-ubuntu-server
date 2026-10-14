#!/usr/bin/env bash
# Qwen2.5-Coder-1.5B (Q8_0) — llama.cpp SYCL1 (Card 1, fallback SYCL0), port 8001
# Tailored for VS Code Continue Tab-Autocomplete (FIM)
source /opt/intel/oneapi/setvars.sh --force 2>/dev/null || true
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1
export GGML_SYCL_DISABLE_OPT=1
export ZES_ENABLE_SYSMAN=1

MODEL_FILE="/mnt/models/qwen2.5-coder-1.5b-instruct-q8_0.gguf"
if [[ ! -f "$MODEL_FILE" && -f "${HOME}/models/qwen2.5-coder-1.5b-instruct-q8_0.gguf" ]]; then
    MODEL_FILE="${HOME}/models/qwen2.5-coder-1.5b-instruct-q8_0.gguf"
fi

# Detect device: prefer SYCL1 on multi-GPU to avoid competing with Agent on SYCL0
DEVICE="SYCL1"
if ! /opt/llama.cpp/llama-sycl-build/bin/llama-server --list-devices 2>/dev/null | grep -q "SYCL1"; then
    DEVICE="SYCL0"
fi

exec /opt/llama.cpp/llama-sycl-build/bin/llama-server \
    --model "${MODEL_FILE}" \
    --device "${DEVICE}" \
    -ngl 999 \
    -c 4096 \
    --parallel 4 \
    --batch-size 1024 \
    --ubatch-size 256 \
    --defrag-thold 0.1 \
    -fa 0 \
    --host 0.0.0.0 --port 8001 \
    --alias qwen2.5-coder-1.5b \
    -t 1 \
    --no-warmup \
    --log-file /tmp/llama-autocomplete.log
