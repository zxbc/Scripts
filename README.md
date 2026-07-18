# Scripts

Personal utility scripts.

---

## beellama-launch.ps1

Launches [BeeLlama.cpp](https://github.com/ggml-org/beellama) v0.3.2 as a sidecar OpenAI-compatible server for **Unsloth Studio** and **OpenHands**.

Loads a **Qwen 3.6 27B Q4_K_M** GGUF (Claude-Opus-DeepSeek distilled with Imatrix MTP) from the local HuggingFace cache and exposes an OpenAI-compatible endpoint at `http://0.0.0.0:8080/v1`.

### Hardware

| Component | Detail |
|---|---|
| GPU | RTX 3090 24 GB |
| RAM | 32 GB |
| OS | Windows 11 (PowerShell 5.1+) |
| Build | BeeLlama v0.3.2 Preview, build 10316 (fe67745db), Clang 20.1.8, CUDA |

### Configurable Variables

Edit these at the top of the script to adjust behavior:

| Variable | Default | Description |
|---|---|---|
| `$Exe` | `I:\beellama\llama-server.exe` | Path to the BeeLlama server binary |
| `$ModelDir` | `I:\unsloth\models\...` | Root of the HF cache entry for this model |
| `$BlobHash` | `608f32ff...` | GGUF blob hash (no path prefix, no extension) |
| `$LogFile` | `I:\beellama\llama-server.log` | Server log output path |
| `$HostAddr` | `0.0.0.0` | Bind address (`127.0.0.1` for local-only) |
| `$Port` | `8080` | Server port |
| `$CacheTypeK` | `q5_0` | KV cache precision for K (override via `$env:BEE_CTK`) |
| `$CacheTypeV` | `q4_1` | KV cache precision for V (override via `$env:BEE_CTV`) |
| `$ContextSize` | `93184` | Context window in tokens |
| `$BatchSize` | `2048` | Logical prompt batch size |
| `$UbatchSize` | `512` | Physical microbatch size (keeps VRAM spikes in check during prefill) |
| `$SpecDraftNMax` | `2` | MTP speculative draft max (Qwen docs confirm 2 is ideal for quality/speed) |
| `$ModelAlias` | `qwen3.6-27b` | Name advertised at `/v1/models` (use this in OpenAI-compatible clients) |
| `$MinModelSize` | `1GB` | Minimum model file size for sanity check |

### Environment Variable Overrides

KV cache types can be overridden without editing the script:

```powershell
$env:BEE_CTK = "q4_0"; $env:BEE_CTV = "q4_0"; .\beellama-launch.ps1
```

### Server Arguments & Rationale

#### Model & GPU

| Flag | Value | Why |
|---|---|---|
| `-m` | *model path* | GGUF model file |
| `-ngl` | `all` | Offload all layers to GPU |

#### Context & Batching

| Flag | Value | Why |
|---|---|---|
| `-c` | `93184` | ~91k usable context after chat template overhead |
| `-b` | `2048` | Upstream default logical batch |
| `-ub` | `512` | Microbatch: keeps VRAM spikes in check during prefill at long context |
| `-np` | `1` | Single slot — simplest and most memory-efficient |
| `--kv-unified` | *(flag)* | Unified KV buffer across slots; recommended by docs for single-slot long-context serving and proper cache behavior |

#### KV Cache Precision

| Flag | Value | Why |
|---|---|---|
| `-ctk` | `q5_0` | K cache at 5.5 bpv — strong precision for attention keys |
| `-ctv` | `q4_1` | V cache at 5.0 bpv — smaller footprint, good tail precision |

Together: **32.8% of bf16 size, 92.65% precision** — the docs' recommended sweet spot for VRAM-constrained setups at long context.

#### Speculative Decoding

| Flag | Value | Why |
|---|---|---|
| `--spec-draft-n-max` | `2` | MTP speculative decoding (heads built into the model, auto-detected from GGUF metadata). `n-max=2` is the sweet spot for this model — higher values hurt acceptance rate. ~1.8x speedup on structured code. |

**Note:** MTP is auto-detected from the model metadata — no `--spec-type` flag is needed or valid.

#### Attention & Memory

| Flag | Value | Why |
|---|---|---|
| `--flash-attn` | `on` | Flash Attention kernels for faster attention computation at long context |
| `--no-mmap` | *(flag)* | Avoid relying on filesystem mmap behavior on Windows (unreliable with reparse points) |
| `--no-host` | *(flag)* | Bypass host buffer for more backend buffer space |

**Note:** `--mlock` is intentionally **omitted** — it fights Windows for the 32 GB RAM pool and causes paging pressure that hurts latency more than it helps.

#### Reasoning (Agentic Work)

| Flag | Value | Why |
|---|---|---|
| `--reasoning` | `on` | Enable thinking/reasoning output handling |
| `--chat-template-kwargs` | `{"preserve_thinking":true}` | Preserve thinking tokens across turns so the model has full context for follow-up reasoning — critical for multi-turn agentic work |

#### Sampling

| Flag | Value | Why |
|---|---|---|
| `--temp` | `0.6` | Moderate temperature — stable enough for code/tool use, still creative for reasoning |
| `--top-k` | `20` | Restrict token pool for determinism |
| `--min-p` | `0.0` | Disabled — top-k already constrains the token pool adequately at 0.6 temperature |

These settings are tuned for **agentic coding work**: deterministic enough for tool use and code generation, but with enough variance for reasoning and problem-solving.

#### Template Engine & Alias

| Flag | Value | Why |
|---|---|---|
| `--jinja` | *(flag)* | Use Jinja2 chat template engine (required for the Qwen tool-use `<tool_use>` format) |
| `--alias` | `qwen3.6-27b` | Friendly model name advertised at `/v1/models` |

#### Server Endpoints

| Flag | Value | Why |
|---|---|---|
| `--host` | `0.0.0.0` | Bind all interfaces so WSL2/Docker can reach via `host.docker.internal` |
| `--port` | `8080` | Standard HTTP port |
| `--metrics` | *(flag)* | Expose Prometheus-compatible metrics endpoint |

#### Logging

| Flag | Value | Why |
|---|---|---|
| `--log-timestamps` | *(flag)* | Timestamped log lines |
| `--log-prefix` | *(flag)* | Structured log prefix |
| `--log-colors` | `off` | Disable ANSI colors for clean file output |
| `--log-verbosity` | `2` | Standard verbosity level |

### Network Access

| Environment | URL |
|---|---|
| Windows host | `http://127.0.0.1:8080/v1` |
| WSL2 | `http://host.docker.internal:8080/v1` |
| Docker (WSL2 backend) | `http://host.docker.internal:8080/v1` |
| LAN | `http://<your-windows-ip>:8080/v1` |

### Usage

```powershell
.\beellama-launch.ps1
```

Press **Ctrl-C** to stop. Server output is tee'd to the console and `$LogFile`.

### Estimated VRAM Budget

| Component | Estimated VRAM |
|---|---|
| Q4_K_M model weights (27B) | ~15.5–16 GB |
| KV cache (q5_0/q4_1, ~91k ctx) | ~4–5 GB |
| CUDA graph / scratch / overhead | ~1–2 GB |
| **Total** | **~21–23 GB** |

Fits comfortably on a 24 GB RTX 3090 with some headroom.
