---
title: "Qwen 3.6 27B with Native MTP on llama.cpp"
date: 2026-05-13 15:54:41 -0300
categories: [AI, Engineering]
tags: [llama.cpp, Qwen, MTP, speculative-decoding, GGUF, CUDA, Unsloth]
description: "Testing Unsloth's Qwen 3.6 27B MTP GGUF on an RTX 3090 with llama.cpp's MTP branch: native speculative decoding, no draft model, real speedup."
pin: false
math: false
mermaid: false
---

Unsloth released [`unsloth/Qwen3.6-27B-MTP-GGUF`](https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF), a GGUF build of Qwen 3.6 27B with the model's native Multi-Token Prediction heads preserved. That makes speculative decoding possible without a separate draft model.

This is the interesting part: MTP is not the usual “small model drafts for large model” setup. Qwen 3.6 already contains prediction heads trained to guess the next few tokens. llama.cpp's MTP branch can use those heads directly, validate the draft tokens, and skip part of the normal one-token-at-a-time decode loop.

I tested `unsloth/Qwen3.6-27B-MTP-GGUF`, using the recommended `UD-Q4_K_XL` quant, on an RTX 3090.

## The model

Repository:

[`unsloth/Qwen3.6-27B-MTP-GGUF`](https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF)

Quant tested:

```text
UD-Q4_K_XL
```

The model is Qwen 3.6 27B in GGUF form with MTP tensors preserved. Standard GGUFs of the same base model are not enough; the speculative heads need to be present in the file.

Unsloth's model card recommends:

```bash
-hf unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL \
-ngl 99 \
-c 8192 \
-fa on \
-np 1 \
--spec-type mtp \
--spec-draft-n-max 2
```

The key flags are `--spec-type mtp` and `--spec-draft-n-max 2`. That tells llama.cpp to use the model's own MTP head and draft up to two tokens ahead.

## The llama.cpp branch

MTP support currently needs a branch with the MTP serving code. I used [`am17an/llama.cpp`, branch `mtp-clean`](https://github.com/am17an/llama.cpp/tree/mtp-clean):

```bash
git clone -b mtp-clean https://github.com/am17an/llama.cpp.git
cmake llama.cpp -B llama.cpp/build \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_CUDA=ON
cmake --build llama.cpp/build \
  --config Release \
  -j \
  --target llama-server
```

Sanity check:

```bash
llama-server --help | grep -- '--spec-type'
```

Expected output includes:

```text
--spec-type [none|mtp|...]
```

That one line matters. Without `mtp` in the supported `--spec-type` list, the benchmark is not using native MTP.

## Run command

The tested server command:

```bash
llama-server \
  -hf unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL \
  -ngl 99 \
  -c 8192 \
  -fa on \
  -np 1 \
  --split-mode none \
  --main-gpu 0 \
  --jinja \
  --chat-template-kwargs '{"enable_thinking":false,"preserve_thinking":true}' \
  --spec-type mtp \
  --spec-draft-n-max 2
```

This keeps the test narrow: one model, one GPU, one slot, native MTP enabled.

## Results

Hardware: RTX 3090 24 GB. Context: 8K. Quant: `UD-Q4_K_XL`.

### Short coding response

Prompt: write an iterative Python Fibonacci function. Completion length: 76 tokens.

| Mode | Decode tok/s | Wall time | Draft tokens | Accepted draft tokens | Speedup |
|---|---:|---:|---:|---:|---:|
| Baseline | 35.3 | 2.44s | — | — | 1.00× |
| MTP | 62.7 | 1.54s | 50 | 50 | **1.77×** |

The short response is the cleanest demonstration. The MTP head drafted 50 tokens and all 50 were accepted. Decode speed jumped from 35.3 tok/s to 62.7 tok/s.

### Medium planning response

Prompt: write a concise implementation plan for a Python SQLite todo CLI. Completion length: 420 tokens.

| Mode | Decode tok/s | Wall time | Draft tokens | Accepted draft tokens | Speedup |
|---|---:|---:|---:|---:|---:|
| Baseline | 34.6 | 12.44s | — | — | 1.00× |
| MTP | 51.9 | 8.46s | 334 | 251 | **1.50×** |

On the longer response, the acceptance rate settled around 75%. The speedup stayed useful: 1.5× over the same model without MTP.

## VRAM

At 8K context, the run used roughly:

```text
19.98 GB on RTX 3090
```

That fits comfortably enough on a 24 GB card for a single local coding model. The important part is that this measurement includes the MTP-capable `UD-Q4_K_XL` quant running with CUDA offload on the main GPU.

## Why this is useful

Coding agents spend much of their time producing short structured outputs:

- tool calls
- arguments
- shell commands
- small patches
- JSON snippets
- brief plans

Those are exactly the workloads where MTP has the best shape. The model does not need to write thousands of tokens for the speedup to matter. It needs to shave latency off many small decode steps.

That is what the benchmark showed. A 76-token coding response improved by 1.77×. A 420-token planning response improved by 1.50×. Those numbers are enough to matter in an agent loop.

## What to verify in your own run

The response timings should expose draft metrics:

```json
{
  "draft_n": 334,
  "draft_n_accepted": 251
}
```

If those fields are present, the server is actually using speculative decoding. If they are absent, you are only measuring normal decoding.

The minimum checks:

```bash
llama-server --help | grep -- '--spec-type'
# must include mtp

# launch must include:
--spec-type mtp
--spec-draft-n-max 2
-np 1
```

## Takeaway

Unsloth's Qwen 3.6 27B MTP GGUF plus llama.cpp's MTP branch gives a simple local path to native speculative decoding:

- no external draft model
- no second model in VRAM
- one GGUF with preserved MTP heads
- 1.5×–1.8× speedup in these RTX 3090 tests

For local coding agents, this is the right kind of optimization: lower latency per step, not just better peak throughput on synthetic long generations.

---

*Written with [GPT-5.5 High](https://openai.com/codex/)*
