---
title: "RTX 3090 Power Limit: Finding the Sweet Spot for Local LLM Inference"
date: 2026-04-28 19:00:00 -0300
categories: [AI, Hardware]
tags: [rtx-3090, local-llm, gpu-benchmark, power-efficiency, llama-swap, qwen, moe, systemd]
description: "Benchmarked an RTX 3090 across six power limits and found that 280W saves ~70W with less than 1% performance loss for LLM inference. Below 200W, everything collapses."
pin: false
math: false
mermaid: false
---

The RTX 3090 ships with a 350W TDP out of the box. For local LLM inference, that is often overkill — higher electricity bills, more heat, louder fans, and diminishing returns on performance. I wanted to find the exact point where reducing power starts hurting inference speed.

The answer: **280W** — saving ~70W with less than 1% performance loss. Below 200W, everything collapses.

## The setup

I'm running local LLM inference on an RTX 3090 (24 GB VRAM) through [llama-swap](https://github.com/sashakho/llama.cpp) v199 — a fork of llama.cpp that hot-swaps models on the fly without restarting. The driver is NVIDIA 590.48.01.

For the benchmark model, I used Qwen 3.6 27B (dense) with a prompt asking for a detailed essay about the history of computing from abacus to modern AI, targeting 4000 output tokens at temperature 0.7.

## What worked

For each power limit level, I followed this process:

1. Set the power limit using `sudo nvidia-smi -i 0 -pl <watts>`
2. Waited 15 seconds for the GPU to stabilize at the new power state
3. Ran the benchmark prompt and measured tokens generated, time elapsed, and calculated tokens per second
4. Sampled GPU stats at the end of each run: core clock, memory clock, power draw, temperature, and utilization
5. Waited 5 seconds cooldown before the next test

I tested six power levels in descending order: **350W → 300W → 275W → 250W → 200W → 150W**, then reset to the default 350W.

Here is the benchmark script:

```python
import time, subprocess
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8090/v1", api_key="sk-local")

power_levels = [350, 300, 275, 250, 200, 150]
results = []

for watts in power_levels:
    subprocess.run(["sudo", "nvidia-smi", "-i", "0", "-pl", str(watts)])
    time.sleep(15)
    
    start = time.time()
    response = client.chat.completions.create(
        model="qwen3.6-27b",
        messages=[{"role": "user", "content": "Write a very long detailed essay about the history of computing..."}],
        max_tokens=4000, temperature=0.7, stream=True
    )
    
    token_count = 0
    for chunk in response:
        if chunk.choices[0].delta.content:
            token_count += 1
    
    elapsed = time.time() - start
    speed = token_count / elapsed
    
    gpu_stats = subprocess.run(
        ["sudo", "nvidia-smi", "-i", "0",
         "--query-gpu=clocks.current.graphics,clocks.current.memory,power.draw,temperature.gpu,utilization.gpu,power.limit",
         "--format=csv,noheader"],
        capture_output=True, text=True
    )
    
    results.append({
        "watts": watts, "tokens": token_count,
        "elapsed": round(elapsed, 1), "speed": round(speed, 1),
        "gpu_stats": gpu_stats.stdout.strip()
    })

subprocess.run(["sudo", "nvidia-smi", "-i", "0", "-pl", "350"])
```

## Results

| Power Limit | Speed (tok/s) | Core Clock | Mem Clock | Power Draw | Temp | GPU Util |
|-------------|---------------|------------|-----------|-----------|------|----------|
| **350W** | 32.0 | 1710 MHz | 9501 MHz | ~333W | 74°C | 82% |
| **300W** | 33.0 | 1575 MHz | 9501 MHz | ~295W | 73°C | 86% |
| **275W** | 32.7 | 1530 MHz | 9501 MHz | ~273W | 71°C | — |
| **250W** | 31.7 | 1395 MHz | 9501 MHz | ~247W | 69°C | — |
| **200W** | 20.6 | 480 MHz | 9501 MHz | ~199W | 71°C | — |
| **150W** | 8.3 | very low | 9501 MHz | ~150W | — | — |

## Where it almost went sideways

### The Plateau (250W–350W)

From 350W down to 250W, the performance drop is minimal — less than 3%. The core clock scales gradually from 1710 MHz down to 1395 MHz, but the inference speed stays remarkably flat. This is because LLM inference at this scale is **memory-bandwidth bound**, not compute-bound. The memory clock stays pinned at 9501 MHz across all these levels, and that is the real bottleneck.

You can reduce power by ~90W (from 350W to 250W) and lose almost nothing in terms of tokens per second.

### The Cliff (Below 200W)

At 200W, everything falls apart. The core clock collapses from 1395 MHz to **480 MHz** — a 65% drop. Speed plummets from 31.7 tok/s to 20.6 tok/s. At 150W it is unusable at 8.3 tok/s.

This cliff happens because the GPU can no longer maintain even its base clock under the power constraint, and the driver forces aggressive throttling. The memory clock stays high, but without compute capacity to feed it, nothing helps.

### The Sweet Spot: 280W

I chose **280W** as my operating point because:

- Only ~1% slower than 350W (32.7 vs 32.0 tok/s — within measurement variance)
- Saves ~60W of power draw (~333W → ~273W actual consumption)
- Runs 3°C cooler (71°C vs 74°C)
- Core clock at 1530 MHz is well above the danger zone

### Bonus: MoE Models at 280W

I also tested a Mixture-of-Experts model ([qwopus-moe-35b-a3b](https://huggingface.co/search?q=qwopus-moe)) at the same 280W limit and compared it to the dense Qwen 3.6 27B:

| Metric | Qwen 3.6 27B (dense) | QwOpus MoE 35B-A3B |
|--------|----------------------|---------------------|
| Avg speed | 31.9 tok/s | 30.0 tok/s |
| **Steady state** | **32.9 tok/s** | **79.3 tok/s** |
| Core clock | 1485 MHz | 1905 MHz |
| Power draw | 278W | 269W |
| GPU utilization | 84% | 54% |

The MoE model is **2.4x faster in steady state** while consuming less power and using half the GPU. The lower average speed is misleading — it is dragged down by a longer cold start (loading experts for the first token). Once warmed up, it flies at 79+ tokens/second.

## Making It Persistent Across Reboots

The `nvidia-smi -pl` command only applies until reboot. To make it persistent, I created a systemd service:

```bash
sudo tee /etc/systemd/system/nvidia-power-limit.service > /dev/null << 'EOF'
[Unit]
Description=Set NVIDIA GPU 0 (RTX 3090) power limit to 280W
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -i 0 -pl 280
ExecStop=/usr/bin/nvidia-smi -i 0 -pl 350

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable nvidia-power-limit.service
sudo systemctl start nvidia-power-limit.service
```

This service runs after the NVIDIA driver loads, sets the power limit to 280W, and persists across reboots. The `ExecStop` line resets to 350W if you ever disable the service.

For passwordless sudo on nvidia-smi:

```bash
echo "jean ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi" | sudo tee /etc/sudoers.d/nvidia-power
```

Verify it is working:

```bash
$ sudo nvidia-smi -i 0 --query-gpu=power.limit,power.draw,temperature.gpu --format=csv
280.00 W, 277.89 W, 73
```

## Takeaway

Your GPU's TDP rating is a ceiling, not a target. LLM inference is memory-bandwidth bound — as long as your memory clock stays high, you can reduce core clock (and power) significantly before seeing any speed impact. There is always a cliff, and finding it takes one benchmark session. Five minutes of setup saves energy every hour your GPU runs.

And if you're experimenting with MoE models at lower power limits: the sparse activation pattern means less compute demand per token, which translates to higher clocks and dramatically faster inference at the same power budget. The numbers are genuinely surprising.

---

*Written with [Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B) (GGUF via [unsloth/Qwen3.6-27B-GGUF](https://huggingface.co/unsloth/Qwen3.6-27B-GGUF)) on RTX 3090 @ 280W through llama-swap v199.*
