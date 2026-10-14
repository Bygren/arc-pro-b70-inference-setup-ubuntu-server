# Installations- och Konfigurationsguide: Intel Arc Pro B70 AI-Kodserver

En komplett steg-för-steg-guide för att sätta upp en lokal AI-kodserver baserad på **Intel Arc Pro B70 (32GB VRAM)** och **Ubuntu Server 26.04 LTS (eller 24.04 LTS)**, optimerad för **VS Code med Continue**.

---

## Maskinvaruspecifikation (Referenssystem)

* **GPU:** Intel Arc Pro B70 (32GB VRAM, Battlemage Xe2-arkitektur)
* **Processor (CPU):** AMD Ryzen 9 9900X (12 kärnor / 24 trådar, 4.4 GHz basklock, 76MB cache)
* **Moderkort:** ASUS ROG Crosshair X870E Hero (PCIe 5.0)
* **Primärminne (RAM):** Kingston 64GB DDR5 6000MHz
* **Lagring (SSD):** WD Black SN7100 1TB NVMe PCIe 4.0
* **Nätaggregat (PSU):** Phanteks 1000W Platinum
* **CPU-kylning:** be quiet! Pure Rock Pro 3 Black
* **Chassi:** Fractal Design North XL Svart
* **Operativsystem:** Ubuntu Server 26.04 LTS

> **Repogrund:** Baserat på [Bygren/arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Bygren/arc-pro-b70-inference-setup-ubuntu-server) (förgrenat från [Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server)), med integrerade optimeringar och 11 Xe2-prestandapatchar från [Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes](https://github.com/Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes), fullt stöd för Intel oneAPI Base Toolkit, Ubuntu 26.04-drivrutinsdetektering samt automatisk installation av kodmodeller för VS Code Continue.

---

## Modellarkitektur för Continue

Systemet kör två oberoende `llama-server`-processer med Intels hårdvaruoptimerade **SYCL-backend**:

| Roll i Continue | Modell | Kvantisering | Port | Enhet | VRAM | Funktion |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Agent / Chat / Edit** | **Qwen3-Coder 30B-A3B-Instruct** | Q4_K_M | `8000` | `SYCL0` | ~18.8 GB | Chatta, resonera, skriva och redigera kod i projektet (32K kontext) |
| **Tab Autocomplete** | **Qwen2.5-Coder-1.5B** | Q8_0 | `8001` | `SYCL1`* | ~1.6 GB | Blixtsnabb rad- och blockkomplettering i realtid (<15 ms per token) |

*\*Har systemet 1 st GPU körs båda modellerna på `SYCL0` (18.8 + 1.6 = ~20.4 GB av kortets 32GB VRAM). Vid multi-GPU isoleras autocomplete till GPU 1 så att skrivflödet aldrig störs av tunga agentkörningar.*

---

## Steg 1: Förbered BIOS / UEFI (Kritiskt)

Innan installation av operativsystem och drivrutiner måste moderkortet konfigureras så att processorn kan adressera hela grafikminnet på 32GB:

1. Starta datorn och tryck `DEL` eller `F2` för att gå in i BIOS (ASUS ROG UEFI).
2. Ställ in följande:
   * **Above 4G Decoding:** `ENABLED`
   * **Resizable BAR (ReBAR):** `ENABLED`
   * **CSM (Compatibility Support Module):** `DISABLED` (Kör enbart ren UEFI)
   * **Primary Display:** Sätt till `PEG / PCIe Slot` (Prioriterar Arc Pro B70 framför Ryzen 9900X inbyggda grafik)
   * **PCIe Link Speed:** Sätt till `Gen 4` eller `Gen 5` (eller `Auto`)
3. Spara och starta om (`F10`).

---

## Steg 2: Rensa eventuella gamla AI-tjänster och drivrutiner

Om systemet har använts tidigare med Ollama eller Nvidia-grafikkort, städa bort dessa så att portar och drivrutiner inte krockar:

```bash
# Stoppa och ta bort Ollama om den installerats tidigare
sudo systemctl stop ollama.service 2>/dev/null || true
sudo systemctl disable ollama.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/ollama.service
sudo systemctl daemon-reload

# Rensa eventuella Nvidia-drivrutiner
sudo apt remove --purge '^nvidia-.*' -y 2>/dev/null || true
sudo apt autoremove -y
```

---

## Steg 3: Kör installationsskriptet

Allt som tidigare krävde manuella kloningar, PPA-tillägg och egna kompileringar är nu samlat i installationsskriptet.

### Klona repot och kör:

```bash
# Klona repot via SSH (eller HTTPS)
git clone git@github.com:Bygren/arc-pro-b70-inference-setup-ubuntu-server.git
cd arc-pro-b70-inference-setup-ubuntu-server

# Ge körrättighet och kör som root
chmod +x odin-b70-setup.sh
sudo ./odin-b70-setup.sh
```

### Vad skriptet gör automatiskt:
1. **Linux-kärna 6.17+ & Drivrutiner:** Installerar Intel Xe KMD-drivrutin, firmware och Intel compute-runtime.
2. **Intel oneAPI Base Toolkit:** Installerar Intels officiella DPC++-kompilator (`icx`/`icpx`), oneMKL och oneDNN.
3. **Mesa-detektering för Ubuntu 26.04:** Använder Ubuntu 26.04:s inbyggda moderna Mesa-stack (och undviker instabila externa PPA-arkiv).
4. **Docker & Nätverkskonfiguration:** Installerar Docker och konfigurerar automatiskt `/etc/docker/daemon.json` med adresspool `172.30.0.0/16` (subnät `size: 24`) för att undvika IP- och routingkrockar med det lokala nätverket.
5. **llama.cpp med 11 Xe2-prestandapatchar:** Kompilerar `llama-server` med native SYCL-acceleration för Battlemage (MoE MMVQ kernels, Xe2 warptiles, minnesfixar).
6. **Modellnedladdning:** Hämtar automatiskt:
   * `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` till `/mnt/models`
   * `qwen2.5-coder-1.5b-instruct-q8_0.gguf` till `/mnt/models`
7. **Systemd-tjänster:** Skapar och aktiverar automatiskt `llama-agent.service` (port 8000) och `llama-autocomplete.service` (port 8001).
8. **Brandvägg:** Öppnar portarna 22 (SSH), 8000 (Agent), 8001 (Autocomplete) och 8765 (Inference Diagnostic HTTP) i UFW.

---

## Steg 4: Starta om servern

Efter att skriptet har körts klart krävs en omstart för att den nya Linux-kärnan och Xe-drivrutinen ska laddas:

```bash
sudo reboot
```

---

## Steg 5: Verifiera att hårdvara och tjänster fungerar

Logga in på servern igen efter omstarten och kontrollera statusen:

### 1. Snabb systemstatus via sysinfo
```bash
~/sysinfo.sh
```
*Detta skript ger dig en direkt översikt av IP-adress, kärna, GPU-temperaturer, Vulkan-enheter och hälsostatus för Continue Agent (port 8000) och Autocomplete (port 8001).*

### 2. Kontrollera grafikkortet
```bash
# Verifiera att B70 identifieras på PCIe-bussen
lspci -v | grep -i VGA
# Ska visa "Intel Corporation Battlemage G31" eller enhet e223

# Verifiera att xe-drivrutinen är aktiv
lsmod | grep xe
```

### 3. Övervaka GPU i realtid
```bash
xpu-smi
```
*Här ser du kortets klockfrekvens, temperatur, strömförbrukning och VRAM-allokering.*

### 4. Kontrollera AI-tjänsterna
```bash
# Kontrollera Agent-tjänsten (Qwen3-Coder)
sudo systemctl status llama-agent

# Kontrollera Autocomplete-tjänsten (Qwen2.5-Coder)
sudo systemctl status llama-autocomplete
```

### 5. Testa endpointsen via curl
```bash
# Testa Agent-endpointen (port 8000)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3-coder-30b","messages":[{"role":"user","content":"Skriv en hej-värld i Python"}],"max_tokens":50}'

# Testa Autocomplete-endpointen (port 8001)
curl http://localhost:8001/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-1.5b","prompt":"def fibonacci(n):\n","max_tokens":30}'

# Testa hälsosidan för diagnos (port 8765)
curl -s http://localhost:8765/ | python3 -m json.tool
```

---

## Steg 6: Konfigurera Continue i VS Code

Öppna VS Code på din utvecklingsdator och öppna Continues konfigurationsfil (klicka på kugghjulet i Continue eller öppna `~/.continue/config.json`):

### Alternativ A: JSON-format (`~/.continue/config.json`)

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

### Alternativ B: YAML-format (`~/.continue/config.yaml`)

```yaml
models:
  - title: Qwen3 Coder 30B (Agent)
    provider: openai
    model: qwen3-coder-30b
    apiBase: http://<SERVER-IP>:8000/v1
    contextLength: 32768

tabAutocompleteModel:
  title: Qwen2.5 Coder 1.5B (Autocomplete)
  provider: openai
  model: qwen2.5-coder-1.5b
  apiBase: http://<SERVER-IP>:8001/v1

allowAnonymousTelemetry: false
```

> **Tips:** Ersätt `<SERVER-IP>` med IP-adressen till din server i det lokala nätverket (t.ex. `http://192.168.1.50:8000/v1`), eller `http://localhost:8000/v1` om du kör VS Code direkt på servern.

---

## Manuell drift och felsökning

Om du föredrar att köra serverprocesserna manuellt i en terminal istället för som systemd-bakgrundstjänster finns färdiga startskript installerade i din hemkatalog:

```bash
# Stoppa bakgrundstjänsterna först
sudo systemctl stop llama-agent llama-autocomplete

# Starta Agent manuellt (port 8000)
~/start_agent.sh

# Starta Autocomplete manuellt (port 8001 i en ny terminal)
~/start_autocomplete.sh
```

### Förklaring av de kritiska miljövariablerna och flaggorna:
* `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1`: Tar bort Level Zeros standardspärr och låter programmet allokera upp till hela kortets 32GB minne.
* `GGML_SYCL_DISABLE_OPT=1`: **Obligatorisk för MoE-modeller (Qwen3).** Förhindrar att modellens slot-initiering krockar med drivrutinen och stänger av servern.
* `-fa 0`: Stänger av Flash Attention. SYCL:s Flash Attention är ännu inte helt stabil på MoE på Intel B70; standardattention med de 11 Xe2-patcharna ger ändå maximal prestanda.
* `--defrag-thold 0.1`: Defragmenterar automatiskt KV-cachen när fragmenteringen överstiger 10 %, vilket håller tok/s stabil över långa kodsessioner.
* `-t 1`: Använder 1 CPU-avlastningstråd. Fler CPU-trådar skapar kö-kollisioner på PCIe/Xe2-arkitekturen och sänker prestandan.
* `--device SYCL0`: Binder processen till specifik Intel Arc Pro-GPU.

---

## Hur du byter eller uppgraderar en modell

Att byta ut en modell görs i tre snabba steg utan att du behöver installera om eller bygga om AI-motorn. 

Här är ett konkret exempel där vi byter ut Agent-modellen från **Qwen3-Coder 30B-A3B** till **Devstral Small 2 24B Instruct 2512** (utvecklad av Mistral AI & All Hands AI, ca 14.5 GB VRAM i Q4_K_M-format).

### Steg 1: Ladda ner den nya modellen till `/mnt/models`

Kör följande Python-kommando på servern för att hämta GGUF-filen via `huggingface_hub`:

```bash
python3 - << 'EOF'
from huggingface_hub import hf_hub_download

repo = "unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF"
filename = "Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf"
dest = "/mnt/models"

print(f"Laddar ner {filename} från {repo}...")
hf_hub_download(repo_id=repo, filename=filename, local_dir=dest)
print("Nedladdning klar!")
EOF
```

### Steg 2: Uppdatera startskriptet (`~/start_agent.sh`)

Öppna startskriptet för agenten i en textredigerare:

```bash
nano ~/start_agent.sh
```

Ändra följande rader:
1. Peka på den nya modellfilen:
   ```bash
   MODEL_FILE="/mnt/models/Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf"
   ```
2. Ändra modellens alias:
   ```bash
   --alias devstral-small-24b
   ```

Spara filen (`Ctrl+O`, tryck `Enter`) och stäng nano (`Ctrl+X`).

> **💡 Behövs det några nya inställningar för SYCL eller omkompilering?**
>
> **Nej!** Du behöver varken kompilera om eller göra nya SYCL-installationer:
> 1. **Motorn är universell:** `llama-server`-binären i `/opt/llama.cpp/llama-sycl-build/bin/llama-server` är redan färdigkompilerad med oneAPI DPC++/SYCL och stöder alla GGUF-arkitekturer (Mistral, Devstral, Qwen, Llama, Gemma m.fl.).
> 2. **SYCL-inställningarna ärvs automatiskt:** Eftersom `~/start_agent.sh` redan innehåller:
>    - `source /opt/intel/oneapi/setvars.sh` (Initierar oneAPI-miljön)
>    - `--device SYCL0` (Styr körningen till Intel Arc Pro-grafikkortet)
>    - `-ngl 999` (Lägger alla modellens lager direkt i B70:s snabba VRAM)
>    - `export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1` (Låter SYCL allokera upp till 32GB VRAM)
>    ...kommer den nya modellen automatiskt att köras med full SYCL-acceleration på ditt Arc-kort!
> 3. **MoE vs Tät (Dense) modell:**
>    - `export GGML_SYCL_DISABLE_OPT=1`: Detta krävs specifikt för MoE-modeller (som Qwen3-Coder) för att undvika krasch vid slot-initiering. För Devstral (som är en standard tät modell) gör det ingen skada att låta den stå kvar, men du kan även ta bort den.
>    - `--reasoning off`: Stänger av tänkande `<think>`-block i Qwen-modeller. Devstral har ingen sådan mekanism, så flaggan ignoreras harmlöst.

Starta sedan om agent-tjänsten så att den laddar den nya modellen:

```bash
sudo systemctl restart llama-agent
```

Verifiera att den nya modellen körs och svarar:

```bash
sudo systemctl status llama-agent

# Testa anrop mot nya modellen
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"devstral-small-24b","messages":[{"role":"user","content":"Hej Devstral!"}],"max_tokens":30}'
```

### Steg 3: Uppdatera Continue i VS Code

Öppna Continues inställningar i VS Code (`~/.continue/config.json`) och uppdatera `model` och `title`:

```json
{
  "models": [
    {
      "title": "Devstral Small 2 24B (Agent)",
      "provider": "openai",
      "model": "devstral-small-24b",
      "apiBase": "http://<SERVER-IP>:8000/v1",
      "contextLength": 32768
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5 Coder 1.5B (Autocomplete)",
    "provider": "openai",
    "model": "qwen2.5-coder-1.5b",
    "apiBase": "http://<SERVER-IP>:8001/v1"
  }
}
```

Klart! Nu använder Continue din nya Devstral Small 2 24B-modell för agentkodning, chat och redigering, medan Qwen2.5-Coder 1.5B fortsätter att sköta autocomplete i bakgrunden.

