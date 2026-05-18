---
title: "When your VLM test flake is actually a VNC capture race"
date: 2026-05-18 14:20:00 -0300
categories: [Engineering, Testing]
tags: [vnc, rfb, vlm, ui-automation, testing, debugging, electron, race-condition]
description: "Spent half a session tuning VLM localize prompts. The real bug was deep in my RFB client: framebuffer captures were 1–N frames behind reality."
pin: false
math: false
mermaid: false
---

A UI test harness I run drives a guest VM over VNC and asks a vision-language model to find and click things on the screen. For a while it had been "mostly works" — a flake budget I had quietly come to accept. Yesterday I tried to fix the flake. The fix was not in any of the places I looked first.

This is the short version of the chase.

## The setup

The runner is [mOSdat](https://github.com/jeanfbrito/mOSdat) — a VLM-driven functional test framework I use to exercise Electron apps inside Proxmox VMs. The loop is straightforward:

1. Take a screenshot of the guest screen over a VNC WebSocket.
2. Ask a vision-language model where the target element is.
3. Send mouse/keyboard events back over the same RFB channel.
4. Re-screenshot, ask a yes/no VLM to verify the post-action state.

The failing scenario opened a sidebar kebab menu, then clicked **Settings** inside the popup that appears. The kebab click would land at the right pixel. Then the next step would localize **Settings**, return a coordinate near the kebab, and click on a no-op spot. Three retries at 10+ seconds each, then the step would fail.

The popup was *visible the whole time* if I watched the same VM through a VNC viewer in another window. The runner just couldn't seem to see it.

## What I tried first (and why it was wrong)

The prompt looked rough. Compare:

```
the 'Settings' or 'Desktop Settings' menu item in the popup menu that
just opened from the sidebar kebab button
```

Three things wrong with that, as a *prompt*:

- **Temporal reference.** "Just opened" — the VLM sees one screenshot, no history.
- **Trigger named in target.** "From the sidebar kebab button" — the most concrete visual anchor in the sentence is the kebab itself, so the model relocates the kebab.
- **No disambiguation.** "Menu item" is generic when the popup also contains Downloads and a header row.

I wrote up the rules: lead with the target, use exact text labels in quotes, anchor by visible spatial relations, disambiguate siblings, never name the trigger element. Saved as a durable lesson for future sessions. Started rewriting the prompt.

Then I opened the actual screenshot the runner had captured at the failing step.

The popup was not in it.

## Where it almost went sideways

A VLM cannot localize an element that isn't in the frame. Every retry was feeding the model the same pre-click frame, so it kept returning the same wrong answer for the same right reason. Prompt quality is downstream of a corrupt input pipeline.

That reframe was the unlock. I stopped re-tuning prompts and went looking at the capture path.

The RFB client (a hand-rolled `VncClient` over `websockets.sync.client`) had a function called `_grab_framebuffer()` whose loop terminated like this:

```python
while painted < target and max_messages > 0:
    ...
```

Where `target = W * H` (total pixels in the framebuffer). The idea: keep reading rectangle updates until the canvas is full.

Two compounding bugs lived in those lines.

**Bug 1: stale buffer leak.** QEMU's VNC server is allowed to emit unsolicited `FramebufferUpdate` messages between requests — cursor moves, dirty regions from animation, anything. Those bytes pile up in the underlying socket and in my own internal read buffer. When `capture()` sends a fresh `FramebufferUpdateRequest` and immediately starts reading, the first bytes it reads are *not* the response to its own request — they're whatever stale update happened to be queued from before. If those bytes satisfy the completion gate, the loop exits with old pixel data and the fresh response sits in the socket waiting for the *next* `capture()` call. The result is captures that are N frames behind reality, where N grows with how often you call `capture()`.

**Bug 2: completion gate counts wrong even within one message.** QEMU often sends overlapping rectangles inside a single update — redrawing the same region twice for legitimate reasons. The loop added `w * h` to `painted` for every rectangle regardless of overlap. So `painted >= target` could trip with substantial portions of the screen never written and late-arriving small rectangles (exactly the shape a popup produces) dropped on the floor.

The fix is two lines of intent, maybe forty of code:

```python
def capture(self):
    self._drain_pending()      # discard everything currently queued
    self._send_fbur()           # then send our request
    return self._read_one_fb_update()  # then read exactly one response
```

`_drain_pending()` zeros the internal buffer and does a 0-timeout `recv()` loop on the WebSocket until it returns nothing. `_read_one_fb_update()` reads message types until it sees a `FramebufferUpdate`, consumes its `n_rects` rectangles, then returns — no pixel-count gate, no "keep reading until full." The completion criterion is "we consumed exactly one response message," not "we accumulated W×H pixels."

After that fix the runner's next captured screenshot showed the popup. The VLM localized Settings at `(284, 671)`. The previous failing run had been localizing it at `(197, 692)` — which is the kebab. Same model, same prompt, real frame this time, correct answer.

## The other half of the cure: stop being instant

With correct frames the runner still raced the UI occasionally. Cursor was moving from one location to another in 150 milliseconds — effectively a teleport. Click events fired the instant the cursor arrived; hover-driven UI state had no time to settle. Post-click captures fired before the rendered DOM had finished landing.

So I bumped the timing defaults:

- **Cursor motion duration: 150 ms → 1000 ms.** The Bezier path now actually plays out at a pace a human eye can follow. Trackable in replay, no longer indistinguishable from "instant" profile.
- **Hover dwell: 0 ms → 250 ms.** Press is no longer the same event as arrival. The widget gets a quarter second to settle hover/focus state before the click registers.
- **Post-action settle: 0 ms → 1000 ms.** After click/key/type, the client sleeps before returning. The next `capture()` reads a screen that has finished re-rendering.

Each click step now costs about 2.25 seconds of wall-clock. For a scenario with twenty clicks, that's 45 extra seconds. Net wall-clock dropped, though, because the prior baseline had a non-trivial chance of burning three 10-second VLM retries on every failed localize. Cheap waits beat expensive retries when the input pipeline is solid.

## Why the path matters, not just the duration

There's a subtler win hiding inside that 1000 ms cursor duration. The motion isn't a linear sweep — it's a quadratic Bezier with an ease-in-out curve and a small Gaussian perpendicular jitter on each sample (roughly 60 frames at the 16 ms emit cap). The path generator looks like this in essence:

```python
def _profile_bezier(start, end, duration_ms, jitter_amplitude, ...):
    ctrl = _control_point(start, end, control_offset_ratio)  # off-axis midpoint
    for t in eased_timesteps(duration_ms):                   # ease-in-out
        x, y = _bezier_sample([start, ctrl, end], t)
        j = rng.gauss(0, jitter_amplitude / 3)               # perpendicular nudge
        yield int(x + jx(j)), int(y + jy(j)), dt_ms
```

The reason this matters for the popup-Settings case is **hover continuity**. Electron's menu popups close on certain mouseleave geometries. If the cursor teleports from the kebab (popup's origin) to the Settings row (somewhere inside the popup), the renderer doesn't see a continuous hover trajectory inside the popup — it sees a pointer event at point A and a pointer event at point B. Depending on how mouse capture is set up and how fast the synthesized events arrive, the popup can interpret the gap as the cursor having left and dismiss itself before the click registers.

A Bezier path with 60 intermediate `pointermove` events sweeping smoothly *through* the popup region keeps hover state continuously asserted on a child of the popup. The popup has no reason to close because, as far as it can tell, the user just slowly moved their mouse from the trigger to the menu item. Which is exactly what a human does.

The jitter is doing related work for the click itself. Pixel-perfect dead-center hits look synthetic; some web widgets gate behavior on pointer-move-before-click heuristics (anti-bot, drag detection). Gaussian wobble of ~2 px on the path keeps the cursor within the target's hitbox while making the trajectory non-deterministic enough to look organic. The total cost is one `random.gauss()` per sample.

I had all of this code in the repo already — the cursor module shipped months ago — but `duration_ms=150` was effectively defeating it. 150 ms over a 600-pixel sweep at the 16 ms emit cap is ~9 samples. Nine sparse points along a Bezier arc isn't a smooth curve; it's an angular zigzag. The hover gaps between those samples were big enough for popups to give up. Stretching to 1000 ms makes the path dense (~60 samples), which is the difference between "human-like motion" and "robot teleport with extra steps."

If you build any kind of UI test runner against real human-facing components, do the boring thing: model your cursor motion on actual humans, give it enough wall-clock to play out, and don't treat it as instrumentation overhead. The path is the test surface.

## Takeaway

Four things I want to carry into the next time something like this happens.

1. **Inspect the actual captured input before debating model behavior.** Vision models cannot localize what isn't in the frame. Prompt tuning is a layer above the question "is my screenshot real?" Verify the layer below first.
2. **"Instant" is a smell in real-time pipelines.** UIs have render cycles. Transports buffer. Compositors batch. Wherever you see `sleep(0)`, immediate-read-after-write, or "no delay needed here" — challenge it. Adding the wait first and measuring it out later is the cheaper experiment.
3. **Two-strike rule on hypotheses.** After two genuine attempts at the same problem from the same angle that don't land, the model of the problem is probably wrong. Stop, escalate, reframe. Don't try a third prompt rewrite. Dispatch an auditor — or in a solo session, write the symptoms down somewhere outside the editor and re-read them.
4. **Cheap waits beat expensive retries.** Two seconds of strategic settle delay saved me from thirty-second VLM retry cycles that ended in failure. The math is brutal in either direction.

The bug had been there for months. I had been treating its symptom — VLM flake — as a model-quality problem. It wasn't. It was a four-decade-old protocol (RFB 3.8 dates back to the late 1990s) being driven by code that assumed cleaner semantics than the spec actually provides. The fix shipped as a sixty-line diff. The lesson is going to outlive the diff.

---

*Written with [Claude Opus 4.7](https://www.anthropic.com/claude/opus) (`claude-opus-4-7`) via Claude Code.*
