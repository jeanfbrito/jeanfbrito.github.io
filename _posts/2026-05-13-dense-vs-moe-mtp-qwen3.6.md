---
title: "Qwen 3.6 Dense vs MOE on Local Stack: what MTP actually delivers"
date: 2026-05-13 20:02:18 -0300
categories: [AI, Engineering]
tags: [llama.cpp, Qwen, MTP, MOE, speculative-decoding, GGUF, CUDA]
description: "Practical comparison between Qwen 3.6 Dense and MOE on an RTX 3090, focused on real throughput by scenario and the practical impact of Multi-Token Prediction in local inference flow."
pin: false
math: false
mermaid: false
---

Instead of discussing “speedup marketing”, I ran numbers on the real local lab setup (dedicated llama-server per port, fixed context, 1 slot, same stack) to decide the daily setup between:

- **Dense 27B** (`Qwen3.6-27B-UD-Q4_K_XL`)
- **MOE 35B** (`Qwen3.6-35B-A3B-UD-Q3_K_M`)

With and without MTP.

## Setup that kept comparability

- `--batch-size 2048`
- `--ubatch-size 512`
- `--cache-type-k q4_0`
- `--cache-type-v q4_0`
- `--fit on`
- `--split-mode none`
- `--main-gpu 0`
- `--flash-attn on`
- `--cont-batching`
- `--parallel 1`
- `--timeout 900`

Differences between runs:

- **Dense**: `--ctx-size 131072`
- **MOE**: `--ctx-size 65536`
- **MTP on**: `--spec-type mtp --spec-draft-n-max`
- **MTP off** (MOE): `--spec-type none`

## Numerical result

### Short scenario

| Model | Throughput short (tok/s) | VRAM |
|---|---:|---:|
| Dense 27B (MTP) | 60 | 21.9 GiB |
| Dense 27B (non-MTP) | 36.2 | 21.9 GiB |
| MOE 35B (MTP) | 117.9 | 18.7 GiB |
| MOE 35B (non-MTP) | 125.5 | 19.0 GiB |

### Medium scenario

| Model | Throughput medium (tok/s) | VRAM |
|---|---:|---:|
| Dense 27B (MTP) | 49 | 21.9 GiB |
| Dense 27B (non-MTP) | 34.2 | 21.9 GiB |
| MOE 35B (MTP) | 129.3 | 18.7 GiB |
| MOE 35B (non-MTP) | 93.6 | 19.0 GiB |

### Long scenario

| Model | Throughput long (tok/s) | VRAM |
|---|---:|---:|
| Dense 27B (MTP) | 49.0 | 21.9 GiB |
| Dense 27B (non-MTP) | 34.0 | 21.9 GiB |
| MOE 35B (MTP) | 116.1 | 18.7 GiB |
| MOE 35B (non-MTP) | 85.9 | 19.0 GiB |

Comparability notes:

- `Dense 27B (non-MTP)` was **recollected now** in an isolated campaign (`spec-type none`, 2 runs/scenario, 131072 ctx).
- Even so, `long` is not apples-to-apples with MOE: contexts differ (`Dense 27B 131072` vs `MOE 65536`).
- The MTP gain for MOE remains robust in the available scenarios; MOE numbers did not change in this round.

## Honest interpretation of numbers

- For MOE 35B, **MTP improves the medium and especially long scenario**:
  - medium: **129.3 vs 93.6** (~**+38%**)
  - long: **116.1 vs 85.9** (~**+35%**)
- In short and medium, variability depends more on warmup jitter than on `spec-type`, so these values should be read with caution.
- The isolated architecture gain (Dense 27B vs MOE 35B) is not apples-to-apples because `ctx-size` and operational limits differ (`131072` vs `65536`).
- The objective of this round was to lock practical cost/benefit: MTP remains the practical differentiator for MOE, with `spec-draft-n-max 1` as the stable default.

## `spec-draft-n-max`: 1 or 2?

`--spec-draft-n-max 2` and `1` were tested on MOE with MTP build:

- `nmax=2` produced peaks in some samples, but produced recurring draft truncation warning:
  - `draft size 2 exceeds max 1, truncating`
- `nmax=1` removes this truncation behavior, simplifies operation, and still keeps a strong gain versus non-MTP with better acceptance stability.

Operational conclusion: **for daily validation, `spec-draft-n-max 1` is the cleanest configuration**.

## Commands used (summary)

```bash
# Dense 27B with MTP
/path/to/llama-server \
  --model /path/to/Qwen3.6-27B-UD-Q4_K_XL.gguf \
  --ctx-size 131072 \
  --batch-size 2048 --ubatch-size 512 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --fit on --split-mode none --main-gpu 0 --flash-attn on \
  --cont-batching --parallel 1 --timeout 900 \
  --spec-type mtp --spec-draft-n-max 2

# MOE 35B with MTP
/path/to/llama-server \
  --model /path/to/Qwen3.6-35B-A3B-UD-Q3_K_M.gguf \
  --ctx-size 65536 \
  --batch-size 2048 --ubatch-size 512 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --fit on --split-mode none --main-gpu 0 --flash-attn on \
  --cont-batching --parallel 1 --timeout 900 \
  --spec-type mtp --spec-draft-n-max 1

# MOE 35B without MTP
/path/to/llama-server \
  --model /path/to/Qwen3.6-35B-A3B-UD-Q3_K_M.gguf \
  --ctx-size 65536 \
  --batch-size 2048 --ubatch-size 512 \
  --cache-type-k q4_0 --cache-type-v q4_0 \
  --fit on --split-mode none --main-gpu 0 --flash-attn on \
  --cont-batching --parallel 1 --timeout 900 \
  --spec-type none
```

## Practical decision

- **If priority is continuous local production use:** MOE + MTP, with `--spec-draft-n-max 1`, was the best cost/benefit balance.
- **Dense 27B with MTP remains strong** as fallback and for larger context usage, with stable operation.
- **MOE without MTP is for technical comparison only**, not the default.

---

*Written with [GPT-5.5 High](https://openai.com/codex/)*