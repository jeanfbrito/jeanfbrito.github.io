---
title: "Club 3090 vs My Llama Setup"
date: 2026-05-04 07:49:00 -0300
categories: [AI, Local LLMs]
tags: [rtx3090, vllm, llama-cpp, qwen, local-llm, benchmarking]
description: A direct RTX 3090 benchmark comparing my llama.cpp plus llama-swap Qwen3.6-27B setup against the club-3090 vLLM tools-text solution.
pin: false
math: false
mermaid: false
---

I had a working local Qwen3.6-27B setup through `llama.cpp`, `llama-swap`, and OneGPU4All. It was stable, easy to route, and already useful for coding prompts. The question was whether the [club-3090](https://github.com/noonghunna/club-3090) solution was actually better on the same RTX 3090, or whether it was just another pile of setup complexity.

So I tested it against the route I was already using.

Short version: club-3090 won clearly. On the same coding prompt, my dense llama-swap setup measured `37.4 tok/s` at `276.8W` average. The club-3090 `tools-text` vLLM stack measured about `64.6-66.1 tok/s`, with a power sample of `63.0 tok/s` at `219.4W` average.

That is about `+72%` throughput and roughly `2.1x` perf-per-watt.

## The Baseline

My existing path was:

```text
client -> OneGPU4All -> llama-swap -> llama-server
```

The model route was dense `qwen3.6-27b-coding`, served through llama.cpp. I had already tried the obvious local llama-side tuning before this comparison:

- reducing the coding context from 262K to 65K
- trying DFlash locally
- raising the RTX 3090 power limit
- testing a two-GPU row split with the smaller second GPU
- trying KV variants such as `q8_0`, F16, and `q4_0`
- testing llama.cpp speculative decoding with a local Qwen draft model
- testing ngram speculative decoding

None of those produced a real 30% improvement on the same dense 27B route. The best stable llama.cpp result was around `40-41 tok/s`. The restored baseline for the final comparison was:

```text
llama-swap dense qwen3.6-27b-coding
37.4 tok/s
276.8W average
0.135 tok/s/W
```

That was the number club-3090 had to beat.

## The Club 3090 Setup

The tested club-3090 path was the Qwen3.6-27B vLLM `tools-text` solution, not my llama-swap stack.

Setup was:

```bash
git clone https://github.com/noonghunna/club-3090.git
cd club-3090
bash scripts/setup.sh qwen3.6-27b
```

The setup downloaded the model and SHA-verified the shards. Then I started the single-card vLLM compose on port `8020`:

```bash
cd models/qwen3.6-27b/vllm/compose
PORT=8020 docker compose -f docker-compose.tools-text.yml up -d
```

This stack is materially different from my llama setup. It uses vLLM, AutoRound INT4 safetensors, fp8 KV, Genesis patches, and MTP. That distinction matters: this was not "make llama.cpp faster." It was "run the club-3090 solution and compare it to the llama.cpp route."

## The Benchmark

I used the same LRU coding prompt against both stacks:

```text
Write a JavaScript LRU cache implementation with get, set, delete, clear,
capacity eviction, and a short usage example. Return code only.
```

The first club-3090 benchmark attempt exposed an important usability issue. vLLM was generating tokens, and server logs showed roughly `52-53 tok/s` after warmup, but the client response content came back empty. The output was likely landing in `reasoning_content` instead of normal `content`.

The fix was to disable thinking in the chat template kwargs:

```json
{
  "chat_template_kwargs": {
    "enable_thinking": false,
    "preserve_thinking": true
  }
}
```

After that, the endpoint became usable for the coding prompt and matched the club-3090 docs much more closely:

```text
club-3090 vLLM tools-text
64.6-66.1 tok/s
power sample: 63.0 tok/s
219.4W average
0.287 tok/s/W
```

Compared to my restored llama-swap dense route:

```text
llama-swap dense qwen3.6-27b-coding
37.4 tok/s
276.8W average
0.135 tok/s/W
```

## The Result

The club-3090 solution was not just faster. It was faster while drawing less power in the measured sample.

```text
throughput:     37.4 -> ~64.6-66.1 tok/s
gain:           about +72%
perf-per-watt:  0.135 -> 0.287 tok/s/W
efficiency:     about 2.1x
```

That changes the decision. Before testing the actual club-3090 stack, the local llama.cpp path looked like the pragmatic option: simple routing, stable process control, and acceptable speed. After testing, the vLLM tools-text path was clearly the better coding-throughput setup for this specific Qwen3.6-27B workload on the RTX 3090.

The llama setup still has a place. It is simpler to integrate with llama-swap, easier to route alongside other local GGUF models, and useful when operational predictability matters more than throughput. But for this coding prompt, club-3090 delivered the real win.

## Takeaway

The useful lesson was not "tune harder." I already tried that on the llama.cpp route and hit small gains. The useful lesson was to test the right stack.

For dense Qwen3.6-27B on a single RTX 3090, my llama-swap setup was stable but slower. The club-3090 `tools-text` vLLM/MTP solution was a different serving architecture, and it produced the improvement I was trying to squeeze out of llama.cpp: around `+72%` throughput and about `2.1x` perf-per-watt on the same coding prompt.

---

*Written with [GPT-5.5](https://openai.com/codex/) (`gpt-5.5`) via Codex.*
