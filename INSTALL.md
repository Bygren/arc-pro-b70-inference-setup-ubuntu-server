# Installation and Configuration Guide: Intel Arc Pro B70 AI Coding Server

> 🇸🇪 **Svenska:** För en svensk version av denna installationsguide, se [INSTALL_SV.md](INSTALL_SV.md).

A comprehensive step-by-step guide to setting up a dedicated local AI coding server powered by the **Intel Arc Pro B70 (32GB VRAM)** and **Ubuntu Server 26.04 LTS (or 24.04 LTS)**, optimized for **VS Code with Continue**.

---

## Hardware Specification (Reference System)

* **GPU:** Intel Arc Pro B70 (32GB VRAM, Battlemage Xe2 architecture)
* **Processor (CPU):** AMD Ryzen 9 9900X (12 cores / 24 threads, 4.4 GHz base, 76MB cache)
* **Motherboard:** ASUS ROG Crosshair X870E Hero (PCIe 5.0)
* **Memory (RAM):** Kingston 64GB DDR5 6000MHz
* **Storage (SSD):** WD Black SN7100 1TB NVMe PCIe 4.0
* **Power Supply (PSU):** Phanteks 1000W Platinum
* **CPU Cooler:** be quiet! Pure Rock Pro 3 Black
* **Chassis:** Fractal Design North XL Black
* **Operating System:** Ubuntu Server 26.04 LTS (or 24.04 LTS)

> **Repository Background:** Maintained by [Bygren/arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Bygren/arc-pro-b70-inference-setup-ubuntu-server) (forked from [Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server)), integrating optimizations and 11 Xe2 performance patches from [Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes](https://github.com/Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes), native Intel oneAPI Base Toolkit support, Ubuntu 26.04 driver detection, and automated coding model provisioning for VS Code Continue.

---

## Model Architecture for Continue

The system runs two isolated `llama-server` instances accelerated by Intel's hardware-optimized **SYCL backend**:

| Role in Continue | Model | Quantization | Port | Device | VRAM | Function |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Agent / Chat / Edit** | **Qwen3-Coder 30B-A3B-Instruct** | Q4_K_M | `8000` | `SYCL0` | ~18.8 GB | Chatting, architectural reasoning, and in-place code editing (32K context) |
| **Tab Autocomplete** | **Qwen2.5-Coder-1.5B** | Q8_0 | `8001` | `SYCL0`* | ~1.6 GB | Ultra-low-latency line and block completion in real time (<15 ms per token) |

*\*On single-GPU systems (standard setup), both models run concurrently on `SYCL0` (18.8 + 1.6 = ~20.4 GB of the card's 32GB VRAM). On multi-GPU systems, autocomplete automatically offloads to GPU 1 (`SYCL1`) so that typing flow is never impacted by heavy agent tasks.*

---

## Step 1: Configure BIOS / UEFI (Required)

Before installing the OS and drivers, the motherboard BIOS must be configured so the CPU can address the full 32GB of graphics memory:

1. Power on the system and press `DEL` or `F2` to enter BIOS (ASUS ROG UEFI).
2. Configure the following settings:
   * **Above 4G Decoding:** `ENABLED`
   * **Resizable BAR (ReBAR):** `ENABLED`
   * **CSM (Compatibility Support Module):** `DISABLED` (Pure UEFI mode only)
   * **Primary Display:** Set to `PEG / PCIe Slot` (Prioritizes the Arc Pro B70 over Ryzen 9900X integrated graphics)
   * **PCIe Link Speed:** Set to `Gen 4` or `Gen 5` (or `Auto`)
3. Save changes and reboot (`F10`).

---

## Step 2: Clean Up Legacy AI Services & Drivers

> [!NOTE]
> **Clean Ubuntu Server 26.04:** If installing on a fresh Ubuntu installation, you can skip this step and proceed directly to **Step 3**.

If the system was previously configured with Ollama or Nvidia drivers, remove them to prevent port and driver conflicts:

```bash
# Stop and remove Ollama if previously installed
sudo systemctl stop ollama.service 2>/dev/null || true
sudo systemctl disable ollama.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/ollama.service
sudo systemctl daemon-reload

# Purge any legacy Nvidia drivers
sudo apt remove --purge '^nvidia-.*' -y 2>/dev/null || true
sudo apt autoremove -y

# Remove Docker Snap package if present (Snap blocks GPU access and ignores daemon.json)
if command -v snap &>/dev/null && snap list docker &>/dev/null; then
    sudo snap remove --purge docker
fi
```

---

## Step 3: Run the Automated Setup Script

All manual driver installations, oneAPI repository configurations, Docker subnet isolation, and compilation steps are consolidated into a single turnkey script.

### Clone the repository and execute:

```bash
# Clone the repository (HTTPS recommended for clean servers, or using your GitHub token)
git clone https://github.com/Bygren/arc-pro-b70-inference-setup-ubuntu-server.git
cd arc-pro-b70-inference-setup-ubuntu-server

# Grant execute permissions and run as root
chmod +x odin-b70-setup.sh
sudo ./odin-b70-setup.sh
```

### What the script automates:
1. **Linux Kernel 6.17+ & Drivers:** Installs the Intel Xe KMD driver, firmware, and Intel compute-runtime.
2. **Intel oneAPI Base Toolkit:** Installs the official DPC++ compiler (`icx`/`icpx`), oneMKL, and oneDNN.
3. **Mesa Detection for Ubuntu 26.04:** Utilizes Ubuntu 26.04's native, modern Mesa stack (avoiding broken third-party PPAs).
4. **Docker & Network Isolation:** Installs Docker CE and configures `/etc/docker/daemon.json` with `bip: 172.30.0.1/24` and address pool `172.30.0.0/16`, moving Docker's default bridge away from standard office/home LAN subnets (`172.17.0.0/16`).
5. **llama.cpp with 11 Xe2 Performance Patches:** Compiles `llama-server` with native SYCL acceleration for Battlemage (MoE MMVQ kernels, Xe2 warptiles, memory alignment fixes).
6. **Model Downloads:** Automatically downloads:
   * `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` to `/mnt/models`
   * `qwen2.5-coder-1.5b-instruct-q8_0.gguf` to `/mnt/models`
7. **Systemd Services:** Creates, registers, and starts `llama-agent.service` (port 8000) and `llama-autocomplete.service` (port 8001).
8. **Firewall (UFW):** Opens ports 22 (SSH), 80 (HTTP), 443 (HTTPS), 8000 (Agent), 8001 (Autocomplete), and 8765 (Inference Diagnostics).

---

## Step 4: Reboot the Server

Once the installation finishes, reboot the system to load the newly installed kernel and Intel Xe driver:

```bash
sudo reboot
```

---

## Step 5: Verify Hardware & Running Services

Log back into the server after reboot and check the operational status:

### 1. Quick system check via sysinfo
```bash
~/sysinfo.sh
```
*Provides an immediate dashboard showing your server IP, kernel version, GPU temperatures, Vulkan device enumeration, and endpoint health for Agent (port 8000) and Autocomplete (port 8001).*

### 2. Verify GPU Detection
```bash
# Verify B70 is enumerated on the PCIe bus
lspci -v | grep -i VGA
# Should output "Intel Corporation Battlemage G31" or device ID e223

# Verify the xe kernel module is loaded
lsmod | grep xe
```

### 3. Real-Time GPU Monitoring
```bash
# Interactive GPU monitor with VRAM, engine usage, and temperature (recommended):
nvtop

# Intel's official hardware engine monitor:
sudo intel_gpu_top

# Thermal and fan monitoring:
watch -n 1 sensors
```

### 4. Verify Systemd Services
```bash
# Check the Agent service (Qwen3-Coder)
sudo systemctl status llama-agent

# Check the Autocomplete service (Qwen2.5-Coder)
sudo systemctl status llama-autocomplete
```

### 5. Test API Endpoints via curl
```bash
# Test Agent completion endpoint (port 8000)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"Write a quick hello world in Python"}],"max_tokens":50}'

# Test Autocomplete completion endpoint (port 8001)
curl http://localhost:8001/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-1.5b","prompt":"def fibonacci(n):\n","max_tokens":30}'

# Test Inference Diagnostic HTTP status (port 8765)
curl -s http://localhost:8765/ | python3 -m json.tool
```

---

## Step 6: Configure Continue in VS Code

On your client development machine, open VS Code and configure Continue (`~/.continue/config.yaml` or `config.json`):

### Option A: Modern YAML Format (`~/.continue/config.yaml` — Recommended)

```yaml
name: Intel B70 Coding Server
version: 0.0.1
schema: v1

models:
  # 1. Primary Model for Chat, Edit, and Agent Reasoning
  - name: Qwen3-Coder 30B (Agent)
    provider: openai
    model: qwen3-coder-30b
    apiBase: http://<SERVER-IP>:8000/v1
    roles:
      - chat
      - edit
      - apply

  # 2. Ultra-fast Tab Autocomplete
  - name: Qwen2.5-Coder 1.5B (Autocomplete)
    provider: openai
    model: qwen2.5-coder-1.5b
    apiBase: http://<SERVER-IP>:8001/v1
    roles:
      - autocomplete
```

### Option B: Legacy JSON Format (`~/.continue/config.json`)

```json
{
  "models": [
    {
      "title": "Qwen3 Coder 30B (Agent)",
      "provider": "openai",
      "model": "qwen3-coder-30b",
      "apiBase": "http://<SERVER-IP>:8000/v1",
      "contextLength": 32768
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5 Coder 1.5B (Autocomplete)",
    "provider": "openai",
    "model": "qwen2.5-coder-1.5b",
    "apiBase": "http://<SERVER-IP>:8001/v1"
  },
  "allowAnonymousTelemetry": false
}
```

> **Tip:** Replace `<SERVER-IP>` with the local network IP address of your server (e.g., `http://172.17.20.189:8000/v1`), or `http://localhost:8000/v1` if running VS Code directly on the host.

---

## Manual Execution & Troubleshooting

If you prefer running server instances interactively in a terminal rather than as systemd services, helper scripts are installed in your home directory:

```bash
# Stop background services first
sudo systemctl stop llama-agent llama-autocomplete

# Start Agent manually (port 8000)
~/start_agent.sh

# Start Autocomplete manually in another terminal (port 8001)
~/start_autocomplete.sh
```

### Critical Flags and Environment Variables Explained:
* `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1`: Removes Level Zero's default memory restriction, allowing processes to allocate up to the full 32GB VRAM.
* `GGML_SYCL_DISABLE_OPT=1`: **Mandatory for MoE architectures (Qwen3).** Prevents runtime driver faults during slot initialization.
* `-fa 0`: Disables Flash Attention. SYCL Flash Attention is currently unstable on MoE on Battlemage; standard attention with the 11 Xe2 patches achieves optimal tok/s.
* `--defrag-thold 0.1`: Triggers KV-cache defragmentation when fragmentation exceeds 10%, keeping throughput stable during long development sessions.
* `-t 1`: Allocates 1 CPU offload thread. Additional threads cause queue contention across the PCIe/Xe2 bus on Battlemage, reducing throughput.
* `--device SYCL0`: Binds the process to the target Intel Arc Pro GPU device.

---

## How to Swap or Upgrade Models

Swapping models requires only three simple steps without reinstalling drivers or rebuilding `llama.cpp`.

Here is an example swapping the Agent model from **Qwen3-Coder 30B-A3B** to **Devstral Small 2 24B Instruct 2512** (by Mistral AI & All Hands AI, ~14.5 GB VRAM in Q4_K_M).

### Step 1: Download the new model to `/mnt/models`

Run this quick Python command to download the GGUF file via `huggingface_hub`:

```bash
python3 - << 'EOF'
from huggingface_hub import hf_hub_download

repo = "unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF"
filename = "Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf"
dest = "/mnt/models"

print(f"Downloading {filename} from {repo}...")
hf_hub_download(repo_id=repo, filename=filename, local_dir=dest)
print("Download complete!")
EOF
```

### Step 2: Update the Start Script (`~/start_agent.sh`)

Open the agent start script in an editor:

```bash
nano ~/start_agent.sh
```

Update the following values:
1. Point to the new model file:
   ```bash
   MODEL_FILE="/mnt/models/Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf"
   ```
2. Update the model alias:
   ```bash
   --alias devstral-small-24b
   ```

Save (`Ctrl+O`, `Enter`) and exit (`Ctrl+X`).

> **💡 Are new SYCL settings or recompilations required?**
>
> **No.** 
> 1. **Universal Engine:** The `llama-server` binary in `/opt/llama.cpp/llama-sycl-build/bin/llama-server` is built with oneAPI DPC++/SYCL and natively supports all standard GGUF architectures (Mistral, Devstral, Qwen, Llama, Gemma, etc.).
> 2. **Inherited SYCL Flags:** Because `~/start_agent.sh` already loads `source /opt/intel/oneapi/setvars.sh`, `--device SYCL0`, `-ngl 999`, and `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1`, the new model automatically leverages full SYCL acceleration.
> 3. **MoE vs Dense Models:**
>    - `GGML_SYCL_DISABLE_OPT=1`: Required for MoE models (like Qwen3). For dense models like Devstral, leaving this set is harmless.
>    - `--reasoning off`: Disables `<think>` reasoning tags in Qwen models; ignored by models that don't output reasoning blocks.

Restart the agent service:

```bash
sudo systemctl restart llama-agent
```

Verify service status and query the new model:

```bash
sudo systemctl status llama-agent

# Test the new model
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"devstral-small-24b","messages":[{"role":"user","content":"Hello Devstral!"}],"max_tokens":30}'
```

### Step 3: Update Continue Configuration in VS Code

In `~/.continue/config.yaml` or `config.json`, update the model name:

```yaml
models:
  - name: Devstral Small 2 24B (Agent)
    provider: openai
    model: devstral-small-24b
    apiBase: http://<SERVER-IP>:8000/v1
    roles:
      - chat
      - edit
      - apply
```

Your setup is ready! Continue now routes agent and editing requests to the new model while Qwen2.5-Coder 1.5B continues handling tab autocompletions in the background.
