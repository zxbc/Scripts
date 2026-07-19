# Scripts

Personal utility scripts.

---

## beellama-launch.ps1

Launches [BeeLlama.cpp](https://github.com/Anbeeld/beellama.cpp) v0.4.0 as a sidecar OpenAI-compatible server for **Unsloth Studio** and **OpenHands**.

Loads a **Qwen 3.6 27B Q4_K_M** GGUF (Claude-Opus-DeepSeek distilled with Imatrix MTP) from the local HuggingFace cache and exposes an OpenAI-compatible endpoint at `http://0.0.0.0:8080/v1`.

**v0.4.0 change:** MTP speculative decoding now requires explicit `--spec-type draft-mtp` (auto-detect was removed).

### Hardware

| Component | Detail |
|---|---|
| GPU | RTX 3090 24 GB |
| RAM | 32 GB |
| OS | Windows 11 (PowerShell 5.1+) |
| Build | BeeLlama v0.4.0 Preview, Windows x86_64, CUDA |

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
| `$CacheTypeK` | `kvarn5` | KV cache compression for K (override via `$env:BEE_CTK`) |
| `$CacheTypeV` | `kvarn4` | KV cache compression for V (override via `$env:BEE_CTV`) |
| `$ContextSize` | `131072` | Context window in tokens (128K) |
| `$BatchSize` | `2048` | Logical prompt batch size |
| `$UbatchSize` | `512` | Physical microbatch size (keeps VRAM spikes in check during prefill) |
| `$SpecDraftNMax` | `2` | MTP speculative draft max (Qwen docs confirm 2 is ideal for quality/speed) |
| `$ModelAlias` | `qwen3.6-27b` | Name advertised at `/v1/models` (use this in OpenAI-compatible clients) |
| `$MinModelSize` | `1GB` | Minimum model file size for sanity check |

### Environment Variable Overrides

KV cache types can be overridden without editing the script:

```powershell
# Fallback to standard quantized cache if KVarN causes issues:
$env:BEE_CTK = "q5_0"; $env:BEE_CTV = "q4_1"; .\beellama-launch.ps1
```

Available cache types: `kvarn2`–`kvarn8`, `q4_0`, `q4_1`, `q5_0`, `q5_1`, `q8_0`.

### Server Arguments & Rationale

#### Model & GPU

| Flag | Value | Why |
|---|---|---|
| `-m` | *model path* | GGUF model file |
| `-ngl` | `all` | Offload all layers to GPU |

#### Context & Batching

| Flag | Value | Why |
|---|---|---|
| `-c` | `131072` | 128K context window |
| `-b` | `2048` | Upstream default logical batch |
| `-ub` | `512` | Microbatch: keeps VRAM spikes in check during prefill at long context |
| `-np` | `1` | Single slot — simplest and most memory-efficient |
| `--kv-unified` | *(flag)* | Unified KV buffer across slots; recommended by docs for single-slot long-context serving and proper cache behavior |

#### KV Cache Compression (KVarN)

| Flag | Value | Why |
|---|---|---|
| `-ctk` | `kvarn5` | KVarN 5-bit: WHT transform + adaptive per-tile scaling for attention keys |
| `-ctv` | `kvarn4` | KVarN 4-bit: Same compression pipeline for attention values |

**What is KVarN?** A transform-domain KV cache compression scheme (v0.3.2 Preview, experimental):

1. Splits K/V into 128×128 tiles
2. Applies a **Walsh-Hadamard Transform** (WHT) — concentrates energy into fewer coefficients
3. Applies **adaptive per-column/per-row scaling** — each tile gets optimal normalization
4. Quantizes transformed coefficients to N bits (5 for K, 4 for V)

**Why it's better than q5_0/q4_1:**

| Metric | q5_0/q4_1 | kvarn5/kvarn4 |
|---|---|---|
| Memory vs bf16 | 32.8% | **28.3%** (~14% less VRAM) |
| Scaling | Fixed-group min/max (32 values) | Per-tile adaptive (128×128 values) |
| Quantization target | Raw values | WHT-transformed coefficients |
| FlashAttention | Requires F16 materialization | **Native consumption** (no materialization) |

At 128K context, kvarn5/kvarn4 saves ~0.7–0.8 GB VRAM vs q5_0/q4_1.

**Model support:** Specifically wired for Qwen3.6 head dimensions (128/256/512). Draft/auxiliary contexts stay on normal cache types — only the target context uses KVarN.

**Fallback:** If you encounter issues, revert to standard quantized cache via `$env:BEE_CTK = "q5_0"; $env:BEE_CTV = "q4_1"`.

#### Speculative Decoding

| Flag | Value | Why |
|---|---|---|
| `--spec-type` | `draft-mtp` | Explicit MTP type required in v0.4.0+ (auto-detect was removed) |
| `--spec-draft-n-max` | `2` | MTP speculative draft horizon (heads built into the model). `n-max=2` is the sweet spot — higher values hurt acceptance rate. ~1.8x speedup on structured code. |

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
| `$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS` | `{"preserve_thinking":true}` | Preserve thinking tokens across turns so the model has full context for follow-up reasoning — critical for multi-turn agentic work. Set via environment variable (not a CLI flag) to avoid PowerShell JSON quoting issues. |

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
| KV cache (kvarn5/kvarn4, 128K ctx) | ~4.3–5.2 GB |
| CUDA graph / scratch / overhead | ~1–2 GB |
| **Total** | **~21–23 GB** |

Fits on a 24 GB RTX 3090 with ~1–3 GB headroom. KVarN saves ~0.7–0.8 GB vs q5_0/q4_1.

If you hit OOM, try these fallbacks (in order):
1. Drop to `kvarn4/kvarn4` (~25% of bf16): `$env:BEE_CTK = "kvarn4"; $env:BEE_CTV = "kvarn4"`
2. Revert to standard quantized cache: `$env:BEE_CTK = "q5_0"; $env:BEE_CTV = "q4_1"`
3. Reduce context to 65536: edit `$ContextSize` in the script
