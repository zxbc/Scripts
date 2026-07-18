#Requires -Version 5.1
<#
.SYNOPSIS
  Launches BeeLlama.cpp v0.3.2 as a sidecar OpenAI-compatible server for
  Unsloth Studio and OpenHands.

.DESCRIPTION
  Loads a Qwen 3.6 27B Q4_K_M GGUF from Unsloth Studio's local HF cache
  with MTP speculative decoding (heads built into the model, auto-detected).

  Confirmed working on: build 10316 (fe67745db) v0.3.2 Preview, Clang 20.1.8,
  Windows x86_64, RTX 3090 24GB.
  Speed: ~30+ t/s with --spec-draft-n-max 2 (higher n-max hurts acceptance).

  Network: binds 0.0.0.0:8080 so it is reachable from:
    - Windows host:        http://127.0.0.1:8080/v1
    - WSL2:                http://host.docker.internal:8080/v1
                            (or the WSL2 eth0 host IP)
    - Docker in WSL2:      same as WSL2, via --add-host host.docker.internal
    - LAN:                 port 8080 (allow via Windows Firewall on Private)

  Tool use: passes --jinja so the embedded Qwen chat template (which includes
  the <tool_use> format) is used for request templating and tool parsing.

.NOTES
  --mlock is intentionally omitted: it fights Windows for the 32GB RAM pool
  and can cause paging pressure that hurts latency more than it helps.
  --kv-unified is included: the docs recommend it for single-slot long-context
  serving and proper cache behavior.
#>

# ============== CONFIG ==============
$Exe          = "I:\beellama\llama-server.exe"

# Model directory (root of the HF cache entry for this model)
$ModelDir     = "I:\unsloth\models\models--Brian6145--Qwen3.6-27B-Claude-Opus-DeepSeek-Distilled-Imatrix-MTP-GGUF"

# Blob hash. NO path prefix, NO extension.
$BlobHash     = "608f32ff2128e4ad1ba1c1f8da11fe88ef45b302b6f3eecd058a1b091286e04d"

$LogFile      = "I:\beellama\llama-server.log"

# Bind to all interfaces so Docker-in-WSL2 can reach us via host.docker.internal.
# 127.0.0.1 would only allow Windows-localhost access.
$HostAddr     = "0.0.0.0"
$Port         = 8080

# KV cache preset. KVarN (Walsh-Hadamard transform-domain compression) is
# specifically wired for Qwen3.6 head dimensions (128/256/512). kvarn5/kvarn4
# uses WHT + adaptive per-tile scaling to achieve ~28.3% of bf16 size with
# precision comparable to q5_0/q4_1 (32.8%), saving ~14% VRAM on the cache.
# Native CUDA FlashAttention consumption — no F16 materialization overhead.
# Override at launch:  $env:BEE_CTK = "q5_0"; $env:BEE_CTV = "q4_1"; .\beellama-launch.ps1
$CacheTypeK   = $(if ($env:BEE_CTK) { $env:BEE_CTK } else { "kvarn5" })
$CacheTypeV   = $(if ($env:BEE_CTV) { $env:BEE_CTV } else { "kvarn4" })

# Context & batch
$ContextSize  = 131072
$BatchSize    = 2048
$UbatchSize   = 512

# Speculative decoding via the model's own MTP heads (~1.8x speedup).
# MTP is auto-detected from model metadata -- no --spec-type flag needed.
# n-max=2 is the sweet spot for this model (Qwen docs confirm).
$SpecDraftNMax = 2

# Friendly model name advertised on /v1/models. Use this exact string as
# the "model" field in OpenHands / OpenAI-compatible clients.
$ModelAlias   = "qwen3.6-27b"

$MinModelSize = 1GB

# ============== COMPUTE BLOB PATH ==============
$ModelPath = Join-Path $ModelDir "blobs\$BlobHash"

# ============== SANITY CHECKS ==============
$fail = $false

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "FATAL: llama-server.exe not found at: $Exe" -ForegroundColor Red
    $fail = $true
}

if (-not (Test-Path -LiteralPath $ModelPath)) {
    Write-Host "FATAL: Model blob not found at: $ModelPath" -ForegroundColor Red
    Write-Host "  Check that ModelDir and BlobHash are correct." -ForegroundColor Red
    $fail = $true
} else {
    $ModelInfo = Get-Item -LiteralPath $ModelPath
    $SizeBytes = $ModelInfo.Length
    if ($SizeBytes -lt $MinModelSize) {
        Write-Host "FATAL: Model blob is too small: $SizeBytes bytes" -ForegroundColor Red
        Write-Host "  Path:     $ModelPath" -ForegroundColor Red
        Write-Host "  Expected: at least $([math]::Round($MinModelSize/1GB, 2)) GB" -ForegroundColor Red
        $fail = $true
    }
}

if ($fail) { exit 1 }

# ============== BANNER ==============
Write-Host ""
Write-Host "========================================"
Write-Host " BeeLlama v0.3.2 Sidecar Launch"
Write-Host "========================================"
Write-Host " Target:    $ModelPath"
Write-Host " Size:      $($SizeBytes.ToString('N0')) bytes ($([math]::Round($SizeBytes/1GB, 2)) GB)"
Write-Host " Endpoint:  http://$HostAddr`:$Port/v1"
Write-Host " Context:   $ContextSize tokens  (batch=$BatchSize, ubatch=$UbatchSize)"
Write-Host " GPU:       all layers offloaded"
Write-Host " Cache:     K=$CacheTypeK  V=$CacheTypeV"
Write-Host " Spec:      MTP (n-max=$SpecDraftNMax)"
Write-Host " Alias:     $ModelAlias"
Write-Host " Log:       $LogFile"
Write-Host "========================================"
Write-Host ""
Write-Host "Reachable from:"
Write-Host "  Windows host:        http://127.0.0.1:$Port/v1"
Write-Host "  WSL2 / Docker:       http://host.docker.internal:$Port/v1"
Write-Host ""
Write-Host "Model name for clients: $ModelAlias"
Write-Host ""

# Pass JSON kwargs via env var to avoid PowerShell argument parsing issues
$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"preserve_thinking":true}'

# ============== ARGS ==============

$argList = @(
    # Model & GPU placement
    "-m",                  $ModelPath
    "-ngl",                "all"

    # Context & batching
    "-c",                  $ContextSize
    "-b",                  $BatchSize
    "-ub",                 $UbatchSize
    "-np",                 "1"
    "--kv-unified"

    # KV cache precision (q5_0 K / q4_1 V — docs sweet spot)
    "-ctk",                $CacheTypeK
    "-ctv",                $CacheTypeV

    # Speculative decoding: MTP (auto-detected, fixed n-max)
    "--spec-draft-n-max",  $SpecDraftNMax

    # Attention & memory
    "--flash-attn",        "on"
    "--no-mmap"
    "--no-host"

    # Reasoning (agentic work)
    "--reasoning",         "on"

    # Sampling (balanced for agentic use)
    "--temp",              "0.6"
    "--top-k",             "20"
    "--min-p",             "0.0"

    # Template engine & alias
    "--jinja"
    "--alias",             $ModelAlias

    # Server endpoints
    "--host",              $HostAddr
    "--port",              $Port
    "--metrics"

    # Logging
    "--log-timestamps"
    "--log-prefix"
    "--log-colors",        "off"
    "--log-verbosity",     "2"
)

Write-Host "Starting BeeLlama server (Ctrl-C in this window to stop)..." -ForegroundColor Green
Write-Host ""

& $Exe @argList 2>&1 | Tee-Object -FilePath $LogFile