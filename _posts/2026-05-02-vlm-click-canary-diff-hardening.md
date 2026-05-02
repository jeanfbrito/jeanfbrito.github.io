---
title: "Stopping a VLM-Driven Test From Leaking My Password"
date: 2026-05-02 18:30:00 -0300
categories: [AI, Tooling]
tags: [vlm, ui-testing, automation, vision-models, debugging, electron, vnc]
description: "A vision-language-model-driven UI test typed my password into the username field. Fixing it took eye-icon prompts, before/after-click diffs, canary-byte typing, and uncovering two latent bugs."
pin: false
math: false
mermaid: false
---

I was watching a smoke test run on a Linux VM when the screen showed `User not found`. The username field on the Rocket.Chat login page contained the string `Pa55word.jean` — my password concatenated with my username. The vision-language model driving the test had clicked the wrong row and typed the password into the email field. If the page had been less strict about validation, that string would have hit the server in plaintext.

This post is about how I made the test self-check enough to never do that again, and the two latent bugs I tripped over on the way.

## The setup

The harness is [mOSdat](https://github.com/jeanfbrito/mOSdat), a small VLM-driven UI test runner for desktop Electron apps. It boots a Proxmox VM, attaches a GPU for hardware-accelerated rendering, talks to the VM over VNC for screenshots and input injection, and uses a local vision-language model (qwen3.6-35b via llama-swap) to localize widgets from natural-language descriptions:

```yaml
- localize: "the upper input field labeled 'Email or username'"
  then_type: "{test_user}"
- localize: "the Password input field — the masked field below Email"
  then_type: "{test_password}"
  then_key: "enter"
```

The model returns `(x, y)` pixel coordinates. The runner clicks there. Then types. Done.

This works most of the time. But "most of the time" is not "always", and the failure mode for a credential-typing step is *type the secret into the wrong widget*. That is a credential leak, not a flaky test.

## The first wrong turn: better prompts

The Email and Password fields look identical: same width, same grey border, same height, ~100px apart vertically. When the VLM mis-targets, it goes Email→Email or Password→Email. Asking the model to be more careful via better prompts (`"BETWEEN the Email field above and the Login button below"`) reduced the rate but did not eliminate it.

The breakthrough was anchoring on a **unique visible feature** — Password fields have an eye icon on the right edge for toggling visibility, Email fields don't:

```yaml
- localize: "the Password input row — find the small eye icon
    (an open/closed eye glyph) on the right edge of an input row,
    and click the empty space INSIDE that input row to its LEFT.
    The Email/username field above has NO eye icon —
    never click there."
```

The eye icon is a salient discriminator the encoder can keep through downscale. Click accuracy on Password jumped to first-attempt-pass on most runs.

But "most runs" is still not enough.

## Self-checking: verify_click

Step one of hardening: after the click, before any keystrokes, ask the VLM "did the click land on the right field?". I added a `verify_click` field to the scenario:

```yaml
- localize: "the Password input row …"
  verify_click: "the Password row is focused — a text cursor or
    focus ring is visible inside that specific row, NOT inside
    the Email/username row above"
  then_type: "{test_password}"
```

The runner takes a screenshot 400ms after the click and asks the VLM yes/no on that prompt. If the answer is no, it retries the localize+click. Pre-type, pre-leak.

This caught most failures. Then I noticed false positives.

## Where it almost went sideways: false-positive verify

Step 6 (username) ran. Click landed at Y=378, just above the email field. `verify_click` said *yes, focused*. Type fired. The screenshot a moment later showed: cursor in the form, no `jean` anywhere on screen.

The placeholder `example@example.com` was still visible. The click had hit empty whitespace above the field, the model had said the field was focused anyway, the type had gone into a void.

The reason the model lied: focus rings are 2px wide, the caret is 1px wide and blinks at 530ms. After the model's image encoder downscales 640×400 to ~384×... whatever, those features are gone. The model answered the question by hallucinating a confident yes for an attribute it literally cannot see.

Asking VLMs to detect subpixel features is the wrong question. The right question is one they *can* answer.

## The right question: comparison, not absolute state

VLMs are reliable on **comparison**. "Did the right crop change vs the left?" is a question with a concrete pixel-level answer. "Is the field focused?" is a question about an attribute the model cannot perceive.

So the second iteration: capture the screenshot **before** the click, capture again **after**, crop both ±80px around the click point, stitch them side-by-side with a black divider, and ask:

```
"comparing the LEFT crop (before click) to the RIGHT crop
 (after click): the RIGHT crop now shows a visible change
 indicating an input field has gained focus — a text cursor,
 a coloured/thicker border, or a placeholder that disappeared.
 If the two crops look essentially identical, answer no."
```

The 160-pixel-wide composite is small, fast (single VLM call ~400ms), and the model is asking *did this thing change* — which it can answer.

Diff verify caught the whitespace-click immediately. The before-crop showed unfocused field, the after-crop showed nothing different (because the click had missed) — `no`, retry.

## The strongest gate: canary-byte typing

But even diff verify can false-yes if *something* on screen changed near the click — a button hover state, an animation, a tooltip. The strictest possible check is to **prove the typing is going where you think it is going** by typing a harmless probe character first:

```python
# 1. type a single distinctive char
self.injector.type_text("q")
time.sleep(0.3)
# 2. ask the VLM where it landed
landed = self.vlm.verify(screenshot,
    "the character 'q' is visible inside the target field, "
    "NOT inside any other field")
# 3. if yes, backspace it and type the real text
if landed:
    self.injector.key("backspace")
    self.injector.type_text(real_text)
else:
    retry()
```

This is bulletproof: if the click misfired, the canary `q` lands in the wrong place, the model sees it there, and the runner retries *without ever typing the real credential*. If the click was correct, one keypress and one backspace is the only cost — about 400ms.

## Two latent bugs the canary uncovered

Implementation went smoothly. Tests passed (49/49). I ran the live smoke. Step 5 failed with `canary verify never passed` three times. Screenshot showed the field focused, cursor in place, and the placeholder *still visible*. The canary character was not on screen.

### Bug 1: VNC keysym-only path drops shift-required ASCII on Wayland

I had defaulted the canary to `§` (U+00A7), which felt distinctive and unlikely to collide with placeholder text. After it failed, I tried `~`. Same failure. Single-char unmodified ASCII like `q` worked. Multi-char shifted strings (the test was already typing things like `rocketchat.jeanbrito.com` — all unmodified ASCII) worked.

The Proxmox→QEMU→Wayland-mutter VNC chain accepts X11 keysyms but the shift-modifier wrap that `vnc.type_text` applies for `~` (Shift+grave) and `§` (Latin-1) gets dropped silently somewhere in the stack. No error, no warning — the keypress just disappears. The unmodified-ASCII path is the only reliable one for single-char probes.

The fix was to default the canary char to `q` — lowercase, no shift, not present in any RC placeholder text. Distinctive enough for the model to spot and harmless if the field already has content.

Lesson now lives in `docs/KNOWN_ISSUES.md`: VNC `type_text` cannot be trusted for single shifted keystrokes on this stack.

### Bug 2: Defaults defined in two places drift

I changed the dataclass default in two files (`scenario.py` and `functional.py`) from `§` to `q`. Tests passed. Live smoke logs still showed `canary verify (char='§')`. The character had not propagated.

The cause: `_parse_step` in `functional.py` reconstructs `FunctionalStep` from raw YAML using `raw.get("canary_char", "§")`. The literal `"§"` fallback in the parser overrode the dataclass default any time the YAML didn't specify the field — which was every step.

A default defined in two places is a default defined zero times. The fix was a one-line change to the parser. The lesson is the rule: either factor defaults into a module-level constant imported by both sites, or have the parser pass `None` and let the dataclass apply the real default.

## The result

With the eye-icon prompt, diff-based verify_click, and canary-byte typing all live — and both latent bugs fixed — the smoke test ran end-to-end green:

```
step 5 server URL:  OK 26.6s   diff=yes  canary='q'=yes
step 6 username:    OK 10.9s   diff=yes  canary='q'=yes
step 7 password:    OK 13.4s   diff=yes  (canary off — masked field)
step 8 channel:     OK 14.5s
step 9 message:     OK  9.0s
```

Each gate is independently toggleable via CLI flag (`--click-verify={off,yesno,diff,diff+yesno}`, `--canary={auto,off,on}`) so I can A/B test which layer is doing the work.

Cost is about 4 seconds per typed step in the worst case (one diff call + one canary call + a backspace). I'll take 4 seconds over a leaked password every time.

## Takeaway

Three things I want to remember the next time I'm writing a test against a vision model:

1. **Comparison beats absolute state.** Ask the model "did this change vs that?", not "is this thing in this state?". The first is a question about pixels, which the model can answer. The second is a question about attributes the model often cannot perceive after image-encoder downscale.

2. **Layer cheap and strict gates.** A fast, noisy gate (diff verify) followed by a slower, stricter gate (canary-byte) catches more than either alone. Each gate is allowed to fail-open if the next one will catch it.

3. **Never type a real secret without proving where it's going first.** A one-character probe + verify + backspace is so cheap that there's no excuse not to do it for credential-bearing steps.

The harness is [open source](https://github.com/jeanfbrito/mOSdat) if anyone wants to poke at the verify_click + canary implementation directly. The runner code is in `automation/runners/functional.py`, the diff helper is `_check_click`, and the canary helper is `_check_canary`.

---

*Written with [Claude Opus 4.7 (1M context)](https://www.anthropic.com/claude) (`claude-opus-4-7[1m]`) via Claude Code.*
