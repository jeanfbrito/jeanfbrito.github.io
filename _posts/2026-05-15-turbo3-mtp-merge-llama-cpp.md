---
title: "262K Context + MTP: Merging Two llama.cpp Forks"
date: 2026-05-15 19:30:00 -0300
categories: [AI, Local LLMs]
tags: [llama.cpp, cuda, rtx3090, speculative-decoding, mtp, quantization, ggml, turboQuant]
description: "Merging turbo3 KV cache and MTP speculative decoding into one llama.cpp binary: the build crashes, the CUDA dispatch bug, and 252K context at 85% draft acceptance."
pin: false
math: false
mermaid: false
---

For a while I've been running two separate llama.cpp binaries. One has [MTP speculative decoding]({% post_url 2026-05-08-mtp-qwen3.6-27b-llama-cpp %}): 85–93% draft acceptance, roughly 1.5× throughput on Qwen 3.6 27B. The other has turbo3 KV cache: 3.5 bits per value instead of the usual 8, which should let the 3090's 24 GB stretch to much longer contexts. I wanted both at once.

The reason: at q4_0 KV cache (4 bpv), four parallel slots at 262K context — the model's full training window — costs about 55 GB. That's nowhere near fitting. At turbo3 (3.5 bpv), the math suggested a better trade-off: either full 262K context in a single 3090 slot, or four concurrent slots at useful context lengths across the 3090 + 3060. The measured four-slot run landed at 65K tokens per slot (262K total pool), not 262K per slot — still a practical serving mode, but not the fantasy version the first back-of-envelope math implied. Getting there cost two separate crashes and a few hours of looking at the wrong code.

## What the two pieces do

**MTP** (upstream PR #22673) uses the Multi-Token Prediction head layers already present in models trained for it. At inference time, the MTP head generates draft tokens for the next positions; the main model verifies them in one forward pass. For Qwen 3.6 27B, the acceptance rate runs 85–93% depending on the task, and throughput roughly doubles.

**Turbo3** is a KV cache quantization scheme from a llama.cpp fork. Keys and values go through a Walsh-Hadamard Transform before quantization — the WHT spreads energy across all dimensions, making the resulting distribution more amenable to very low bit codes. The 3-bit variant uses polar quantization with 8 centroids. At inference it needs a specialized flash-attention kernel: a VEC kernel with a shared-memory LUT that precomputes `Q[d] × centroid[c]` per block, then the K·Q loop does a table lookup instead of a float multiply.

Neither piece touches the other in the high-level model logic. The overlap is entirely in `ggml-cuda`: new quantized types, new SET_ROWS kernels for writing to KV cache, new flash-attention VEC kernel instantiations, and changes to the attention graph builder.

## The merge

I kept the MTP branch as the base — it's closer to upstream — and ported the turbo3 ggml-cuda code into it:

- Register `GGML_TYPE_TURBO3_0` (ID 43), `TURBO2_0` (42), `TURBO4_0` (44) in the type registry and `ggml.c`
- Port SET_ROWS kernels in `set-rows.cu` — these handle writing quantized tokens to the KV cache ring buffer
- Port the VEC kernel code and add template instantiations for D=64, D=128, D=256 for all turbo K/V type combinations
- Port the KV cache allocation and auto-asymmetric GQA logic
- Wire `--cache-type-k turbo3` / `--cache-type-v turbo3` through the argument parser

Build succeeded. Then the fun started.

## Crash 1: reshape assertion in build_attn

The first failure was a clean C++ assertion, not a CUDA problem:

```
GGML_ASSERT(ggml_nelements(a) == ne0*ne1*ne2)
```

Stack trace pointed to `build_attn` in `llama-graph.cpp`, inside the V padding removal block. This code trims padding that the turbo3 VEC kernel requires V to have (aligning to block boundaries) before the output flows into the next layer.

The root cause was the auto-asymmetric GQA feature. Qwen 3.6 27B has 24 query heads and 4 KV heads — a 6:1 GQA ratio. Turbo3's auto-asymmetric logic upgrades K from turbo3 to q8_0 when the ratio hits 6:1, on the argument that with many queries sharing one key, the K quantization quality matters more. When K is q8_0, the attention kernel uses the non-transposed (non-FA) path. In that path, `get_v` returns V in a transposed layout where `v->ne[0] = n_kv` (the context length, e.g. 4096), not `n_embd_head_v` (256).

The V padding block read `padded_v_head = v->ne[0]` expecting 256, got 4096, saw that 4096 ≠ 256, fired a reshape — and the reshape assertion failed because the element counts didn't add up.

Fix: guard the V padding block so it only fires when K is also a turbo type (i.e., when the FA path is actually in use and V is genuinely non-transposed with ne[0] = 256):

```cpp
if ((v->type == GGML_TYPE_TURBO3_0 || ...) &&
    (k->type == GGML_TYPE_TURBO3_0 || ...)) {
    // V padding removal — only valid on FA path with both K and V turbo
    const int64_t orig_v_head  = hparams.n_embd_head_v(il);
    const int64_t padded_v_head = v->ne[0];
    if (padded_v_head != orig_v_head) {
        // trim padding from FA output
    }
}
```

When K is q8_0 (auto-asymmetric upgraded), the block is skipped entirely. The server loaded. And then crashed again.

## Crash 2: SIGSEGV with no CUDA error

```
0.05.798.938 I srv    load_model: initializing slots, n_slots = 4
[exit 139]
```

Exit 139 is SIGSEGV. No stack trace. Setting `CUDA_LAUNCH_BLOCKING=1` produced nothing new. The silence that usually means a GPU kernel illegal memory access — so I started reading kernel code.

The turbo3 VEC kernel for D=256 uses a 256×9 half shared-memory LUT. For single-token decode (`cols_per_block = 1`) it fills the LUT once per block and the K·Q loop reads from it. For batch prompts (`cols_per_block = 2`) the LUT fill is compile-time skipped and the loop falls through to a generic quantized dot product. I checked the LUT fill bounds, the V dequantization block index math, the shared memory size against the Ampere limit. None of it had a bug.

The VEC kernel was never executing.

After two failed sessions in the kernel code I dispatched a reasoning-model pass over the dispatch logic. It identified the crash in a single read of `fattn.cu`.

The function `ggml_cuda_get_best_fattn_kernel` decides which flash-attention variant to use. RTX 3090 is Ampere (compute capability 8.6). Ampere satisfies `turing_mma_available()`. The dispatch for quantized K/V on pre-Ada hardware (CC < 890):

```cpp
if (turing_mma_available(cc)) {
    if (can_use_vector_kernel) {
        // ...
        } else {  // pre-Ada Ampere, quantized K/V
            if (Q->ne[1] == 1) {   // single-token decode only
                return BEST_FATTN_KERNEL_VEC;
            }
        }
    }
    return BEST_FATTN_KERNEL_MMA_F16;  // everything else → MMA
}
```

Single-token decode routes to VEC. Anything else — including the short prompt that `common_context_can_seq_rm` sends on every startup — routes to `BEST_FATTN_KERNEL_MMA_F16`.

The MMA kernel calls `ggml_get_to_fp16_cuda(K->type)`. That function is a switch over all registered quantized types. It has cases for Q4_0, Q8_0, Q4_K, Q6_K, IQ1_S, and about twenty others. It has no case for `GGML_TYPE_TURBO3_0`. The default branch returns `nullptr`. The next line calls `nullptr` as a function pointer. On the CPU. SIGSEGV.

`CUDA_LAUNCH_BLOCKING=1` can only surface synchronous CUDA errors from kernel launches. A host-side null pointer dereference happens before any CUDA kernel runs. The flag is useless here.

Fix — three lines in the pre-Ada branch:

```cpp
} else {
    // Turbo types have no fp16 converter registered.
    // MMA would call ggml_get_to_fp16_cuda → nullptr → SIGSEGV.
    const bool kv_is_turbo =
        K->type == GGML_TYPE_TURBO3_0 || K->type == GGML_TYPE_TURBO2_0 || K->type == GGML_TYPE_TURBO4_0 ||
        V->type == GGML_TYPE_TURBO3_0 || V->type == GGML_TYPE_TURBO2_0 || V->type == GGML_TYPE_TURBO4_0;
    if (Q->ne[1] == 1 || kv_is_turbo) {
        return BEST_FATTN_KERNEL_VEC;
    }
}
```

When K or V is a turbo type, always route to VEC regardless of batch size. VEC handles prompt batches with `cols_per_block = 2` and the non-LUT fallback — correct, slightly slower on prefill, doesn't SIGSEGV.

There was one compile error along the way: the `k_is_turbo` variable I tried to reference was defined inside a `#ifndef GGML_CUDA_FA_ALL_QUANTS { }` block with its own scope, so it went out of scope before the dispatch site. Inlined the check directly.

## Caveats worth knowing

**Auto-asymmetric and `TURBO_AUTO_ASYMMETRIC=0`.** With auto-asymmetric enabled (the default), K is silently upgraded from turbo3 to q8_0 when the GQA ratio hits 6:1. This model is exactly 6:1. That upgrade avoids the SIGSEGV on the original dispatch (q8_0 has a registered fp16 converter) but means K is 8 bpv, not 3.5 — losing most of the compression. To get full turbo3 on both K and V, run with `TURBO_AUTO_ASYMMETRIC=0`. After the dispatch fix, this works.

**The fit algorithm expands context aggressively.** The `-fit` flag estimates how much context fits in available VRAM and sets `n_ctx` accordingly. With one parallel slot on the 3090, all tested KV types fit the full 262,144-token training window. With four parallel slots across the 3090 + 3060, `-fit` produced a 262K total context pool divided into 65,536 tokens per slot. Don't compare raw VRAM numbers between KV types without accounting for the context size and slot count.

**MTP draft context inherits KV types.** The MTP draft context is initialized with the same parameters as the main context. It also uses turbo3 K/V. This is fine — the fix applies to both — but worth knowing if you're checking why the MTP context is also taking turbo-sized allocations.

## Numbers

All four configurations benchmarked on RTX 3090 only (`CUDA_VISIBLE_DEVICES=0`, 24 GB — no spill to the 3060), same model (Qwen 3.6 27B, Q4_K_M), one parallel slot, `-fit` maximizing context within the 3090's budget.

| Configuration | ctx / slot | VRAM | gen tok/s | prefill tok/s | MTP accept |
|---|---|---|---|---|---|
| q4_0, no MTP | 262,144 | 20.8 GB | 36.5 | 187.8 | — |
| turbo3, no MTP | 262,144 | 19.6 GB | 35.8 | 178.2 | — |
| q4_0 + MTP n-max 2 | 262,144 | 22.2 GB | 53.9 | 149.4 | 91% |
| turbo3 + MTP n-max 1 | 262,144 | 20.9 GB | 48.2 | 162.9 | 95% |
| **q4_0 + ngram-mod + MTP** | **262,144** | **21.9 GB** | **66.9** | **158.3** | **86%** |

A few things stand out:

**Turbo3 does not hurt generation speed.** 35.8 vs 36.5 tok/s without MTP — a 2% difference inside measurement noise. The LUT-based attention kernel does not add latency per token.

**Turbo3 saves about 1.2 GB VRAM at full 262K context.** At one slot it is modest; across multiple slots it compounds into extra headroom for concurrency. In the measured four-slot run, that meant loading cleanly at 65K tokens per slot across the 3090 + 3060, not 262K per slot.

**Speculation changes the winner.** Plain MTP adds 48% throughput on q4_0 (36.5 → 53.9 tok/s). On turbo3, the best stable setting is n-max 1: 35.8 → 48.2 tok/s, with 95% single-token draft acceptance. But the fastest single-GPU config is `ngram-mod,draft-mtp` on q4_0: 66.9 tok/s, 86% acceptance, same VRAM class as plain MTP.

**Both fit the full 262K training window within 24 GB.** q4_0 + MTP needs 22.2 GB; turbo3 + MTP needs 20.9 GB. Both land well under the 3090's ceiling. The earlier (flawed) benchmark showed 27.5 GB and 26.7 GB respectively — that was because `-fit` was computing context against the combined 36 GB of both GPUs, then silently spilling the overflow to the slower 3060. Constraining to a single GPU gives cleaner numbers and removes the cross-bus penalty.

**The multi-slot argument.** At four parallel slots, turbo3 loaded cleanly on the RTX 3090 + RTX 3060 setup at 65K tokens per slot (262K total context pool), 37.7 tok/s per active request, and 95% draft acceptance. That is not a single-request speed play — PCIe traffic costs ~22% — but it is useful for concurrent serving: four slots can run simultaneously instead of one long-context slot monopolizing the server.

## The trade-off

The numbers above are all single-slot. That is where turbo3 looks weakest. The full picture requires thinking about how many parallel slots you need.

**Single slot: q4_0 wins on speed.** q4_0 + `ngram-mod,draft-mtp` reaches 66.9 tok/s. turbo3 + MTP n-max 1 reaches 48.2 tok/s. Turbo3 is not the max-speed choice; it is the lower-VRAM, more-concurrent choice.

**Multi-slot: turbo3 compounds in concurrency, not per-request speed.** For total system throughput, four turbo3 slots at 37.7 tok/s each can deliver ~151 tok/s aggregate if several clients are active. That beats any single-slot config, but one request still runs slower than q4_0 + ngram + MTP. The win is utilization: more slots alive at useful context length.

The measured multi-GPU run (RTX 3090 + RTX 3060, `--parallel 4`, `-fit`, `TURBO_AUTO_ASYMMETRIC=0`) loaded without OOM at 65,536 tokens per slot. VRAM landed at 13.8 GB on the 3090 and 8.9 GB on the 3060. The earlier estimate that turbo3 would hold 250K+ per slot at four slots was wrong: `-fit` produced a 262K total context pool and divided it across four slots.

**The q8_0/turbo3 middle ground failed.** Running `--cache-type-k q8_0 --cache-type-v turbo3` was supposed to keep high-quality K while compressing V. In practice it cost more VRAM than q4_0 (23.4 GB), dropped acceptance to 79.6% at n-max 2, and was slower than q4_0+MTP. Full turbo3 at n-max 1 is both smaller and cleaner.

## How many draft tokens?

The Unsloth release notes for these MTP GGUFs recommend bumping `--spec-draft-n-max` from 2 to 6, claiming 1.8× throughput. That number does not hold here. Running a full sweep across n-max 1, 2, and 6 on both KV types:

| Config | n-max 1 | n-max 2 | n-max 6 |
|---|---|---|---|
| q4_0 gen tok/s | 49.9 | **53.9** | 55.7 |
| q4_0 accept % | 94.8% | 91% | 77% |
| turbo3 gen tok/s | **48.2** | 47.4 | 37.8 |
| turbo3 accept % | 95.4% | 78% | 48% |

**q4_0**: n-max 2 is the peak. n-max 6 adds 3% speed on this prompt but accept rate drops to 77% — on harder prompts (coding, structured output) that rate tends to fall further, making n-max 6 fragile. n-max 2 at 91% is the robust choice.

**turbo3**: n-max 1 and n-max 2 are statistically identical (48.2 vs 47.4 tok/s). At n-max 2, turbo3's 78% acceptance means the expected accepted tokens per verify pass is ≈1.39 — better than n-max 1's ≈0.95 on paper. But the overhead of generating the second draft token eats the difference. n-max 6 is actively harmful: acceptance collapses to 48%, and verifying long rejected draft chains costs more than the occasional fully-accepted run gains. Use n-max 1 for turbo3 — same throughput as n-max 2, less wasted compute.

The 1.8× claim from Unsloth targets their stock GGUFs at high acceptance rates. This fine-tuned model on turbo3 K/V doesn't have the acceptance headroom to amortize long draft sequences.

After running all three, one more result came in that changes the single-user recommendation.

**`--spec-type ngram-mod,draft-mtp` hits 66.9 tok/s — 24% faster than MTP alone.** The combined speculator uses the n-gram cache for repetitive token sequences and the MTP head for everything else. More draft tokens per verify pass (259 vs 230), 86% acceptance, same VRAM as q4_0+MTP. This is now the fastest single-GPU config tested.

**`--cache-type-k q8_0 --cache-type-v turbo3` is not worth it.** The expectation was that high-quality K would recover acceptance toward 91%. It doesn't: at n-max 2, acceptance is 79.6% — barely above turbo3+turbo3 — and it costs +3 GB VRAM vs full turbo3. K quality doesn't compensate for the V compression noise at n-max 2; at n-max 1 it reaches 86.3% but again costs +2.5 GB vs full turbo3 with no speed gain. Full turbo3 with n-max 1 at 95.4% acceptance is strictly better.

**Multi-GPU turbo3, 4 slots: works, no OOM, 95% acceptance.** The 22% speed penalty from PCIe inter-GPU traffic is real, but for concurrent serving: 4 × 37.7 tok/s = ~151 tok/s system-wide throughput. Each slot gets 65K context (the pool is divided by slot count, not per-slot).

Updated summary across all tested configs (RTX 3090, single slot unless noted):

| Configuration | VRAM | gen tok/s | accept % |
|---|---|---|---|
| q4_0, no MTP | 20.8 GB | 36.5 | — |
| turbo3, no MTP | 19.6 GB | 35.8 | — |
| q4_0 + MTP n-max 2 | 22.2 GB | 53.9 | 91% |
| turbo3 + MTP n-max 1 | 20.9 GB | 48.2 | 95% |
| k=q8\_0, v=turbo3 + MTP n-max 1 | 23.4 GB | 47.0 | 86% |
| **q4\_0 + ngram-mod + MTP** | **21.9 GB** | **66.9** | **86%** |
| turbo3 + MTP n-max 1, 4 slots (2 GPUs) | 22.7 GB total | 37.7/slot | 95% |

**Optimal launch flags:**

```bash
# Single user, absolute max speed
--cache-type-k q4_0 --cache-type-v q4_0 \
--spec-type ngram-mod,draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.75

# Multi-user, long context (4 slots, 2 GPUs)
TURBO_AUTO_ASYMMETRIC=0 \
--cache-type-k turbo3 --cache-type-v turbo3 \
--spec-type draft-mtp --spec-draft-n-max 1 --spec-draft-p-min 0.75 \
--parallel 4 -fit
```

| Goal | Best config |
|---|---|
| Single user, max tok/s | q4\_0 + ngram-mod + MTP |
| 4 users, long context | turbo3 + MTP n-max 1, 2 GPUs |
| K=q8\_0 / V=turbo3 middle ground | Not worth it — worse than both alternatives |

## What I'd do differently

Check the dispatch routing table before the kernel internals. Any new quantized type that reaches `launch_fattn` needs either a registered `ggml_get_to_fp16_cuda` entry or an explicit escape to VEC. One missing `case` in a switch returns null silently. The null lands in a function call. SIGSEGV.

More generally: when a llama.cpp fork adds a new quantized type, the blast radius is wider than just the kernel files. The type registration, the flash-attention dispatch, the type converters, the SET_ROWS writer, and the graph builder's conditional paths all need updating. A complete checklist would have saved the sessions I spent inside the wrong kernel.

---

*Written with [Claude Sonnet 4.6](https://www.anthropic.com/claude) (`claude-sonnet-4-6`) via Claude Code.*
