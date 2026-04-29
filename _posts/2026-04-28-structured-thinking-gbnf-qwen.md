---
title: "Taming Qwen Overthinking with GBNF Grammars"
date: 2026-04-28 19:30:00 -0300
categories: [AI, Tooling]
tags: [qwen, local-llm, gbnf, grammar-constraints, thinking-mode, llama-swap, token-efficiency, structured-reasoning]
description: "Qwen 3.6 overthinks in free-form mode, wasting thousands of tokens. Constraining thinking with a GBNF grammar reduced think-token consumption by 7x without losing code quality."
pin: false
math: false
mermaid: false
---

Qwen 3.6 models support a "thinking" mode, but they tend to overthink excessively — wasting thousands of tokens and producing painfully slow responses. By constraining the thinking process with a GBNF grammar that forces three concise fields (GOAL / APPROACH / EDGE), I reduced think-token consumption by up to **7x** without sacrificing code quality.

## The setup

Anyone who has used the Qwen 3.5/3.6 series in thinking mode knows the problem: ask the model to write a simple function and it produces 800+ tokens of reasoning — rehashing the problem statement, exploring approaches it will not use, discussing edge cases at unnecessary length, and generally meandering before arriving at an answer that could have been reached in three lines of structured thought.

This is not just wasteful — it is slow. At local inference speeds of ~33 tokens/second on consumer hardware, a thousand wasted think tokens means **30 extra seconds** of waiting for every response.

My setup: Qwen 3.6 27B (dense) running through llama-swap v199 on an RTX 3090 with a [power limit of 280W](./2026-04-28-rtx-3090-power-limit-sweet-spot.md). Temperature set to 0.1 for deterministic coding output.

## What worked

The idea is elegant in its simplicity: instead of letting the model think freely (and therefore verbosely), use a **GBNF grammar** to constrain the thinking section to exactly three fields, each on a single line:

```gbnf
root  ::= think code
think ::= "<think>\n" "GOAL: " line "APPROACH: " line "EDGE: " line "</think>\n\n"
line  ::= [^\n]+ "\n"
code  ::= [\x09\x0A\x0D\x20-\x7E]+
```

This grammar forces the model to answer three specific questions through the GOAL / APPROACH / EDGE slots:

- **GOAL:** What do I need to do?
- **APPROACH:** How will I do it?
- **EDGE:** What pitfalls should I watch for?

A proven thinking framework — essentially "understand, plan, anticipate failures" compressed into three lines. The model can no longer meander; it must directly fill in these fields, then produce its code.

The grammar is enforced at the token level via llama.cpp's guided decoding, meaning the model literally cannot output anything outside this structure during the thinking phase.

## Benchmark results

I tested four modes on the same problem: implement a parser and evaluator for arithmetic expressions with operator precedence, parentheses, and negative numbers.

| Mode | Total Tokens | Think Tokens | % in Thinking | Time | Speed |
|------|-------------|-------------|---------------|------|-------|
| **Normal** (no thinking) | 1,621 | 0 | 0% | 49.5s | 32.8 tok/s |
| **Free-form thinking** | 2,788 | ~1,100+ | ~40% | 79.1s | 35.3 tok/s |
| **Structured (GBNF grammar)** | 1,645 | 144 | 9% | 45.9s | 35.8 tok/s |
| **Structured (prompt only)** | 1,655 | 62 | 4% | 44.3s | 37.3 tok/s |

### Key findings

**Free-form thinking is the worst option.** Without grammar constraints, the model produced 2,788 total tokens — **72% more** than the normal mode with no thinking at all. The thinking section alone consumed over a thousand tokens of verbose reasoning that added little value.

**GBNF grammar tames the beast.** With the grammar enforced, the thinking section was compressed to just 144 tokens across three concise lines — a **7.6x reduction** in think-token consumption compared to free-form thinking. Total token count dropped from 2,788 to 1,645, nearly matching the no-thinking baseline.

**Code quality was preserved.** Both the normal mode and the GBNF-structured mode produced correct implementations with proper function signatures, error handling, and test cases. The structured thinking actually helped — the GOAL/APPROACH/EDGE format produced more focused reasoning than the free-form rambling.

Here is what the GBNF-constrained thinking section produced for the parser problem:

```
<think>
GOAL: Implement a function evaluate(expr: str) -> float that parses and evaluates arithmetic expressions with operator precedence (+, -, *, /), parentheses, and negative numbers. Raise ValueError for invalid expressions. Provide complete implementation with tests.
APPROACH: Use the Shunting Yard algorithm to convert infix expression to Reverse Polish Notation (RPN), then evaluate RPN. Or use recursive descent parsing with proper operator precedence handling. Handle negative numbers as unary minus operators.
EDGE: Watch for division by zero, handle consecutive operators correctly, ensure proper parentheses matching, and consider floating-point precision issues.
</think>
```

Three lines. 144 tokens. Covers the same ground that free-form thinking would have spent 800+ tokens on — but in a structured, actionable format.

## Where it almost went sideways

The prompt-only approach (using frequency_penalty of 0.5 and presence_penalty of 0.3 without grammar enforcement) achieved even fewer think tokens at 62, making it the fastest option overall. But this approach depends on the model cooperating — without grammar enforcement, there is no guarantee it will follow the format consistently across different prompts or sessions. The GBNF grammar is stricter but more reliable.

For backends that do not support GBNF grammars natively, the prompt-only approach with penalties is a reasonable fallback — just be aware it is less reliable.

## How to use this

The GBNF grammar can be passed to any llama.cpp-compatible backend via the `grammar` parameter:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8090/v1", api_key="your-key")

grammar = r'''root  ::= think code
think ::= "<think>\n" "GOAL: " line "APPROACH: " line "EDGE: " line "</think>\n\n"
line  ::= [^\n]+ "\n"
code  ::= [\x09\x0A\x0D\x20-\x7E]+'''

response = client.chat.completions.create(
    model="qwen3.6-27b",
    messages=[
        {"role": "system", "content": "Think before answering using <think> tags."},
        {"role": "user", "content": "Your coding problem here..."}
    ],
    max_tokens=4000,
    temperature=0.1,
    extra_body={"grammar": grammar}
)
```

## Original research credit

This structured thinking technique was shared by [@andthatto](https://x.com/andthatto/status/2048103064922447992), who reported even more dramatic results on coding benchmarks:

- **HumanEval+:** 22x fewer think tokens with no accuracy loss
- **LiveCodeBench public slice:** +14% pass@1 improvement with ~5x fewer total tokens

My independent testing confirmed the core finding — structured thinking via GBNF grammars dramatically reduces overthinking while maintaining or even improving output quality. Big thanks to @andthatto for publishing this technique and making it available to the community. Techniques like this are exactly what make local LLM inference practical and efficient on consumer hardware.

## Takeaway

Constrained thinking beats free-form thinking on every metric that matters: fewer tokens, faster responses, better code quality. If you are running Qwen models locally with thinking enabled, a five-line GBNF grammar is the highest-ROI change you can make.

---

*Written with [Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B) (GGUF via [unsloth/Qwen3.6-27B-GGUF](https://huggingface.co/unsloth/Qwen3.6-27B-GGUF)) on RTX 3090 @ 280W through llama-swap v199.*
