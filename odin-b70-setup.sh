#!/usr/bin/env bash
# =============================================================================
# Intel B70 Inference Server — Automated Setup Script v1.7.0
# VS Code Continue Coding Edition (Qwen3-Coder 30B-A3B + Qwen2.5-Coder 1.5B)
#
# Sets up Intel Arc Pro B70 GPUs for LLM coding & inference with:
#   1. llama.cpp SYCL backend (Intel oneAPI DPC++/SYCL + 11 B70 Xe2 patches)
#   2. VS Code Continue Agent: Qwen3-Coder 30B-A3B-Instruct (Q4_K_M) on port 8000
#   3. VS Code Continue Autocomplete: Qwen2.5-Coder-1.5B (Q8_0) on port 8001
#   4. Optional vLLM multi-GPU tensor parallelism inside Docker
# Tested on Ubuntu Server 24.04 LTS and 26.04 LTS with 1x, 2x and 4x B70 configurations.
#
# Hardware requirements:
#   - 1-4x Intel Arc Pro B70 GPUs (32GB VRAM each)
#   - 64GB+ system RAM (128GB recommended)
#   - PCIe x16 slots (Gen 3.0+ works, Gen 5.0 optimal)
#   - Ubuntu Server 24.04 LTS or 26.04 LTS
#
# BIOS requirements (must be set manually before running this script):
#   - Above 4G Decoding: ENABLED
#   - Resizable BAR: ENABLED
#   - CSM: DISABLED (UEFI boot only)
#
# Usage:
#   chmod +x odin-b70-setup.sh
#   sudo ./odin-b70-setup.sh
#
# After running, reboot and then:
#   systemctl status llama-agent         # Status of Qwen3-Coder Agent (port 8000)
#   systemctl status llama-autocomplete  # Status of Qwen2.5-Coder Autocomplete (port 8001)
#   ~/start_agent.sh                     # Manual start for Agent
#   ~/start_autocomplete.sh              # Manual start for Autocomplete
# =============================================================================
set -euo pipefail

SCRIPT_VERSION="1.7.0"
LOG="/var/log/odin-b70-setup.log"

# --- Configuration (edit these) ---
AGENT_MODEL_REPO="unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
AGENT_MODEL_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
AGENT_PORT=8000

AUTOCOMPLETE_MODEL_REPO="Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF"
AUTOCOMPLETE_MODEL_FILE="qwen2.5-coder-1.5b-instruct-q8_0.gguf"
AUTOCOMPLETE_PORT=8001

BUILD_VLLM="${BUILD_VLLM:-false}"                 # Set to true to build vLLM Docker image from source
VLLM_PORT="${VLLM_PORT:-8080}"                   # Port for optional vLLM server
LLAMACPP_PORT="${LLAMACPP_PORT:-8082}"           # Port for optional fallback Vulkan server
VLLM_MODEL_NAME="${VLLM_MODEL_NAME:-gemma-4-26b-a4b}"
MODEL_LOCAL_NAME="${MODEL_LOCAL_NAME:-gemma-4-26B-A4B-it}"
KERNEL_VERSION="6.17.0-20-generic"              # Minimum kernel for B70
COMPUTE_RUNTIME_VERSION="25.48.36300.8"         # Stable for BMG (do not upgrade)
IGC_VERSION="v2.24.8"                           # Paired with 25.48 (do not upgrade)
VLLM_DOCKER_IMAGE="vllm-xpu:gemma4-fixed"
# ----------------------------------

touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "================================================================"
echo "Intel B70 Inference Server Setup v${SCRIPT_VERSION} — $(date)"
echo "================================================================"

# -----------------------------------------------------------
# 0. Sanity checks
# -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo ./odin-b70-setup.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    echo "ERROR: Do not run as root directly. Use: sudo ./odin-b70-setup.sh"
    echo "       The script needs SUDO_USER to identify your non-root account."
    exit 1
fi

REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
    echo "ERROR: Could not determine home directory for user '${REAL_USER}'"
    exit 1
fi

echo "User: ${REAL_USER} | Home: ${REAL_HOME}"

# Detect and validate OS release
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="${NAME:-Ubuntu}"
    OS_VERSION="${VERSION_ID:-}"
    OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
else
    echo "WARNING: /etc/os-release not found. Assuming Ubuntu 24.04 LTS."
    OS_NAME="Ubuntu"
    OS_VERSION="24.04"
    OS_CODENAME="noble"
fi

echo "OS:   ${OS_NAME} ${OS_VERSION} (${OS_CODENAME})"
if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"ubuntu"* ]]; then
    echo "WARNING: This script is intended for Ubuntu Server (24.04 or 26.04 LTS)."
    echo "         Detected: ${ID:-unknown}"
fi
echo ""

# Check for B70 GPUs
B70_COUNT=$(lspci | grep -c "Intel.*e223" 2>/dev/null || echo 0)
if [[ "$B70_COUNT" -eq 0 ]]; then
    echo "WARNING: No Intel Arc Pro B70 GPUs detected (device e223)."
    echo "         Make sure BIOS has Above 4G Decoding and ReBAR enabled."
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
else
    echo "Detected ${B70_COUNT}x Intel Arc Pro B70 GPU(s)"
fi

echo ""
NEED_REBOOT=false

# -----------------------------------------------------------
# 1. System update & essential packages
# -----------------------------------------------------------
echo ">>> [1/11] System update & essentials"

# Clean up legacy AI services or conflicting PPAs from prior experiments
if systemctl list-unit-files ollama.service &>/dev/null || [[ -f /etc/systemd/system/ollama.service ]]; then
    echo "    Cleaning up legacy Ollama service..."
    systemctl stop ollama.service 2>/dev/null || true
    systemctl disable ollama.service 2>/dev/null || true
    rm -f /etc/systemd/system/ollama.service
    systemctl daemon-reload
fi

# Remove Kobuk team PPA if present (can conflict with pinned Intel BMG driver packages)
if ls /etc/apt/sources.list.d/*kobuk* &>/dev/null; then
    echo "    Removing conflicting kobuk-team/intel-graphics PPA..."
    rm -f /etc/apt/sources.list.d/*kobuk* 2>/dev/null || true
fi

add-apt-repository -y universe 2>/dev/null || true
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential cmake ninja-build patch git curl wget \
    htop lm-sensors intel-gpu-tools nvtop \
    pkg-config libssl-dev \
    software-properties-common \
    ca-certificates gpg \
    python3 python3-pip python3-venv \
    unzip pciutils lshw numactl \
    clinfo glslang-tools glslc \
    vulkan-tools libvulkan-dev libvulkan1 \
    mesa-vulkan-drivers
echo "    Done."

# -----------------------------------------------------------
# 2. Install kernel 6.17+ (Battlemage xe driver support)
# -----------------------------------------------------------
echo ""
echo ">>> [2/11] Kernel 6.17+ for Battlemage xe driver"

CURRENT_KERNEL=$(uname -r)
CURRENT_MAJOR=$(echo "$CURRENT_KERNEL" | cut -d. -f1)
CURRENT_MINOR=$(echo "$CURRENT_KERNEL" | cut -d. -f2)

if [[ "$CURRENT_MAJOR" -lt 6 ]] || [[ "$CURRENT_MAJOR" -eq 6 && "$CURRENT_MINOR" -lt 17 ]]; then
    echo "    Current kernel: ${CURRENT_KERNEL} (too old for B70)"
    echo "    Installing kernel ${KERNEL_VERSION}..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "linux-image-${KERNEL_VERSION}" \
        "linux-modules-${KERNEL_VERSION}" \
        "linux-modules-extra-${KERNEL_VERSION}" 2>/dev/null || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "linux-image-unsigned-${KERNEL_VERSION}" \
        "linux-modules-${KERNEL_VERSION}" \
        "linux-modules-extra-${KERNEL_VERSION}" 2>/dev/null || {
            echo "    WARNING: Could not install kernel ${KERNEL_VERSION}."
            echo "    Searching for latest 6.17+ kernel..."
            KERNEL_VERSION=$(apt-cache search linux-image | grep -E "linux-image-((6\.(1[7-9]|[2-9][0-9]))|([7-9]\.[0-9]+)).*generic" | grep -v unsigned | grep -v dbg | sort -V | tail -1 | awk '{print $1}' | sed 's/linux-image-//')
            if [[ -n "$KERNEL_VERSION" ]]; then
                echo "    Found: ${KERNEL_VERSION}"
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    "linux-image-${KERNEL_VERSION}" \
                    "linux-modules-${KERNEL_VERSION}" \
                    "linux-modules-extra-${KERNEL_VERSION}"
            else
                echo "    ERROR: No 6.17+ kernel found. Add the HWE PPA or install manually."
                exit 1
            fi
        }
    NEED_REBOOT=true
else
    echo "    Current kernel: ${CURRENT_KERNEL} (OK)"
fi

# Set GRUB parameters
if ! grep -q "iommu=pt" /etc/default/grub; then
    cp /etc/default/grub /etc/default/grub.bak
    # Restore backup on failure
    trap 'cp /etc/default/grub.bak /etc/default/grub 2>/dev/null; echo "GRUB restored from backup"' ERR
    CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//;s/"$//')
    NEW_CMDLINE="${CURRENT_CMDLINE:+$CURRENT_CMDLINE }iommu=pt pci=realloc"
    # Write the new line using python to avoid sed delimiter issues
    NEW_CMDLINE="${NEW_CMDLINE}" python3 - << 'GRUBPY'
import re, os
new_val = os.environ['NEW_CMDLINE']
with open('/etc/default/grub', 'r') as f:
    content = f.read()
content = re.sub(
    r'^GRUB_CMDLINE_LINUX_DEFAULT=.*$',
    f'GRUB_CMDLINE_LINUX_DEFAULT="{new_val}"',
    content, flags=re.MULTILINE
)
with open('/etc/default/grub', 'w') as f:
    f.write(content)
GRUBPY
    update-grub 2>&1 | tee -a "$LOG"
    trap - ERR
    echo "    GRUB: added iommu=pt pci=realloc"
    NEED_REBOOT=true
fi

echo "    Done."

# -----------------------------------------------------------
# 3. Intel GPU drivers (compute-runtime from GitHub)
# -----------------------------------------------------------
echo ""
echo ">>> [3/11] Intel GPU drivers (compute-runtime ${COMPUTE_RUNTIME_VERSION})"

# Add Intel graphics APT repo for base packages
mkdir -p /etc/apt/keyrings
wget -qO- https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --dearmor --yes -o /etc/apt/keyrings/intel-graphics.gpg 2>/dev/null

INTEL_REPO_CODENAME="${OS_CODENAME:-noble}"
# Test if Intel repository supports current release; fallback to noble if not yet available
if ! curl -fsIL "https://repositories.intel.com/gpu/ubuntu/dists/${INTEL_REPO_CODENAME}/InRelease" >/dev/null 2>&1; then
    if [[ "$INTEL_REPO_CODENAME" != "noble" ]]; then
        echo "    Notice: Intel repository does not yet index '${INTEL_REPO_CODENAME}', using 'noble' unified repo."
        INTEL_REPO_CODENAME="noble"
    fi
fi

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/intel-graphics.gpg] \
https://repositories.intel.com/gpu/ubuntu ${INTEL_REPO_CODENAME} unified" \
    > /etc/apt/sources.list.d/intel-gpu.list
apt-get update -qq

# Install Level Zero loader
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq level-zero libze1 2>/dev/null || \
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libze-dev libze1 2>/dev/null || true

# Install compute-runtime from GitHub (APT repo version doesn't support BMG e223)
echo "    Downloading compute-runtime ${COMPUTE_RUNTIME_VERSION} from GitHub..."
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"

CR_BASE="https://github.com/intel/compute-runtime/releases/download/${COMPUTE_RUNTIME_VERSION}"
wget -q "${CR_BASE}/libze-intel-gpu1_${COMPUTE_RUNTIME_VERSION}-0_amd64.deb"
wget -q "${CR_BASE}/intel-opencl-icd_${COMPUTE_RUNTIME_VERSION}-0_amd64.deb"
wget -q "${CR_BASE}/intel-ocloc_${COMPUTE_RUNTIME_VERSION}-0_amd64.deb"
wget -q "${CR_BASE}/libigdgmm12_22.9.0_amd64.deb" || true

echo "    Downloading IGC ${IGC_VERSION}..."
IGC_BASE="https://github.com/intel/intel-graphics-compiler/releases/download/${IGC_VERSION}"
IGC_TAG=$(echo "$IGC_VERSION" | sed 's/^v//')
wget -q "${IGC_BASE}/intel-igc-core-2_${IGC_TAG}+20950_amd64.deb" || \
wget -q "${IGC_BASE}/intel-igc-core_${IGC_TAG}_amd64.deb" || true
wget -q "${IGC_BASE}/intel-igc-opencl-2_${IGC_TAG}+20950_amd64.deb" || \
wget -q "${IGC_BASE}/intel-igc-opencl_${IGC_TAG}_amd64.deb" || true

# Validate downloaded .deb files
echo "    Validating packages..."
for deb in *.deb; do
    [[ -f "$deb" ]] || continue
    if ! file "$deb" | grep -q "Debian binary package"; then
        echo "    WARNING: $deb is not a valid Debian package, skipping"
        rm -f "$deb"
    fi
done

echo "    Installing..."
# Remove conflicting old packages
dpkg -r intel-opencl-icd libze-intel-gpu1 intel-ocloc libigc1 libigdfcl1 libigc2 libigdfcl2 2>/dev/null || true

for deb in libigdgmm12_*.deb intel-igc-core*.deb intel-igc-opencl*.deb libze-intel-gpu1_*.deb intel-opencl-icd_*.deb intel-ocloc_*.deb; do
    [[ -f "$deb" ]] || continue
    dpkg -i "$deb" || echo "    WARNING: Failed to install $deb"
done
DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true
ldconfig

cd /
rm -rf "$WORK_DIR"

# GuC + HuC firmware update for Battlemage
#
# Background: with linux-firmware shipping GuC 70.44.1, all four B70 GPUs
# experienced blitter-engine (bcs) hangs requiring GuC engine resets under
# sustained vLLM load, which cascaded into vLLM EngineCore RPC timeouts and
# killed the API server. The kernel xe driver itself logs:
#   "GuC firmware (70.45.2) is recommended, but only (70.44.1) was found"
#
# Verified working on production 4x B70 install: GuC 70.60.0 + HuC 8.2.10 from
# linux-firmware.git HEAD, installed as zstd-compressed .bin.zst files.
#
# CRITICAL: the xe driver loads bmg_guc_70.bin.zst (compressed). Placing an
# uncompressed bmg_guc_70.bin next to it will take precedence and crash all
# GPUs with -EINVAL. ALWAYS install as .bin.zst, never as raw .bin.
echo "    Updating GuC + HuC firmware from linux-firmware.git HEAD..."
apt-get install -y --only-upgrade -qq linux-firmware >/dev/null 2>&1 || true
apt-get install -y -qq zstd >/dev/null 2>&1
FW_TMP=$(mktemp -d)
LF_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/xe"
if curl -fsSLo "$FW_TMP/bmg_guc_70.bin" "$LF_BASE/bmg_guc_70.bin" && \
   curl -fsSLo "$FW_TMP/bmg_huc.bin"   "$LF_BASE/bmg_huc.bin"; then
    zstd -19 -q -f -o "$FW_TMP/bmg_guc_70.bin.zst" "$FW_TMP/bmg_guc_70.bin"
    zstd -19 -q -f -o "$FW_TMP/bmg_huc.bin.zst"   "$FW_TMP/bmg_huc.bin"
    mkdir -p /lib/firmware/xe
    # Backup any existing files before overwriting
    [[ -f /lib/firmware/xe/bmg_guc_70.bin.zst ]] && \
        cp /lib/firmware/xe/bmg_guc_70.bin.zst /lib/firmware/xe/bmg_guc_70.bin.zst.bak.$(date +%s)
    [[ -f /lib/firmware/xe/bmg_huc.bin.zst ]] && \
        cp /lib/firmware/xe/bmg_huc.bin.zst /lib/firmware/xe/bmg_huc.bin.zst.bak.$(date +%s)
    # CRITICAL: remove any uncompressed .bin that would shadow the .bin.zst
    rm -f /lib/firmware/xe/bmg_guc_70.bin /lib/firmware/xe/bmg_huc.bin
    install -m 644 "$FW_TMP/bmg_guc_70.bin.zst" /lib/firmware/xe/bmg_guc_70.bin.zst
    install -m 644 "$FW_TMP/bmg_huc.bin.zst"   /lib/firmware/xe/bmg_huc.bin.zst
    update-initramfs -u >/dev/null 2>&1 || true
    echo "    GuC/HuC firmware updated. New versions will load on next boot."
else
    echo "    NOTE: Could not fetch firmware from linux-firmware.git (no internet?)."
    echo "    Falling back to distro linux-firmware package."
fi
rm -rf "$FW_TMP"

# Add user to render and video groups
usermod -aG render "${REAL_USER}" 2>/dev/null || true
usermod -aG video "${REAL_USER}" 2>/dev/null || true

echo "    Done."

# -----------------------------------------------------------
# 3b. Intel oneAPI Base Toolkit (DPC++/SYCL, oneMKL, oneDNN)
# -----------------------------------------------------------
echo ""
echo ">>> [3b/11] Intel oneAPI Base Toolkit for SYCL"

# Configure Intel oneAPI repository (all main works on Ubuntu 24.04 and 26.04)
mkdir -p /etc/apt/keyrings
wget -qO- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | \
    gpg --dearmor --yes -o /etc/apt/keyrings/oneapi-archive-keyring.gpg 2>/dev/null

echo "deb [signed-by=/etc/apt/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" \
    > /etc/apt/sources.list.d/oneAPI.list
apt-get update -qq

echo "    Installing oneAPI SYCL compiler (icx/icpx), oneMKL, and oneDNN..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    intel-oneapi-compiler-dpcpp-cpp \
    intel-oneapi-mkl-devel \
    intel-oneapi-dnnl-devel \
    ninja-build

# Mesa check: On Ubuntu 24.04 with older Mesa, upgrade via kisak-mesa PPA for Vulkan BF16
# On Ubuntu 26.04, Mesa 25.3+/26.x is already native and kisak-mesa is not needed.
MESA_VER=$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null || echo 0)
if [[ "${OS_VERSION}" =~ ^24 ]] && ! [[ "$MESA_VER" =~ ^(26|27|28) ]]; then
    echo "    Ubuntu 24.04 detected with Mesa < 26 ($MESA_VER) — adding kisak-mesa PPA for Vulkan BF16..."
    add-apt-repository -y ppa:kisak/kisak-mesa >/dev/null 2>&1 || true
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mesa-vulkan-drivers libvulkan1 vulkan-tools 2>/dev/null || true
else
    echo "    Mesa drivers version: $MESA_VER (OK)"
fi

if [[ -f /opt/intel/oneapi/setvars.sh ]]; then
    echo "    Intel oneAPI installed successfully (/opt/intel/oneapi)"
else
    echo "    WARNING: /opt/intel/oneapi/setvars.sh not found after install"
fi

# -----------------------------------------------------------
# 4. Docker
# -----------------------------------------------------------
echo ""
echo ">>> [4/11] Docker"

# If Docker is installed via Snap, remove it. Snap sandboxing blocks direct GPU
# access (/dev/dri) and ignores /etc/docker/daemon.json address pools.
if command -v snap &>/dev/null && snap list docker &>/dev/null; then
    echo "    Notice: Docker is installed via Snap. Removing Snap package to use native apt..."
    snap remove --purge docker 2>/dev/null || true
fi

mkdir -p /etc/docker
DOCKER_CONFIG_UPDATED=false
if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json << 'DOCKERCONF'
{
  "bip": "172.30.0.1/24",
  "default-address-pools": [
    {
      "base": "172.30.0.0/16",
      "size": 24
    }
  ]
}
DOCKERCONF
    echo "    Configured /etc/docker/daemon.json (bip: 172.30.0.1/24, address pool 172.30.0.0/16)"
    DOCKER_CONFIG_UPDATED=true
fi

if ! command -v docker &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
    systemctl enable docker
    systemctl restart docker
    echo "    Installed Docker $(docker --version | awk '{print $3}')"
else
    echo "    Docker already installed: $(docker --version | awk '{print $3}')"
    if [[ "${DOCKER_CONFIG_UPDATED}" == "true" ]]; then
        systemctl restart docker 2>/dev/null || true
    fi
fi

usermod -aG docker "${REAL_USER}" 2>/dev/null || true

# Install Docker buildx (required for building vLLM from source)
if ! docker buildx version &>/dev/null; then
    echo "    Installing Docker buildx..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-buildx 2>/dev/null || true
fi
if ! docker buildx version &>/dev/null; then
    mkdir -p /usr/local/lib/docker/cli-plugins "${REAL_HOME}/.docker/cli-plugins"
    curl -sL "https://github.com/docker/buildx/releases/download/v0.23.0/buildx-v0.23.0.linux-amd64" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
    cp -f /usr/local/lib/docker/cli-plugins/docker-buildx "${REAL_HOME}/.docker/cli-plugins/docker-buildx"
    chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.docker/cli-plugins/docker-buildx"
    echo "    Buildx installed: $(docker buildx version 2>/dev/null || echo 'OK')"
else
    echo "    Docker buildx already installed: $(docker buildx version 2>/dev/null || echo 'OK')"
fi
echo "    Done."

# -----------------------------------------------------------
# 5. Build vLLM Docker image from source (Optional)
# -----------------------------------------------------------
echo ""
if [[ "${BUILD_VLLM}" == "true" ]]; then
    echo ">>> [5/11] Building vLLM XPU Docker image from source"
    echo "    This builds from vLLM main branch for latest model support."
    echo "    This will take 30-60 minutes..."

    VLLM_BUILD_DIR=$(mktemp -d)
    cd "$VLLM_BUILD_DIR"
    sudo -u "${REAL_USER}" git clone --depth 1 https://github.com/vllm-project/vllm.git .

    if ! docker buildx build -f docker/Dockerfile.xpu -t "${VLLM_DOCKER_IMAGE}" --target vllm-openai --load . 2>&1 | tee -a "$LOG"; then
        echo "    ERROR: vLLM Docker build failed"
        echo "    Falling back to pre-built image..."
        docker pull intel/vllm:0.17.0-xpu
        VLLM_DOCKER_IMAGE="intel/vllm:0.17.0-xpu"
    fi

    # Upgrade transformers inside container for architecture support
    echo "    Upgrading transformers inside container..."
    docker run --rm "${VLLM_DOCKER_IMAGE}" pip install 'transformers>=4.59' 2>/dev/null || true

    cd /
    rm -rf "$VLLM_BUILD_DIR"
    echo "    Done."
else
    echo ">>> [5/11] Skipping vLLM Docker build (using llama.cpp SYCL backend for Continue)"
    echo "    (Set BUILD_VLLM=true if you want to build vLLM container)"
fi

# -----------------------------------------------------------
# 6. Build llama.cpp (SYCL and Vulkan with B70 Xe2 patches)
# -----------------------------------------------------------
echo ""
echo ">>> [6/11] Building llama.cpp (SYCL + Vulkan with Battlemage Xe2 patches)"

LLAMA_BASE_SHA="073bb2c20b5b2c919469653214aaa1a9895816a2"
LLAMA_ROOT="/opt/llama.cpp"
LLAMA_SRC="${LLAMA_ROOT}/llama-sycl-src"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"

mkdir -p "$LLAMA_ROOT"
chown -R "${REAL_USER}:${REAL_USER}" "$LLAMA_ROOT"

if [[ ! -d "$LLAMA_SRC" ]]; then
    echo "    Cloning llama.cpp ($LLAMA_BASE_SHA)..."
    sudo -u "${REAL_USER}" git clone https://github.com/ggml-org/llama.cpp "$LLAMA_SRC"
fi

cd "$LLAMA_SRC"
sudo -u "${REAL_USER}" git fetch origin
sudo -u "${REAL_USER}" git checkout "$LLAMA_BASE_SHA"
sudo -u "${REAL_USER}" git reset --hard "$LLAMA_BASE_SHA" 2>/dev/null || true
sudo -u "${REAL_USER}" git clean -fd 2>/dev/null || true
sudo -u "${REAL_USER}" git branch -D b70-kit 2>/dev/null || true
sudo -u "${REAL_USER}" git checkout -b b70-kit

# Configure git committer identity so git am doesn't fail
sudo -u "${REAL_USER}" git config user.name "B70 Installer"
sudo -u "${REAL_USER}" git config user.email "installer@b70.local"

# Apply B70 Xe2 performance patches (11 cherry-picks from speedup-bugfixes)
if [[ -d "$PATCH_DIR" ]] && [[ $(find "$PATCH_DIR" -name "*.patch" 2>/dev/null | wc -l) -gt 0 ]]; then
    echo "    Applying B70 Battlemage Xe2 patches from patches/..."
    sudo -u "${REAL_USER}" git am --3way "$PATCH_DIR"/*.patch 2>&1 | tee -a "$LOG" || {
        echo "    Notice: git am encountered conflicts, falling back to patch utility..."
        sudo -u "${REAL_USER}" git am --abort 2>/dev/null || true
        for p in "$PATCH_DIR"/*.patch; do
            sudo -u "${REAL_USER}" patch -p1 -N -s < "$p" 2>/dev/null || true
        done
    }
fi

# 6a. Build SYCL backend if oneAPI is installed
LLAMA_SYCL_BUILD="${LLAMA_ROOT}/llama-sycl-build"
if [[ -f /opt/intel/oneapi/setvars.sh ]]; then
    echo "    Building llama.cpp SYCL backend (target: Intel Xe2/BMG, icx/icpx)..."
    rm -rf "$LLAMA_SYCL_BUILD"
    sudo -u "${REAL_USER}" bash -c "
        set -e
        source /opt/intel/oneapi/setvars.sh --force
        cmake -B '$LLAMA_SYCL_BUILD' -S '$LLAMA_SRC' -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DGGML_SYCL=ON \
            -DGGML_SYCL_TARGET=INTEL \
            -DGGML_SYCL_F16=ON \
            -DGGML_SYCL_DNN=ON \
            -DGGML_SYCL_GRAPH=ON \
            -DGGML_SYCL_HOST_MEM_FALLBACK=ON \
            -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx
        cmake --build '$LLAMA_SYCL_BUILD' -j\$(nproc)
    " 2>&1 | tee -a "$LOG"
    echo "    Built SYCL server: ${LLAMA_SYCL_BUILD}/bin/llama-server"
else
    echo "    WARNING: /opt/intel/oneapi/setvars.sh not found, skipping SYCL build."
fi

# 6b. Build Vulkan backend (with Xe2 warptile & coopmat optimizations)
echo "    Building llama.cpp Vulkan backend..."
LLAMA_VK_BUILD="${LLAMA_ROOT}/llama-vulkan-build"
rm -rf "$LLAMA_VK_BUILD"

if ! command -v glslc &>/dev/null; then
    echo "    Installing glslc for Vulkan shader compilation..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq glslc 2>/dev/null || true
fi

VK_COOPMAT_FLAG="-DGGML_VULKAN_COOPMAT_GLSLC_SUPPORT=ON"
if ! command -v glslc &>/dev/null; then
    echo "    Notice: glslc not found, building Vulkan without glslc coopmat support..."
    VK_COOPMAT_FLAG="-DGGML_VULKAN_COOPMAT_GLSLC_SUPPORT=OFF"
fi

mkdir -p "${REAL_HOME}/llama.cpp/build/bin"
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/llama.cpp"

if sudo -u "${REAL_USER}" cmake -B "$LLAMA_VK_BUILD" -S "$LLAMA_SRC" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=ON \
    "${VK_COOPMAT_FLAG}" \
    -DGGML_SYCL=OFF 2>&1 | tee -a "$LOG" && \
   sudo -u "${REAL_USER}" cmake --build "$LLAMA_VK_BUILD" -j$(nproc) 2>&1 | tee -a "$LOG"; then
    echo "    Built Vulkan server: ${LLAMA_VK_BUILD}/bin/llama-server"
    ln -sf "${LLAMA_VK_BUILD}/bin/llama-server" "${REAL_HOME}/llama.cpp/build/bin/llama-server"
else
    echo "    WARNING: Vulkan build failed or incomplete. Using SYCL backend as primary."
    if [[ -f "${LLAMA_SYCL_BUILD}/bin/llama-server" ]]; then
        ln -sf "${LLAMA_SYCL_BUILD}/bin/llama-server" "${REAL_HOME}/llama.cpp/build/bin/llama-server"
    fi
fi

# -----------------------------------------------------------
# 7. Download coding models for Continue (Agent & Autocomplete)
# -----------------------------------------------------------
echo ""
echo ">>> [7/11] Downloading coding models for VS Code Continue"

MODEL_DIR="/mnt/models"
mkdir -p "${MODEL_DIR}"
chown -R "${REAL_USER}:${REAL_USER}" "${MODEL_DIR}"
ln -sfn "${MODEL_DIR}" "${REAL_HOME}/models"

echo "    Installing huggingface_hub..."
sudo -u "${REAL_USER}" python3 -m pip install --break-system-packages -q huggingface_hub 2>/dev/null || \
python3 -m pip install --break-system-packages -q huggingface_hub 2>/dev/null || true

echo "    Checking/Downloading models:"
echo "      - Agent:        ${AGENT_MODEL_FILE} (${AGENT_MODEL_REPO})"
echo "      - Autocomplete: ${AUTOCOMPLETE_MODEL_FILE} (${AUTOCOMPLETE_MODEL_REPO})"

sudo -u "${REAL_USER}" python3 - \
    "${AGENT_MODEL_REPO}" \
    "${AGENT_MODEL_FILE}" \
    "${AUTOCOMPLETE_MODEL_REPO}" \
    "${AUTOCOMPLETE_MODEL_FILE}" \
    "${MODEL_DIR}" << 'PYEOF'
import sys, os
from huggingface_hub import hf_hub_download

agent_repo = sys.argv[1]
agent_file = sys.argv[2]
ac_repo = sys.argv[3]
ac_file = sys.argv[4]
model_dir = sys.argv[5]

models = [
    (agent_repo, agent_file),
    (ac_repo, ac_file)
]

for repo, filename in models:
    dest = os.path.join(model_dir, filename)
    if os.path.exists(dest) and os.path.getsize(dest) > 100000000:
        print(f"    [SKIP] {filename} already exists ({os.path.getsize(dest)} bytes)")
    else:
        print(f"    [DOWNLOADING] {filename} from {repo} (this may take a few minutes)...")
        hf_hub_download(repo_id=repo, filename=filename, local_dir=model_dir)
        print(f"    [OK] Downloaded {filename}!")
PYEOF

echo "    Done."

# -----------------------------------------------------------
# 8. Swap configuration & Continue configuration generator
# -----------------------------------------------------------
echo ""
echo ">>> [8/11] Swap configuration and Continue VS Code setup"

# Create swap file if RAM < 64GB
TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
if [[ "$TOTAL_RAM_GB" -lt 64 ]]; then
    SWAP_SIZE=$((64 - TOTAL_RAM_GB + 16))
    echo "    System has ${TOTAL_RAM_GB}GB RAM — creating ${SWAP_SIZE}GB swap file..."
    if [[ ! -f /swapfile_vllm ]]; then
        fallocate -l "${SWAP_SIZE}G" /swapfile_vllm
        chmod 600 /swapfile_vllm
        mkswap /swapfile_vllm
        swapon /swapfile_vllm
        echo "/swapfile_vllm none swap sw 0 0" >> /etc/fstab
        echo "    Swap file created and enabled (persistent across reboots)"
    else
        echo "    Swap file already exists"
    fi
else
    echo "    System has ${TOTAL_RAM_GB}GB RAM — no extra swap needed"
fi

# Generate Continue config.json snippet in user home
CONTINUE_DIR="${REAL_HOME}/.continue"
mkdir -p "${CONTINUE_DIR}"
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "${HOST_IP}" ]] && HOST_IP="127.0.0.1"

cat > "${CONTINUE_DIR}/config.json.example" << CONTINUEDOC
{
  "models": [
    {
      "title": "Qwen3-Coder 30B-A3B (Agent)",
      "provider": "openai",
      "model": "qwen3-coder-30b",
      "apiBase": "http://${HOST_IP}:${AGENT_PORT}/v1",
      "contextLength": 32768
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5-Coder 1.5B (Autocomplete)",
    "provider": "openai",
    "model": "qwen2.5-coder-1.5b",
    "apiBase": "http://${HOST_IP}:${AUTOCOMPLETE_PORT}/v1"
  }
}
CONTINUEDOC
chown -R "${REAL_USER}:${REAL_USER}" "${CONTINUE_DIR}"
echo "    Generated Continue configuration example at ${CONTINUE_DIR}/config.json.example"
echo "    Done."

# -----------------------------------------------------------
# 9. Create scripts and systemd services
# -----------------------------------------------------------
echo ""
echo ">>> [9/11] Creating scripts and services"

# Detect GPU count
GPU_COUNT=$(lspci | grep -c "Intel.*e223" 2>/dev/null || echo 0)
[[ "$GPU_COUNT" -eq 0 ]] && GPU_COUNT=1  # Default assumption (single GPU)

# --- vLLM startup script ---
cat > "${REAL_HOME}/start_vllm.sh" << VLLMSCRIPT
#!/usr/bin/env bash
# Start vLLM with tensor parallelism across all B70 GPUs
GPU_COUNT=\$(lspci | grep -c "Intel.*e223" 2>/dev/null || echo ${GPU_COUNT})

if ! docker ps --format '{{.Names}}' | grep -q '^vllm-b70\$'; then
    echo "ERROR: Container vllm-b70 is not running. Run ${REAL_HOME}/boot_vllm.sh first."
    exit 1
fi

# Idempotency guard: check if vllm is ALREADY HEALTHY (listening on port and
# responding to /health), not just if the process exists. A crashed vllm
# often leaves orphaned worker processes or a zombie bash wrapper that would
# match 'pgrep -f "vllm serve"' — an earlier version of this guard did that
# and refused to start a new vllm after a hang, leaving the bot stack dead.
if curl -sf --max-time 3 "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null 2>&1; then
    echo "vLLM already healthy on port ${VLLM_PORT} — skipping start"
    exit 0
fi
# If we get here, vllm is not healthy. Clean up any orphaned processes +
# shared-memory segments before spawning a fresh one.
if docker exec vllm-b70 pgrep -f 'vllm serve' >/dev/null 2>&1; then
    echo "vLLM process exists but port ${VLLM_PORT} is not responding — cleaning up orphans"
    "${REAL_HOME}/stop_vllm.sh" || true
    sleep 2
fi

docker exec -d vllm-b70 bash -c "
# vLLM XPU env vars (DO NOT REMOVE — each works around a specific BMG/vLLM bug)
#
# ZE_AFFINITY_MASK=1,3      — Cards 0/2 have shown silent SEGV on this rig;
#                             cards 1,3 are the verified-stable pair for TP=2.
# UR_L0_USE_IMMEDIATE_COMMANDLISTS=0
#                           — Routes around libze 25.48 vtable GPF in the
#                             kernel residency path (dmesg traps: GPF in
#                             libze_intel_gpu.so.1.14.36300[6e36f5]).
# CCL_TOPO_P2P_ACCESS=0     — Forces XCCL allreduce through system RAM instead
#                             of Level Zero P2P (P2P init hangs TP=2 workers).
# VLLM_WORKER_MULTIPROC_METHOD=spawn
#                           — Required for multi-GPU XPU; fork deadlocks on xccl.
# VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
#                           — Allows max-model-len > model's native context.
export ZE_AFFINITY_MASK=1,3
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export UR_L0_USE_IMMEDIATE_COMMANDLISTS=0
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export CCL_TOPO_P2P_ACCESS=0

# vLLM CLI flags (DO NOT REMOVE — each works around a specific bug)
#
# --enforce-eager           — XPU Graph is not supported, eager is required.
# --attention-backend TRITON_ATTN
#                           — Triton is the only stable XPU attention backend for Gemma 4.
# --disable-custom-all-reduce
#                           — vLLM's custom AR kernel crashes on BMG.
# --tensor-parallel-size 2  — TP=4 triggers libigc JIT crash on the 4-way init path;
#                             TP=2 with ZE_AFFINITY_MASK=1,3 is the verified stable config.
#                             Friday 3-model rollout will run: Gemma TP=2 (this),
#                             Qwen3-Coder-30B TP=1 on card 0, Qwen3-8B+Embed TP=1 on card 2.
# --skip-mm-profiling --language-model-only
#                           — Gemma 4 is multimodal, but the MM dummy-batch profile_run
#                             OOMs during worker init; we only need text inference.
# --num-gpu-blocks-override 400
#                           — Caps KV cache to avoid XPU allocator fragmentation on
#                             per-layer-group KV tensors (workers OOM trying to
#                             allocate 1.9-2.8 GiB contiguous after weights loaded).
#                             Each block = 64 tokens; 400 blocks = 25,600 tokens KV cache.
#                             Max concurrency for 32k prompts is ~1-2, which is fine
#                             for the trading bots (max-num-seqs 4).
# --gpu-memory-util 0.85    — Leaves headroom for Triton JIT compile space.
# --max-num-seqs 4 --max-model-len 32768
#                           — Matches the trading bot expected load.
vllm serve /llm/models/${MODEL_LOCAL_NAME} \\
  --served-model-name ${VLLM_MODEL_NAME} \\
  --port ${VLLM_PORT} \\
  --host 0.0.0.0 \\
  --dtype bfloat16 \\
  --quantization fp8 \\
  --enforce-eager \\
  --skip-mm-profiling \\
  --language-model-only \\
  --attention-backend TRITON_ATTN \\
  --disable-custom-all-reduce \\
  --tensor-parallel-size 2 \\
  --gpu-memory-util 0.85 \\
  --block-size 64 \\
  --max-model-len 32768 \\
  --max-num-seqs 4 \\
  --num-gpu-blocks-override 400 \\
  --enable-auto-tool-choice \\
  --tool-call-parser gemma4 \\
  --enable-chunked-prefill \\
  --no-enable-prefix-caching \\
  --trust-remote-code \\
  --chat-template /llm/models/${MODEL_LOCAL_NAME}/chat_template.jinja \\
  2>&1 | tee -a /tmp/vllm.log
"
echo "vLLM starting (${VLLM_MODEL_NAME}, TP=2 on cards 1,3)..."
echo "Health check: curl http://localhost:${VLLM_PORT}/health"
VLLMSCRIPT

# --- vLLM graceful stop script ---
# Without this, restarting vllm-serve leaves the old vllm process AND its
# leaked /dev/shm segments alive — XPU VRAM never frees and the new vllm
# fails with "Free memory on device xpu:0 (0.02/30.3 GiB)".
cat > "${REAL_HOME}/stop_vllm.sh" << 'STOPSCRIPT'
#!/usr/bin/env bash
# Gracefully stop vLLM inside the container so XPU VRAM and shared memory
# segments are released. SIGKILL leaks shm; SIGTERM lets vLLM clean up.
if ! docker ps --format '{{.Names}}' | grep -q '^vllm-b70$'; then
    exit 0
fi
docker exec vllm-b70 bash -c '
  pids=$(pgrep -f "vllm serve" || true)
  if [ -n "$pids" ]; then
    kill -TERM $pids 2>/dev/null || true
    for i in $(seq 1 30); do
      pgrep -f "vllm serve" >/dev/null || break
      sleep 1
    done
    pkill -9 -f "vllm serve" 2>/dev/null || true
  fi
  # Sweep leaked POSIX shm segments left behind by vLLM workers
  rm -f /dev/shm/psm_* /dev/shm/vllm_* 2>/dev/null || true
' || true
STOPSCRIPT
chmod +x "${REAL_HOME}/stop_vllm.sh"
chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/stop_vllm.sh"

# --- Full boot script ---
cat > "${REAL_HOME}/boot_vllm.sh" << BOOTEOF
#!/usr/bin/env bash
# Full boot: start Docker container, then vLLM server
echo "Starting Docker container..."
docker stop vllm-b70 2>/dev/null || true
docker rm vllm-b70 2>/dev/null || true

docker run -d --privileged --shm-size 32g --net=host --ipc=host \\
  --restart=unless-stopped \\
  -v "${MODEL_DIR}:/llm/models" \\
  --name=vllm-b70 \\
  --entrypoint="" ${VLLM_DOCKER_IMAGE} sleep infinity

sleep 5

# Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q '^vllm-b70\$'; then
    echo "ERROR: Container failed to start. Check: docker logs vllm-b70"
    exit 1
fi

# Upgrade transformers for Gemma 4 (needed until vLLM pins a compatible version)
echo "Upgrading transformers..."
docker exec vllm-b70 pip install -q 'transformers>=4.59' 2>/dev/null || true

echo "Starting vLLM server..."
${REAL_HOME}/start_vllm.sh

echo "Waiting for vLLM health check..."
for i in \$(seq 1 180); do
    if curl -sf -o /dev/null http://127.0.0.1:${VLLM_PORT}/health 2>/dev/null; then
        echo "vLLM READY after \$((i*2))s!"
        echo "API: http://\$(hostname -I | awk '{print \$1}'):${VLLM_PORT}"
        exit 0
    fi
    sleep 2
done
echo "WARNING: vLLM did not become ready within 360s."
echo "Check logs: docker exec vllm-b70 tail -30 /tmp/vllm.log"
BOOTEOF

# --- llama.cpp startup script ---
cat > "${REAL_HOME}/start_llamacpp.sh" << LLAMASCRIPT
#!/usr/bin/env bash
# Start llama.cpp Vulkan server (fallback general-purpose server)
PORT="\${1:-${LLAMACPP_PORT}}"
MODEL="\${2:-\${HOME}/models/${AGENT_MODEL_FILE}}"
[[ -f "\$MODEL" ]] || { echo "Model not found: \$MODEL"; echo "Usage: \$0 [port] [path_to_gguf]"; exit 1; }
echo "Starting llama.cpp Vulkan on port \${PORT}..."
\${HOME}/llama.cpp/build/bin/llama-server \\
    -m "\$MODEL" -ngl 99 \\
    --flash-attn \\
    --cache-type-k q8_0 --cache-type-v q8_0 \\
    --host 0.0.0.0 --port "\${PORT}" \\
    --ctx-size 4096 --parallel 4 --threads \$(nproc)
LLAMASCRIPT

# --- System info script ---
cat > "${REAL_HOME}/sysinfo.sh" << SYSSCRIPT
#!/usr/bin/env bash
echo "=== ODIN Inference Server ==="
echo "Hostname: \$(hostname)"
echo "IP:       \$(hostname -I | awk '{print \$1}')"
echo "Kernel:   \$(uname -r)"
echo "Uptime:   \$(uptime -p)"
echo "RAM:      \$(free -h | awk '/Mem:/{print \$3"/"\$2}')"
echo "Disk:     \$(df -h / | awk 'NR==2{print \$3"/"\$2" ("\$5" used)"}')"
echo ""
echo "=== GPUs ==="
lspci | grep -i "vga\|display\|3d"
echo ""
echo "=== GPU Temps ==="
sensors 2>/dev/null | grep -A3 'xe-pci' || echo "(install lm-sensors or use kernel 6.17+)"
echo ""
echo "=== Vulkan Devices ==="
vulkaninfo --summary 2>/dev/null | grep -A2 "deviceName" || echo "(not available)"
echo ""
echo "=== AI Services (Continue) ==="
if systemctl is-active --quiet llama-agent.service 2>/dev/null; then
    echo "  llama-agent:        running (port ${AGENT_PORT})"
else
    echo "  llama-agent:        inactive/stopped"
fi
if systemctl is-active --quiet llama-autocomplete.service 2>/dev/null; then
    echo "  llama-autocomplete: running (port ${AUTOCOMPLETE_PORT})"
else
    echo "  llama-autocomplete: inactive/stopped"
fi
if curl -sf -o /dev/null http://127.0.0.1:${AGENT_PORT}/v1/models 2>/dev/null; then
    echo "  Agent API:          healthy (http://localhost:${AGENT_PORT})"
else
    echo "  Agent API:          not responding (port ${AGENT_PORT})"
fi
if curl -sf -o /dev/null http://127.0.0.1:${AUTOCOMPLETE_PORT}/v1/models 2>/dev/null; then
    echo "  Autocomplete API:   healthy (http://localhost:${AUTOCOMPLETE_PORT})"
else
    echo "  Autocomplete API:   not responding (port ${AUTOCOMPLETE_PORT})"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'vllm'; then
    echo "  vLLM Docker:        running"
    if curl -sf -o /dev/null http://127.0.0.1:${VLLM_PORT}/health 2>/dev/null; then
        echo "  vLLM API:           healthy (port ${VLLM_PORT})"
    fi
fi
SYSSCRIPT

# --- GPU thermal watchdog script ---
cat > "${REAL_HOME}/gpu_thermal_watchdog.sh" << 'THERMALEOF'
#!/usr/bin/env bash
THRESHOLD=90
LOG=/var/log/gpu_thermal.log
while true; do
    MAX_TEMP=0
    while IFS= read -r line; do
        case "$line" in *C*) ;; *) continue ;; esac
        temp=$(echo "$line" | cut -d'(' -f1 | grep -oE '[0-9]+' | head -1)
        if [ -n "$temp" ] && [ "$temp" -gt "$MAX_TEMP" ] 2>/dev/null; then
            MAX_TEMP=$temp
        fi
    done < <(sensors 2>/dev/null | grep -E "^\s*(pkg|vram):" | grep -v MJ | grep -v W)
    if [ "$MAX_TEMP" -gt 0 ] && [ "$MAX_TEMP" -ge "$THRESHOLD" ]; then
        echo "$(date): CRITICAL GPU temp ${MAX_TEMP}C >= ${THRESHOLD}C stopping AI workloads" | tee -a $LOG
        systemctl stop llama-agent.service 2>/dev/null || true
        systemctl stop llama-autocomplete.service 2>/dev/null || true
        docker exec vllm-b70 pkill -f "vllm serve" 2>/dev/null || true
        docker stop vllm-b70 2>/dev/null || true
        echo "$(date): AI workloads stopped for thermal protection" | tee -a $LOG
    fi
    sleep 30
done
THERMALEOF

# Set permissions
for script in start_vllm boot_vllm start_llamacpp sysinfo gpu_thermal_watchdog; do
    if [[ -f "${REAL_HOME}/${script}.sh" ]]; then
        chmod +x "${REAL_HOME}/${script}.sh"
        chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/${script}.sh"
    fi
done

# --- Systemd service for Docker container ---
cat > /etc/systemd/system/vllm-docker.service << EOF
[Unit]
Description=vLLM Docker Container (ODIN)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=300
TimeoutStopSec=30
ExecStartPre=-/usr/bin/docker stop vllm-b70
ExecStartPre=-/usr/bin/docker rm vllm-b70
ExecStart=/usr/bin/docker run -d --privileged --shm-size 32g --net=host --ipc=host --restart=unless-stopped -v ${MODEL_DIR}:/llm/models --name=vllm-b70 --entrypoint= ${VLLM_DOCKER_IMAGE} sleep infinity
ExecStop=/usr/bin/docker stop -t 15 vllm-b70

[Install]
WantedBy=multi-user.target
EOF

# --- Systemd service for GPU thermal watchdog ---
cat > /etc/systemd/system/gpu-thermal-watchdog.service << EOF
[Unit]
Description=GPU Thermal Watchdog (ODIN)
After=network.target

[Service]
Type=simple
ExecStart=${REAL_HOME}/gpu_thermal_watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- vLLM watchdog script (auto-restart on crash or hang) ---
# IMPORTANT: the authoritative liveness check is an HTTP probe of /health,
# NOT 'pgrep vllm serve'. When vLLM hangs on a GPU blitter-engine reset, the
# EngineCore dies but orphaned worker processes (and the bash wrapper) can
# linger — pgrep would incorrectly report vllm as alive and the watchdog
# would never restart it. Observed failure: engine_class=bcs GuC reset ->
# RPC call to sample_tokens timed out -> EngineCore dead -> port 8000 dead.
cat > "${REAL_HOME}/watchdog_vllm.sh" << WATCHEOF
#!/usr/bin/env bash
LOG=${REAL_HOME}/watchdog.log
HEALTH_URL="http://127.0.0.1:${VLLM_PORT}/health"
CONSECUTIVE_FAILURES=0
FAILURE_THRESHOLD=2     # 2 consecutive failures (60s) between checks
STUCK_THRESHOLD=300     # up to 10 min for model load after a restart
STARTUP_GRACE=600       # up to 20 min for first-boot model load (cold cache)

echo "\$(date): Watchdog started (health-check mode)" >> \$LOG

# Startup grace period: wait for initial health before enforcing the
# failure threshold. Prevents the watchdog from killing in-progress model
# loads on boot or after an operator-initiated restart. Model load on cold
# cache + swap-backed systems can take 10+ minutes.
echo "\$(date): Entering startup grace (up to \$STARTUP_GRACE seconds)" >> \$LOG
for i in \$(seq 1 \$STARTUP_GRACE); do
    if curl -sf --max-time 3 "\$HEALTH_URL" >/dev/null 2>&1; then
        echo "\$(date): Initial health OK after \${i}s" >> \$LOG
        break
    fi
    sleep 1
done

restart_vllm() {
    echo "\$(date): Triggering vLLM restart" >> \$LOG
    # Capture full diagnostic snapshot before tearing down
    /usr/local/bin/gpu_diag_logger.sh --on-failure >/dev/null 2>&1 || true
    "${REAL_HOME}/stop_vllm.sh" 2>>\$LOG || true
    sleep 3
    "${REAL_HOME}/start_vllm.sh" >>\$LOG 2>&1 || true
    # Wait for /health to come back (up to \$STUCK_THRESHOLD * 2 seconds)
    for i in \$(seq 1 \$STUCK_THRESHOLD); do
        if curl -sf --max-time 3 "\$HEALTH_URL" >/dev/null 2>&1; then
            echo "\$(date): vLLM healthy after \$((i*2))s" >> \$LOG
            CONSECUTIVE_FAILURES=0
            return 0
        fi
        sleep 2
    done
    echo "\$(date): vLLM did not become healthy after restart" >> \$LOG
    return 1
}

while true; do
    # Container liveness
    if ! docker ps --format '{{.Names}}' | grep -q '^vllm-b70\$'; then
        echo "\$(date): Container down, restarting docker service..." >> \$LOG
        sudo systemctl restart vllm-docker 2>>\$LOG || true
        sleep 15
        restart_vllm
        sleep 30
        continue
    fi

    # HTTP health probe — the authoritative check
    if curl -sf --max-time 3 "\$HEALTH_URL" >/dev/null 2>&1; then
        CONSECUTIVE_FAILURES=0
    else
        CONSECUTIVE_FAILURES=\$((CONSECUTIVE_FAILURES + 1))
        echo "\$(date): Health check failed (\$CONSECUTIVE_FAILURES/\$FAILURE_THRESHOLD)" >> \$LOG
        if [ \$CONSECUTIVE_FAILURES -ge \$FAILURE_THRESHOLD ]; then
            restart_vllm
        fi
    fi
    sleep 30
done
WATCHEOF
chmod +x "${REAL_HOME}/watchdog_vllm.sh"
chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/watchdog_vllm.sh"

# --- Systemd service for vLLM watchdog ---
cat > /etc/systemd/system/vllm-watchdog.service << EOF
[Unit]
Description=vLLM Watchdog — auto-restart on crash (ODIN)
After=docker.service vllm-docker.service
Wants=docker.service

[Service]
Type=simple
User=${REAL_USER}
ExecStart=${REAL_HOME}/watchdog_vllm.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- VRAM cleanup helper (pre-start hook) ---
# Reclaims VRAM held by crashed vLLM workers before re-launching the model.
# Prevents level_zero UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY on dirty restarts.
CLEANUP_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vllm_vram_cleanup.sh"
if [[ -f "$CLEANUP_SCRIPT_PATH" ]]; then
    install -m755 "$CLEANUP_SCRIPT_PATH" /usr/local/bin/vllm_vram_cleanup.sh
else
    curl -fsSL https://raw.githubusercontent.com/Bygren/arc-pro-b70-inference-setup-ubuntu-server/master/vllm_vram_cleanup.sh \
        -o /usr/local/bin/vllm_vram_cleanup.sh
    chmod 755 /usr/local/bin/vllm_vram_cleanup.sh
fi

# --- xe driver tuning (runs before vllm-docker at every boot) ---
# Raises per-engine job_timeout_ms / preempt_timeout_us to the engine max and
# pins GT frequency to disable DVFS. Root cause fix for the xe GuC watchdog
# hang (xe_guc_submit.c:1291 guc_exec_queue_timedout_job) seen on Gemma 4
# 26B-A4B FP8 TP=4 enforce_eager workloads where a single compute submission
# can exceed the 5000 ms default timeout.
XE_TUNING_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/xe_tuning.sh"
if [[ -f "$XE_TUNING_SRC" ]]; then
    install -m755 "$XE_TUNING_SRC" /usr/local/bin/xe_tuning.sh
fi
XE_TMPFILES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tmpfiles.d/xe-gpu-tuning.conf"
if [[ -f "$XE_TMPFILES_SRC" ]]; then
    install -m644 "$XE_TMPFILES_SRC" /etc/tmpfiles.d/xe-gpu-tuning.conf
fi
XE_UNIT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/systemd/xe-tuning.service"
if [[ -f "$XE_UNIT_SRC" ]]; then
    install -m644 "$XE_UNIT_SRC" /etc/systemd/system/xe-tuning.service
    systemctl daemon-reload
    systemctl enable xe-tuning.service
fi

# --- Systemd service for vLLM serve (with graceful stop) ---
cat > /etc/systemd/system/vllm-serve.service << EOF
[Unit]
Description=vLLM Model Server (inside Docker container)
After=vllm-docker.service
Requires=vllm-docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStopSec=60
# Reclaim VRAM from any crashed workers before (re)starting vLLM.
# Defense-in-depth against level_zero UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY
# on dirty restarts after xe GuC job timeouts.
ExecStartPre=/usr/local/bin/vllm_vram_cleanup.sh
ExecStartPre=/bin/sleep 10
ExecStart=${REAL_HOME}/start_vllm.sh
ExecStop=${REAL_HOME}/stop_vllm.sh
# Health check: wait up to 5 min for vLLM to respond
ExecStartPost=/bin/bash -c 'for i in \$(seq 1 60); do curl -s http://127.0.0.1:${VLLM_PORT}/health && exit 0; sleep 5; done; echo "vLLM health timeout"'

[Install]
WantedBy=multi-user.target
EOF

# --- GPU diagnostic logger ---
# Captures comprehensive GPU and inference state to /var/log/gpu-diag/ so
# intermittent issues (PCODE timeouts, xe driver init failures, oneCCL hangs,
# vLLM EngineCore RPC timeouts) can be debugged after the fact. Reads dmesg,
# /sys/class/drm, /sys/bus/pci, igsc, and the vLLM /health endpoint. Runs at
# boot, every 5 minutes via systemd timer, and is hooked into the vLLM
# watchdog's restart_vllm() function so a snapshot is captured at the
# moment of failure.
#
# Files in /var/log/gpu-diag/:
#   state.log         one-line per snapshot (lightweight, append-only)
#   events.log        state-transition events (card count change, vllm down)
#   detail-YYYY-MM-DD.log   per-day full detail dump (rotated after 14 days)
#   dmesg-last.txt    full dmesg snapshot at the most recent failure
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gpu_diag_logger.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    install -m755 "$SCRIPT_PATH" /usr/local/bin/gpu_diag_logger.sh
else
    # Fallback: install from GitHub raw URL if running odin-b70-setup.sh standalone
    curl -fsSL https://raw.githubusercontent.com/Bygren/arc-pro-b70-inference-setup-ubuntu-server/master/gpu_diag_logger.sh \
        -o /usr/local/bin/gpu_diag_logger.sh
    chmod 755 /usr/local/bin/gpu_diag_logger.sh
fi
mkdir -p /var/log/gpu-diag

cat > /etc/systemd/system/gpu-diag-boot.service << EOF
[Unit]
Description=GPU diagnostic snapshot at boot
After=multi-user.target gpu-rescan.service vllm-docker.service
Wants=gpu-rescan.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpu_diag_logger.sh --boot
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/gpu-diag-timer.service << EOF
[Unit]
Description=GPU diagnostic snapshot (timer-driven)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpu_diag_logger.sh
EOF

cat > /etc/systemd/system/gpu-diag-timer.timer << EOF
[Unit]
Description=Run GPU diagnostic snapshot every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=gpu-diag-timer.service

[Install]
WantedBy=timers.target
EOF

# Stage SYCL start scripts in user home
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for s in start_agent.sh start_autocomplete.sh; do
    if [[ -f "${SETUP_DIR}/${s}" ]]; then
        install -m 0755 "${SETUP_DIR}/${s}" "${REAL_HOME}/${s}"
        chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/${s}"
    fi
done

# Compatibility symlink: start_coder.sh -> start_agent.sh
ln -sf "${REAL_HOME}/start_agent.sh" "${REAL_HOME}/start_coder.sh"
chown -h "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/start_coder.sh"

# Ensure model directory /mnt/models exists
mkdir -p /mnt/models
chown -R "${REAL_USER}:${REAL_USER}" /mnt/models

# Install llama.cpp systemd units
if [[ -f "${SETUP_DIR}/systemd/llamacpp@.service" ]]; then
    install -m 0644 "${SETUP_DIR}/systemd/llamacpp@.service" /etc/systemd/system/llamacpp@.service
fi

# Clean up deprecated services if they exist
for old_svc in llama-gemma.service llama-coder.service llama-fast.service; do
    systemctl stop "${old_svc}" 2>/dev/null || true
    systemctl disable "${old_svc}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${old_svc}"
done

# Install and configure Continue Agent and Autocomplete services
for svc in llama-agent.service llama-autocomplete.service; do
    if [[ -f "${SETUP_DIR}/systemd/${svc}" ]]; then
        sed -e "s|User=.*|User=${REAL_USER}|g" \
            -e "s|/home/[^/]*/start_|${REAL_HOME}/start_|g" \
            "${SETUP_DIR}/systemd/${svc}" > "/etc/systemd/system/${svc}"
    fi
done

systemctl daemon-reload
systemctl enable llama-agent.service
systemctl enable llama-autocomplete.service
systemctl enable gpu-thermal-watchdog.service
systemctl enable gpu-diag-boot.service
systemctl enable gpu-diag-timer.timer

echo "    Starting AI services immediately..."
systemctl restart llama-agent.service 2>/dev/null || true
systemctl restart llama-autocomplete.service 2>/dev/null || true

# -----------------------------------------------------------
# 8b. BMG/vLLM post-install patches (bake into container image)
# -----------------------------------------------------------
# These work around three Intel stack bugs that block Gemma 4 on BMG:
#
# 1. libze 25.48 Tokenizer pickle roundtrip bug
#    Rust tokenizers 0.22.2 can't unpickle its own Tokenizer state when merges
#    use the new list format (Gemma 4 tokenizer.json does). Hits copy.deepcopy(kwargs)
#    inside transformers.processing_utils.get_processor_dict and
#    transformers.configuration_utils.get_config_dict. Fix: monkey-patch
#    Tokenizer.__deepcopy__ to return self (Tokenizer is immutable in our use).
#    Installed as a .pth hook so it runs at every Python interpreter start,
#    including multiprocessing spawn subprocesses.
#
# 2. Gemma 4 tokenizer.json new-format merges crash IGC during BPE init
#    Even with the deepcopy fix, some code paths try to re-parse the minimal
#    tokenizer.json through TokenizerFast.from_str() and hit "Token ,[ out of
#    vocabulary at line 2322064 column 1". Fix: convert merges from
#    [[a, b], ...] list format to legacy "a b" space-joined strings.
#    Safe because NO Gemma 4 merge token contains a space (verified).
#    One-time model-side patch. Backup saved to tokenizer.json.bak.listmerges.
#
# 3. Host bind-mount cleanup
#    Earlier systemd-unit experiments left libze/libigdgmm host paths bind-
#    mounted read-only into the container, which breaks dpkg and makes
#    /usr/lib/x86_64-linux-gnu unwritable. Unit already cleaned, but the
#    post-install verifies no stale bind mounts remain.

if docker ps --format '{{.Names}}' | grep -q '^vllm-b70$'; then
    echo "[+] Baking BMG/vLLM patches into container..."

    # 1) Tokenizer deepcopy patch via .pth hook (fires on every Python start)
    cat > /tmp/_tok_fix.py << 'TOKFIX'
try:
    import tokenizers
    _T = tokenizers.Tokenizer
    if not getattr(_T, '_dc_patched', False):
        _T.__deepcopy__ = lambda self, memo=None: self
        _T._dc_patched = True
except Exception as _e:
    import sys; sys.stderr.write('[_tok_fix] ' + str(_e) + chr(10))
TOKFIX
    CONTAINER_SITE_PACKAGES=$(docker exec vllm-b70 python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "/opt/venv/lib/python3.12/site-packages")
    cat > /tmp/z_tokenizer_fix.pth << PTH
import sys; exec(open('${CONTAINER_SITE_PACKAGES}/_tok_fix.py').read()) if __import__('os').path.exists('${CONTAINER_SITE_PACKAGES}/_tok_fix.py') else None
PTH
    docker cp /tmp/_tok_fix.py "vllm-b70:${CONTAINER_SITE_PACKAGES}/_tok_fix.py"
    docker cp /tmp/z_tokenizer_fix.pth "vllm-b70:${CONTAINER_SITE_PACKAGES}/z_tokenizer_fix.pth"
    docker exec vllm-b70 python3 -c "import tokenizers; assert getattr(tokenizers.Tokenizer, '_dc_patched', False), 'patch not applied'; print('[+] tokenizer deepcopy patch: OK')"

    # 2) Gemma 4 tokenizer.json legacy merges conversion (model-side, persistent)
    GEMMA_TOK="${MODEL_DIR}/gemma-4-26B-A4B-it/tokenizer.json"
    if [[ -f "$GEMMA_TOK" ]]; then
        if [[ ! -f "${GEMMA_TOK}.bak.listmerges" ]]; then
            cp "$GEMMA_TOK" "${GEMMA_TOK}.bak.listmerges"
        fi
        python3 - << PYTOK
import json, sys
p = "$GEMMA_TOK"
d = json.load(open(p))
m = d.get("model", {}).get("merges", [])
if m and isinstance(m[0], list):
    new = [(x[0] + " " + x[1]) if isinstance(x, list) and len(x) == 2 else x for x in m]
    d["model"]["merges"] = new
    json.dump(d, open(p, "w"), ensure_ascii=False)
    print(f"[+] gemma-4 tokenizer.json: converted {len(m)} merges to legacy string format")
else:
    print("[+] gemma-4 tokenizer.json: already legacy format, skipping")
PYTOK
    else
        echo "[!] Gemma 4 model not found at $GEMMA_TOK — skipping tokenizer merges conversion."
        echo "    After downloading the model, re-run this section or run the helper:"
        echo "    sudo $SETUP_DIR/fix_gemma4_tokenizer.sh"
    fi

    # 3) Verify no stale libze/libigdgmm host bind-mounts on the container
    if docker inspect vllm-b70 --format '{{json .Mounts}}' | grep -qE 'libze_intel_gpu|libigdgmm'; then
        echo "[!] WARNING: container has stale libze/libigdgmm bind-mounts from an"
        echo "    earlier experiment. Stop/remove container and re-create via systemd"
        echo "    to clean them up, otherwise dpkg in-container upgrades will fail with"
        echo "    'unable to make backup link ... Invalid cross-device link'."
    fi

    # 4) Commit the patched container as a versioned image so the patches survive
    #    systemd restart. Downstream vllm-docker.service already references
    #    vllm-xpu:gemma4-fixed (see VLLM_DOCKER_IMAGE above).
    docker commit vllm-b70 vllm-xpu:gemma4-fixed >/dev/null
    echo "[+] Committed patched container as vllm-xpu:gemma4-fixed"
else
    echo "[!] vllm-b70 container is not running — skipping patch bake."
    echo "    Start it with: sudo systemctl start vllm-docker && sudo $0"
fi

# Intel driver/firmware daily update checker
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SETUP_DIR/intel_update_check.sh" ]]; then
    install -m 0755 "$SETUP_DIR/intel_update_check.sh" /usr/local/bin/intel_update_check.sh
    install -m 0644 "$SETUP_DIR/systemd/intel-update-check.service" /etc/systemd/system/intel-update-check.service
    install -m 0644 "$SETUP_DIR/systemd/intel-update-check.timer" /etc/systemd/system/intel-update-check.timer
    systemctl daemon-reload
    systemctl enable --now intel-update-check.timer
    echo "    Intel update checker installed + enabled."
fi

echo "    Done."

# -----------------------------------------------------------
# 9b. Inference diagnostic logger + LAN health HTTP endpoint
# -----------------------------------------------------------
# This installs a 60s JSONL sampler, a port-8765 HTTP endpoint that serves the
# latest sample (so the main PC can check box health without SSH — crucial
# when sshd wedges under swap pressure), and a boot-forensics capture service.
# All units are OOM-protected with OOMScoreAdjust=-500.
echo ""
echo ">>> [9b] Installing inference diagnostic logger + LAN health endpoint"
DIAG_INSTALLER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_inference_diag.sh"
if [[ -f "$DIAG_INSTALLER" ]]; then
    bash "$DIAG_INSTALLER" || echo "    WARN: inference diag install reported a problem (continuing)"
else
    echo "    WARN: $DIAG_INSTALLER not found — skipping (re-run install_inference_diag.sh manually)"
fi

# -----------------------------------------------------------
# 10. Firewall & monitoring tools
# -----------------------------------------------------------
echo ""
echo ">>> [10/11] Firewall & monitoring"

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp comment "SSH" 2>/dev/null
    ufw allow 80/tcp comment "HTTP" 2>/dev/null
    ufw allow 443/tcp comment "HTTPS" 2>/dev/null
    ufw allow "${AGENT_PORT}/tcp" comment "Continue Agent API" 2>/dev/null
    ufw allow "${AUTOCOMPLETE_PORT}/tcp" comment "Continue Autocomplete API" 2>/dev/null
    ufw allow 8765/tcp comment "Inference diag HTTP" 2>/dev/null
    ufw --force enable 2>/dev/null
    echo "    Firewall: ports 22, 80, 443, ${AGENT_PORT}, ${AUTOCOMPLETE_PORT}, 8765 open"
fi

# Install xpu-smi
echo "    Installing xpu-smi..."
XPUSMI_URL=$(curl -s https://api.github.com/repos/intel/xpumanager/releases/latest 2>/dev/null | \
    python3 -c "
import json, sys
try:
    assets = [a['browser_download_url'] for a in json.load(sys.stdin).get('assets', []) if a.get('name', '').endswith('.deb')]
    ubuntu_assets = [u for u in assets if 'ubuntu' in u.lower() or 'u24' in u.lower()]
    if ubuntu_assets:
        print(ubuntu_assets[0])
    elif assets:
        print(assets[0])
except Exception:
    pass
" 2>/dev/null | head -1)
if [[ -n "$XPUSMI_URL" && "$XPUSMI_URL" == https://github.com/intel/xpumanager/* ]]; then
    XPUSMI_TMP=$(mktemp)
    wget -q "$XPUSMI_URL" -O "$XPUSMI_TMP"
    if file "$XPUSMI_TMP" | grep -q "Debian binary package"; then
        dpkg -i "$XPUSMI_TMP" 2>/dev/null || apt-get install -f -y -qq 2>/dev/null
        echo "    xpu-smi installed"
    else
        echo "    WARNING: Downloaded xpu-smi is not a valid .deb package"
    fi
    rm -f "$XPUSMI_TMP"
else
    echo "    WARNING: Could not find xpu-smi release. Install manually from github.com/intel/xpumanager/releases"
fi

echo "    Done."

# -----------------------------------------------------------
# 11. Summary
# -----------------------------------------------------------
echo ""
echo "================================================================"
echo "Intel B70 Coding Server Setup Complete!"
echo "================================================================"
echo ""
REBOOT_MSG=""
if [[ "${NEED_REBOOT}" == "true" ]]; then
    REBOOT_MSG=" (NEW KERNEL INSTALLED — REBOOT REQUIRED)"
fi
echo "  Kernel:       $(uname -r)${REBOOT_MSG}"
echo "  GPUs:         ${B70_COUNT}x Intel Arc Pro B70"
echo "  Models Dir:   /mnt/models"
echo ""
echo "Models configured for VS Code Continue:"
echo "  1. Agent (Chat/Edit/Plan):"
echo "     Model:        Qwen3-Coder 30B-A3B-Instruct (Q4_K_M, ~18.8 GB)"
echo "     Port:         ${AGENT_PORT}"
echo "     Service:      llama-agent.service (SYCL0 / Card 0)"
echo "     Start script: ~/start_agent.sh"
echo ""
echo "  2. Tab Autocomplete (Fast FIM):"
echo "     Model:        Qwen2.5-Coder 1.5B (Q8_0, ~1.6 GB)"
echo "     Port:         ${AUTOCOMPLETE_PORT}"
echo "     Service:      llama-autocomplete.service (SYCL1 / Card 1)"
echo "     Start script: ~/start_autocomplete.sh"
echo ""
echo "Active services:"
echo "  systemctl status llama-agent"
echo "  systemctl status llama-autocomplete"
echo "  systemctl status gpu-thermal-watchdog"
echo ""
echo "----------------------------------------------------------------"
echo "VS Code Continue configuration (~/.continue/config.json):"
echo "----------------------------------------------------------------"
cat "${CONTINUE_DIR}/config.json.example" 2>/dev/null || true
echo ""
echo "----------------------------------------------------------------"
echo ""

if [[ "${NEED_REBOOT}" == "true" ]]; then
    echo "================================================================"
    echo "  REBOOT REQUIRED for new kernel and GRUB parameters!"
    echo "  Run: sudo reboot"
    echo "================================================================"
fi

echo ""
echo "Log saved to: ${LOG}"
