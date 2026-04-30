---
title: Running NVIDIA Nemotron 30B with Vision on a 24 GB GPU
date: 2026-04-29 22:15:00 -0300
categories: [AI, Hardware]
tags: [nemotron, nvidia, gguf, vision, llm, local-llm, rtx-3090, llama-cpp]
description: How to fit NVIDIA's Nemotron-3-Nano-30B multimodal model with vision support on a single RTX 3090 — benchmarks, VRAM tricks, and the surprising resolution behavior.
pin: false
math: false
mermaid: false
---

I have a single RTX 3090 (24 GB) and I wanted to run NVIDIA's new [Nemotron-3-Nano-30B-A3B-Reasoning](https://huggingface.co/nvidia/Nemotron-3-Nano-30B-A3B-Reasoning) — a 31B parameter MoE model with vision support. The question was simple: would it fit? Here's what I found.

## The setup

The model is available as a GGUF on [unsloth/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF](https://huggingface.co/unsloth/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF). I downloaded the `UD-IQ4_NL` quant (18.19 GiB) — a 4-bit dynamic quantization that balances quality and size — and the accompanying `mmproj-F16` vision projector (1.48 GiB).

```bash
hf download unsloth/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF \
  --include "UD-IQ4_NL*" --local-dir ~/models/nemotron-vl

hf download unsloth/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF \
  --include "mmproj*" --local-dir ~/models/nemotron-vl
```

I run [llama-swap](https://github.com/mystic-ai/llama-swap) as a model proxy, backed by [llama.cpp](https://github.com/ggml-org/llama.cpp) (turboquant fork). The RTX 3090 is isolated as GPU 0 — no splitting across GPUs, which would tank throughput on this MoE model.

## Fitting vision on a 24 GB card — the trick

Loading the model + mmproj + 64K context at once caused an immediate OOM — `cudaGraphInstantiate` failed because CUDA graph capture buffers couldn't fit in the remaining VRAM.

The trick was  **`--no-mmproj-offload`** . This flag keeps the vision projector (mmproj) on the CPU instead of loading it into GPU VRAM:

```yaml
# llama-swap model config — vision variant
name: nemotron-3-nano-30b-a3b-vl
model: ~/models/nemotron-vl/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-UD-IQ4_NL.gguf
mmproj: ~/models/nemotron-vl/mmproj-nemotron-3-nano-30b-f16.gguf
ctx_size: 32768
no_mmproj_offload: true
```

This saves ~1.5 GB of VRAM — enough to fit the model comfortably. I also dropped context from 64K to 32K for the vision config, since multimodal use rarely needs massive context windows.

With this configuration, VRAM usage sits at **23,119 MiB** — leaving about 900 MiB of headroom on the 24 GB card.

## Performance — text mode

Text-only inference at 64K context is fast on turboquant:

| Metric | Value |
|--------|-------|
| Prompt processing | 3,294 tok/s |
| Text generation | 104.6 tok/s |
| TTFT (time to first token) | 1.38 s |
| VRAM | 23,119 MiB |

For a 31B MoE model running on consumer hardware, 105 tok/s is solid — roughly on par with a 70B at Q4 on 48 GB.

## Performance — vision mode

The vision config (32K, mmproj on CPU) has identical generation performance:

| Metric | Text (64K) | Vision (32K) | Δ |
|--------|-----------|--------------|---|
| Prompt processing | 3,294 tok/s | 3,335 tok/s | +1% |
| Text generation | 104.6 tok/s | 104.6 tok/s | = |
| TTFT | 1.38 s | 1.36 s | -1% |
| VRAM | 23,119 MiB | 23,119 MiB | = |

The key insight: **generation throughput is not affected by the mmproj being on CPU**. Only the image encoding step changes — and that's a one-time cost per unique image.

## The encoding cost

The first time you send an image to the model, the CPU-based mmproj processes it in about **4.7 seconds**:

```bash
# Send an image via the OpenAI-compatible API
curl -X POST http://localhost:5001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @payload.json
```

After that, the image tokens remain in the KV cache. Subsequent requests with the same image take only **~30 ms**:

| Request | Prompt time | Gen time | Total |
|---------|:-----------:|:--------:|:-----:|
| First (uncached) | 4,778 ms | 870 ms | ~5.6 s |
| Second (cached) | 32 ms | 893 ms | ~0.9 s |

Text generation after encoding consistently runs at **114.9 tok/s** — no penalty.

## Where it went sideways — the resolution trap

I tested images from 50×50 to 2048×2048, expecting higher-resolution inputs to produce more tokens and better detail:

| Image size | Prompt tokens | Encoding time |
|:----------:|:-------------:|:-------------:|
| 50×50 | 273 | 4,665 ms |
| 224×224 | 273 | 4,667 ms |
| 336×336 | 273 | 4,740 ms |
| 512×512 | 273 | 4,651 ms |
| 768×768 | 273 | 4,691 ms |
| 1024×1024 | 273 | 4,700 ms |
| 2048×2048 | 273 | 4,639 ms |

**Every single resolution produced exactly 273 prompt tokens.** All images are resized to the CLIP ViT's native **224×224** resolution (patch size 14 → 16×16 = 256 patches) before passing through the mmproj.

This means the model does **not** support high-resolution input natively. There's no dynamic tiling (like LLaVA-NeXT), no resolution scaling — everything gets squashed to 224×224. A 2048×2048 image loses just as much detail as a 512×512 one.

If you need vision at higher resolutions, this isn't the model for that use case. Consider a model with tiling support or a custom preprocessing pipeline.

## The config file

Here's the full llama-swap entry I settled on:

```yaml
- name: nemotron-3-nano-30b-a3b
  model: ~/models/nemotron-vl/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-UD-IQ4_NL.gguf
  ctx_size: 65536

- name: nemotron-3-nano-30b-a3b-vl
  model: ~/models/nemotron-vl/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-UD-IQ4_NL.gguf
  mmproj: ~/models/nemotron-vl/mmproj-nemotron-3-nano-30b-f16.gguf
  ctx_size: 32768
  no_mmproj_offload: true
```

Two configs: one for text (64K context, max throughput), one for vision (32K context, CPU-based mmproj). Swap between them via the API.

## Takeaway

Nemotron 30B fits on a 24 GB GPU with vision enabled — just barely, and with mmproj on CPU. The tradeoff is a ~5 second encoding cost per unique image, which is acceptable for chat and document analysis but not for video or real-time applications. Generation speed is identical to text-only mode, and KV caching makes repeated image queries instant.

The 224×224 resolution cap is the main limitation. For applications that need to read small text or analyze fine details, this model isn't the right choice. But for general image description, it works well and fits on hardware most enthusiasts already own.

---

*Written with [DeepSeek V4 Pro](https://deepseek.com/) (`deepseek-v4-pro`) via Hermes Agent / CrofAI.*
