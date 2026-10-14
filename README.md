# Intel Arc Pro B70 LLM Inference Server — Ubuntu Server Edition

> **Ubuntu Server 24.04 LTS / 26.04 LTS** install.
>
> **Note:** Maintained by [Bygren](https://github.com/Bygren/arc-pro-b70-inference-setup-ubuntu-server), based on [Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server). Adds Ubuntu 26.04 LTS compatibility, driver resilience, and script bugfixes.
>
> **Built-in Intel oneAPI & Xe2 Performance Patches:**
> This edition integrates **Intel oneAPI Base Toolkit** (`icx`/`icpx`, DPC++, oneMKL, oneDNN) and automatically compiles **llama.cpp with native SYCL and Vulkan backends**. It incorporates the **11 Battlemage Xe2 cherry-picked patches** directly from [Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes](https://github.com/Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes) (MoE MMVQ, Xe2 warptile, Q8_0 reorder fix, etc.) into the build so you get maximum tok/s and MoE stability out of the box without needing manual secondary patch steps.
>
> 📖 **Komplett installationsguide (steg-för-steg):**
> Se [INSTALL.md](INSTALL.md) för en utförlig manual med hårdvarureferens (Ryzen 9900X / X870E Hero / Arc Pro B70), BIOS-inställningar, automatiserad installation och Continue-konfiguration för VS Code.

Automated setup script for running LLM coding assistance and inference on Intel Arc Pro B70 GPU with llama.cpp SYCL — optimized for VS Code with Continue (Agent on port 8000, Autocomplete on port 8001).

## Repository Overview

| Component | Status | Details |
|---|---|---|
| **Installation Guide** | [INSTALL.md](INSTALL.md) | Steg-för-steg manual för BIOS, Ubuntu 26.04/24.04, modellsättning & Continue |
| **OS Support** | Ubuntu Server 24.04 LTS & 26.04 LTS | Dynamic repository handling, kernel 6.17+ verification, automated Mesa detection |
| **Intel oneAPI** | Built-in | Installs `intel-oneapi-compiler-dpcpp-cpp`, `intel-oneapi-mkl-devel`, `intel-oneapi-dnnl-devel` |
| **llama.cpp Engine** | Built-in (SYCL + Vulkan) | Pinned base with 11 Battlemage Xe2 cherry-picked patches from [Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes](https://github.com/Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes) |
| **Start Scripts & Systemd** | Included | Pre-configured `start_*.sh` and `llamacpp@.service` with optimal env vars (`GGML_SYCL_DISABLE_OPT=1`, etc.) |

## Hardware Specification

| Component | Spec |
|-----------|------|
| **GPU** | 1x Intel Arc Pro B70 (32GB VRAM, Battlemage Xe2, PCIe 5.0/4.0 x16) |
| **CPU** | AMD Ryzen 9 9900X (12c/24t, 4.4 GHz base / 5.6 GHz boost, 76MB cache) |
| **Motherboard** | ASUS ROG Crosshair X870E Hero (PCIe 5.0) |
| **RAM** | 64GB DDR5-6000MHz (Kingston Fury, dual-channel) |
| **Boot & Storage** | 1TB WD Black SN7100 NVMe PCIe 4.0 |
| **PSU** | Phanteks 1000W Platinum |
| **Cooler** | be quiet! Pure Rock Pro 3 Black |
| **Case** | Fractal Design North XL Svart |
| **OS** | Ubuntu Server 26.04 LTS (or 24.04 LTS), kernel 6.17+ |

> **Single-GPU Capacity:** A single Intel Arc Pro B70 card with 32GB VRAM easily hosts both the **Qwen3-Coder 30B-A3B Agent** (~18.8 GB) and **Qwen2.5-Coder 1.5B Autocomplete** (~1.6 GB) simultaneously on `SYCL0` (~20.4 GB combined), leaving over 11 GB of VRAM headroom for 32K context and KV-cache. Multi-GPU systems are also supported out-of-the-box (autocomplete automatically offloads to Card 1 / `SYCL1`).

### BIOS Settings (Required)
- Above 4G Decoding: **ENABLED**
- Resizable BAR (ReBAR): **ENABLED**
- CSM (Compatibility Support Module): **DISABLED** (pure UEFI only)
- Primary Display: **PEG / PCIe Slot** (prioritize Arc Pro B70 over Ryzen 9900X integrated graphics)
- PCIe Link Speed: **Gen 4 / Gen 5**

## Model Layout (VS Code Continue Edition)

Two dedicated llama.cpp SYCL servers tailored for developer workflows in VS Code with the Continue extension:

| Port | Role | Model | Quant | Device | VRAM | Context | Purpose |
|------|------|-------|-------|--------|------|---------|---------|
| **8000** | **Agent** | Qwen3-Coder 30B-A3B-Instruct | Q4_K_M | SYCL0 (Card 0) | ~18.8 GB | 32768 | Chat, inline code edits, repo-level agent reasoning |
| **8001** | **Autocomplete** | Qwen2.5-Coder 1.5B | Q8_0 | SYCL1 (Card 1) | ~1.6 GB | 4096 | Low-latency FIM (Fill-in-the-Middle) tab-completion |

> **Single-GPU note:** If your system has 1x B70 card (32GB VRAM), both models run simultaneously on `SYCL0` (~20.5 GB total VRAM), leaving plenty of room for KV cache. On multi-GPU configurations, the autocomplete engine runs on `SYCL1` so background typing never contends with agent code generation.

## Performance

Benchmarks on Intel Arc Pro B70 with Xe2 Battlemage optimizations:

| Model | Port | Latency / tok/s | Role |
|-------|------|-----------------|------|
| **Qwen3-Coder 30B-A3B-Instruct** (Q4_K_M) | 8000 | ~45–65 tok/s | Instantaneous agent tool-calls & coding |
| **Qwen2.5-Coder 1.5B** (Q8_0) | 8001 | ~12–18 ms/tok (>60 tok/s) | Real-time tab autocomplete while typing |

> **Memory efficiency:** Both models run entirely in the GPU's 32GB VRAM (~20.4 GB combined), with the host system running AMD Ryzen 9 9900X and 64GB DDR5-6000 RAM. No model weights or KV caches spill into system RAM swap, eliminating the classic swap bottleneck and ensuring consistent, low-jitter tok/s performance across long programming sessions.

## Quick Start

There are two ways to bring up a fresh machine:

### Option A — Bootable USB (recommended for clean hardware)

Builds an Ubuntu Server (24.04 or 26.04 LTS) autoinstall USB that lays down the OS and runs
the full stack setup automatically on first boot. No manual steps after disk
selection.

```bash
# On any Linux box or WSL — install build deps once
sudo apt-get install -y xorriso p7zip-full wget

# Clone and build the ISO (downloads Ubuntu ISO ~3 GB on first run)
git clone git@github.com:Bygren/arc-pro-b70-inference-setup-ubuntu-server.git
cd arc-pro-b70-inference-setup-ubuntu-server
bash build_iso.sh          # Default: Ubuntu 24.04.2
# or for Ubuntu 26.04 LTS:
# bash build_iso.sh 26.04

# Output: arc-pro-b70-autoinstall.iso (~3 GB)
# Write to USB with Rufus (DD mode), Balena Etcher, or:
sudo dd if=arc-pro-b70-autoinstall.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**On the target machine:**
1. Boot from USB and select **"Install Intel Arc Pro B70 Inference Server (autoinstall)"** (default, 10s timeout)
2. Installer runs unattended but **pauses on storage** so you confirm the target disk (protection against wiping the wrong machine)
3. Reboots into Ubuntu — login as `user` / `changeme`
4. `prob70-firstboot.service` automatically runs `odin-b70-setup.sh`
5. Watch progress: `sudo journalctl -fu prob70-firstboot`

The first-boot service is idempotent — it touches `/var/lib/prob70/installed` on success and won't re-run on subsequent boots. Total time from USB boot to working inference endpoints: ~30-60 minutes (llama.cpp SYCL build is faster than the old vLLM source build).

### Option B — Manual install on existing Ubuntu

```bash
# Download
wget https://raw.githubusercontent.com/Bygren/arc-pro-b70-inference-setup-ubuntu-server/master/odin-b70-setup.sh
chmod +x odin-b70-setup.sh

# Run (takes 20-40 minutes — builds llama.cpp with SYCL backend)
sudo ./odin-b70-setup.sh

# Reboot (required for new kernel)
sudo reboot

# Start Continue inference servers (or let systemd manage them)
sudo systemctl status llama-agent         # Port 8000
sudo systemctl status llama-autocomplete  # Port 8001

# Manual start (if running interactively):
~/start_agent.sh &
~/start_autocomplete.sh &

# Test Agent endpoint
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"Write a python quicksort"}],"max_tokens":100}'

# Test Autocomplete endpoint
curl http://localhost:8001/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-1.5b","prompt":"def fibonacci(n):\n","max_tokens":50}'
```

## VS Code Continue Configuration

In VS Code with the [Continue](https://continue.dev) extension, open `~/.continue/config.json` (or `config.yaml`) and configure:

```json
{
  "models": [
    {
      "title": "Qwen3-Coder 30B-A3B (Agent)",
      "provider": "openai",
      "model": "qwen3-coder-30b",
      "apiBase": "http://<SERVER_IP>:8000/v1",
      "contextLength": 32768
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5-Coder 1.5B (Autocomplete)",
    "provider": "openai",
    "model": "qwen2.5-coder-1.5b",
    "apiBase": "http://<SERVER_IP>:8001/v1"
  }
}
```

## What the Script Installs

1. **Kernel 6.17+** — Required for the `xe` driver to recognize Battlemage GPUs
2. **Intel compute-runtime & IGC** — Stable Intel GPU runtime stack
3. **Intel oneAPI Base Toolkit** — DPC++ (`icx`/`icpx`), oneMKL, oneDNN, Level Zero
4. **llama.cpp (SYCL backend, with 11 Xe2 patches)** — Native SYCL with Battlemage optimizations (MoE MMVQ, Xe2 warptiles, Q8_0 reorder fix)
5. **Qwen3-Coder 30B-A3B-Instruct (Q4_K_M)** — High-capability coding model for Agent, Chat, and edit tasks (~18.8 GB VRAM)
6. **Qwen2.5-Coder 1.5B (Q8_0)** — Ultra low-latency model for instant tab autocomplete (~1.6 GB VRAM)
7. **Systemd services** — `llama-agent.service` and `llama-autocomplete.service` auto-started on boot
8. **xpu-smi & GPU Thermal Watchdog** — Continuous temperature and health monitoring

## Architecture

```
  ┌──────────────────────────────────────────────────────────┐
  │               Ubuntu 26.04 / 24.04 Server                │
  │            (AMD Ryzen 9 9900X + 64GB DDR5)               │
  │                                                          │
  │  Port 8000 (Agent / Chat)        Port 8001 (Autocomplete)│
  │  llama-server (SYCL)             llama-server (SYCL)     │
  │  Qwen3-Coder 30B-A3B (Q4_K_M)    Qwen2.5-Coder 1.5B (Q8) │
  │  ~18.8 GB VRAM                   ~1.6 GB VRAM            │
  │  ┌─────────────────────────────────────────────────────┐ │
  │  │         Intel Arc Pro B70 GPU (Device: SYCL0)       │ │
  │  │         32GB VRAM — PCIe 5.0 / 4.0 x16              │ │
  │  │         (~20.4 GB used / 11.6 GB free headroom)     │ │
  │  └─────────────────────────────────────────────────────┘ │
  │  *(Multi-GPU setups: Autocomplete offloads to SYCL1)     │
  └──────────────────────────────────────────────────────────┘
                           │
               Ports 8000 (Agent) & 8001 (Autocomplete)
                           │
          ┌────────────────────────────────┐
          │  VS Code (Continue Extension)  │
          │  Developer Workstation         │
          └────────────────────────────────┘
```

Both endpoints expose standard OpenAI-compatible `/v1/chat/completions` and `/v1/completions` endpoints.

## Key Technical Details

### Why llama.cpp SYCL Instead of vLLM?

vLLM XPU requires `--enforce-eager` (no CUDA graphs on Intel XPU) and a `--privileged` Docker container for oneCCL inter-GPU communication. At 4x TP=4, vLLM was bottlenecked by the host-side scheduler and oneCCL USM traffic through system RAM — the reason the 16GB swap benchmark produced only 5.7 tok/s single.

llama.cpp SYCL sidesteps all of this:
- No Docker, no container overhead, runs directly on the host
- No inter-GPU communication bottlenecks — each process manages its device context directly
- No Python scheduler — C++ server with minimal latency
- Each `llama-server` process pins to `--device SYCL0` (or `SYCL1` in multi-GPU configurations)

For code assistance, Qwen3-Coder 30B-A3B (MoE, ~18.8 GB) and Qwen2.5-Coder 1.5B (~1.6 GB) fit comfortably on a single 32GB Arc Pro B70 card with plenty of room for 32K context.

### Critical llama.cpp SYCL Flags

| Flag | Value | Why |
|------|-------|-----|
| `--device` | `SYCL0` | Pins server to the B70 GPU (or `SYCL1` for autocomplete on multi-GPU) |
| `-ngl 999` | — | Offload all layers to GPU VRAM (no CPU fallback) |
| `-c` | `32768` (Agent) / `4096` (Autocomplete) | 32K context for agent, 4K for autocomplete |
| `--parallel` | `2` (Agent) / `4` (Autocomplete) | Simultaneous requests (autocomplete handles rapid typing bursts) |
| `--batch-size` | `2048` | KV cache fill batch — tuned for B70 XMX engines |
| `--ubatch-size` | `512` | Micro-batch for prompt processing |
| `--defrag-thold` | `0.1` | KV cache defrag at 10% fragmentation (maintains tok/s over long sessions) |
| `-fa 0` | — | Disables flash attention (avoids MoE crashes on current Xe2 SYCL compiler) |
| `-t` | `1` | One CPU decode thread (GPU-bound; extra threads create PCIe queue contention) |
| `--no-warmup` | — | Skip warmup inference on start (instant server readiness) |
| `--reasoning off` | — | Qwen3-Coder: direct instruct mode without `<think>` output tags |

### Critical Environment Variables

| Variable | Value | Why |
|----------|-------|-----|
| `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS` | `1` | Required: Allows SYCL USM allocations up to the full 32GB VRAM |
| `GGML_SYCL_DISABLE_OPT` | `1` | **Mandatory for Qwen3-Coder MoE:** Prevents slot-initialization crash |
| `ZES_ENABLE_SYSMAN` | `1` | Required for xpu-smi / sysman power, frequency, and temperature monitoring |
| `SYCL_CACHE_PERSISTENT` | `0` | Disables stale JIT kernel cache between driver and compiler updates |

### Memory & System Performance

With 64GB DDR5-6000 RAM and an AMD Ryzen 9 9900X CPU, all scheduler and tokenization operations run with high DDR5 memory bandwidth (~80–90 GB/s). Both models remain 100% resident in the GPU's 32GB VRAM (~20.4 GB combined), completely avoiding system swap.

### GPU Thermal Monitoring

The script installs a systemd thermal watchdog (`gpu-thermal-watchdog.service`) that monitors all B70 GPUs every 30 seconds. If any GPU package or VRAM temperature reaches 90°C, it automatically stops inference servers for thermal protection.

Observed temperatures under sustained load:
- Idle: 52-58°C package, 56-62°C VRAM
- Under load (2 parallel slots): 63-71°C package, 64-74°C VRAM
- Throttle point: ~95°C
- Thermal shutdown: ~110°C

```bash
# Check temperatures
sensors | grep -A3 'xe-pci'

# Check watchdog status
sudo systemctl status gpu-thermal-watchdog

# Check thermal log
cat /var/log/gpu_thermal.log
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| GPU not detected in `lspci` | Enable Above 4G Decoding + ReBAR in BIOS, set Primary Display to PEG/PCIe, disable CSM |
| `xe` driver not loading | Requires kernel 6.17+. Check with `lsmod \| grep xe` and verify `uname -r` |
| `FATAL: Unknown device: deviceId: e223` | Compute-runtime too old. Ensure v25.48+ / v26.09+ is installed |
| llama.cpp SYCL `SYCL device not found` | Source oneAPI environment: `source /opt/intel/oneapi/setvars.sh` |
| llama.cpp can't allocate full 32GB VRAM | Ensure `export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1` is set |
| Qwen3-Coder crashes at slot init | **MoE safety:** Ensure `export GGML_SYCL_DISABLE_OPT=1` is exported in startup script |
| Flash Attention causes crash | Disable Flash Attention with `-fa 0` (standard attention is accelerated via Xe2 kernels) |
| Continue cannot connect from VS Code | Verify UFW firewall (`sudo ufw allow 8000/tcp && sudo ufw allow 8001/tcp`) and check service status (`systemctl status llama-agent`) |
| Thermal watchdog triggers shutdown | Check chassis airflow and fan curves; inspect temps via `sensors \| grep -A3 'xe-pci'` |

## Credits

- [Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server) — Original Ubuntu server inference setup
- [Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes](https://github.com/Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes) — Battlemage Xe2 patches & performance tuning kit
- [Level1Techs](https://forum.level1techs.com/t/intel-b70-launch-unboxed-and-tested/247873) — Intel Arc Pro B70 testing & benchmarks
- [vLLM Intel Arc Pro B-Series Blog](https://vllm.ai/blog/intel-arc-pro-b) — Intel's XPU architectural guidance
- [intel/compute-runtime](https://github.com/intel/compute-runtime) — Intel GPU drivers & runtime
- [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) — llama.cpp engine & SYCL backend

## License

MIT
