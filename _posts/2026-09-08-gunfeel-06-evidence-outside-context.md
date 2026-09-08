---
title: "Building Gunfeel 6: Small Results, Honest Evidence"
date: 2026-09-08 13:05:00 -0300
categories: [AI, Tooling]
tags: [ai, tooling, testing, godot, reproducibility, context-management]
description: "Video analysis was filling the conversation with bookkeeping. A local tool now keeps the raw artifacts on disk and returns compact, inspectable findings."
pin: false
math: false
mermaid: false
series: Building Gunfeel
series_order: 6
---

After enough recordings, measurements, and reviews of **Shoot to Thrill**, I asked whether the evidence itself was taking over the conversation. We were trying to improve gunplay, but the agent was spending a lot of its attention coordinating clips, reading logs, selecting frames, and reconciling results. I wanted tools to do that repetitive work and let the agent see the useful conclusions.

This post follows [the testing workflow]({% post_url 2026-09-08-gunfeel-05-testing-without-interruption %}) into the evidence tools we built around it. It is also the current stopping point of the series. The tools have made concrete progress; the walking candidate still has known failures, and the larger realism goal remains unfinished.

## Files on disk are not the context window

The first distinction was simple but useful. Saving a video locally does not automatically place that video into the model's conversation. Returning logs, displaying images, reading large source sections, and accumulating explanations are what bring material into context.

That meant the answer was not to delete the evidence. We needed to change the interface to it. The raw artifacts should remain available for inspection and reanalysis, while routine tool responses should contain only what the next engineering decision needs.

Filtering tools already helped reduce large outputs. The remaining cost was the manual coordination around them: remembering which profile a take used, checking whether a process really finished, distinguishing a stale image from a valid frame, and deciding which part of a log explained the failure.

A reusable tool could own those repeated steps. The agent would still decide what experiment to run and how to interpret the result, but it would not have to reconstruct the experiment's bookkeeping from conversation history every time.

## Begin with a failure we already understood

I did not want the first milestone to be an elaborate analysis platform with no demonstrated connection to the actual problem. The frozen walking candidate supplied known rejected cases: excessive jog touchdowns, a large target jump, and missing support in particular directions.

The first adapter replayed saved evidence and returned a compact result. That gave it a clear test: could it retain the important failures without sending the whole log back to the agent? Could it also preserve uncertainty when a historical run lacked a complete identity or completion record?

This was more useful than starting with a new visual score. The expected conclusions came from existing observations, and the tool had to reproduce their scope. If it turned an incomplete log into a clean success, it had made the workflow worse even if its summary looked convenient.

The next step added headless job execution from isolated snapshots. Existing evidence could still be reanalyzed without another engine run. New execution was reserved for changes that actually required new observations.

## One green status was not enough

The result needed separate answers for different kinds of success. A process can exit successfully after doing too little. A recording can be valid while showing bad animation. An animation can satisfy measured bounds while still looking unconvincing.

| Result dimension | What it answers |
|---|---|
| Execution | Did the intended process reach an explicit end? |
| Evidence | Are the inputs, identity, timing, and observations valid for this claim? |
| Mechanical checks | Did the measured behavior meet the selected requirements? |
| Visual review | Did someone inspect the rendered result for the stated scope? |
| User feel | Does the actual experience satisfy the intended direction? |

Separating these answers made the output a little more structured, but much less misleading. The current walking run can have valid evidence and failing mechanical checks. That is a useful result, not a contradiction.

It also prevents the tool from deciding that the game feels good because a command returned zero. The subjective part remains visible and unfinished until it is actually reviewed.

## Small output needs a path back to the detail

Routine summaries are limited to 2 KiB of text. An inspection command can return a larger but still bounded explanation for one finding. Full results and raw evidence stay on disk, so a short answer does not require discarding the supporting material.

An early combined run produced 75,032 bytes of raw stdout and a 1,120-byte summary. A later event-instrumented run produced 197,612 bytes of stdout and a 1,042-byte default summary. These are measurements of response size, not total model-token savings, elapsed-time savings, or billing reductions.

![Raw stdout and returned summary sizes: 75,032 versus 1,120 bytes for the initial run, and 197,612 versus 1,042 bytes for the event-instrumented run.](/assets/img/shoot-to-thrill/evidence-response-size.png)
_Recorded text sizes on a linear KiB scale. The full logs remain on disk. The two rows come from different tool versions, so they do not form a controlled speed or cost comparison._

The summaries retained the recorded failure count and leading measured findings. They did not contain every event. That was deliberate: if I needed a particular interval, I could ask for it by finding rather than reopen the entire log.

This is the useful form of compression for an engineering workflow. The short result tells me where to look next, while the detailed record remains available to challenge the conclusion.

Here is a standalone example of that interface idea, written for the article:

```python
import json

def compact_result(total_checks, failed_checks, detail_url):
    """A teaching example: keep the full evidence elsewhere."""
    if not 0 <= failed_checks <= total_checks:
        raise ValueError("Inconsistent check counts")
    report = {"checks": total_checks, "failed": failed_checks, "details": detail_url}
    return json.dumps(report, separators=(",", ":"))

print(compact_result(76, 6, "evidence.json"))
```

The six failures remain explicit, and the detail field gives the reader somewhere to investigate. The example does not implement the separate execution, evidence, and review states described above, nor does it enforce a byte budget. Those contracts still need their own validation.

For this series, the [public measurement export](/assets/img/shoot-to-thrill/measurements.json) contains the values behind the charts, with units and limitations. The [standalone Python examples](/assets/img/shoot-to-thrill/examples.py) include small self-checks and contain no game source. This gives readers inspectable material while the project implementation remains private.

## Reanalysis must not rewrite history

The analyzer itself changes as the workflow improves. That creates a temptation to treat the latest interpretation as if it were the original execution. We kept those stages separate instead.

Reanalysis uses saved terminal evidence without launching the engine again. It preserves the execution record, retains earlier analysis, and checks that the original inputs still match their receipts. If something changed, the tool refuses to silently authenticate the new material as the old run.

Missing evidence stays missing too. A historical capture without complete profile information cannot become a trustworthy comparison because today's analyzer knows what values would be convenient. A newer phase contract cannot invent phase records that an older recorder never produced.

The same principle applies to source changes. A result belongs to the source and conditions that produced it. The working tree can move forward without erasing the meaning of the earlier experiment.

## A process observation can be unknown

Detached jobs introduced another important distinction. A status check can fail to observe a process because of a permission problem or a timeout. That does not prove the process ended.

The runner therefore distinguishes a confirmed live process, a confirmed missing process, and an unknown observation. An unknown observation does not trigger a restart. Otherwise, a brief monitoring problem could create a duplicate experiment and make the evidence harder to interpret.

Process completion also does not mean analysis publication has finished. A review found a race where final analysis and a concurrent reanalysis could compete to publish results. The fix made both paths coordinate around the same publication boundary.

These are ordinary lifecycle problems, but they matter especially when an agent is acting on compact summaries. The summary must preserve uncertainty rather than convert a missing observation into an authoritative instruction to do more work.

## Event records made the remaining defects more specific

The walking recorder now produces closed measurement phases and event intervals. The final verification included 18 contact phases and nine directional or reversal phases. Unsupported spans and target jumps are recorded against that local sample timeline.

The analyzer checks more than the presence of labels. Phase boundaries must be consistent, observations must be fresh, and event counts and maxima must agree with the phase receipts. Brake and restart preconditions also have to be reached rather than merely requested.

This matters because a convincing label can hide a weak experiment. “Brake at this phase” is not evidence that the character actually reached that phase before braking. Similarly, a complete-looking list of event records is insufficient if some events can disappear without changing the verdict.

The current scope still has a boundary: setup travel between named windows does not yet have the same complete event timeline. The largest global foot jump occurred in that gap. The tool retains the global measurement and states the limit instead of pretending named-phase coverage means all-frame coverage.

## What exists, and what still does not

The current tools have 29 passing focused Python tests. The final headless walking experiment retained 70 passing recorded assertions and six failures. It produced 462 event receipts, including 400 target-jump occurrences; those occurrences are not 400 separate failed test assertions.

Native recording orchestration, broader execution caching, local reference-video tracking, and generated comparison reports remain future work. The existing importer also retains its limits around historical frame verification. There is no automatic visual judge that can replace a normal-speed review or my own reaction to playing the prototype.

The next engineering step is still to improve walking and then revisit the affected upper-body motion. The tools serve that work. They do not redefine completion as having a better dashboard around an unfinished animation.

The lesson is to keep heavy evidence handling outside the conversation while preserving a reliable route back to the evidence. A compact result is useful when it is specific about what happened, what failed, and what remains unknown. That is the interface I want an agent to work from when we continue.

## The complete series

- [1. Learning to See Weight]({% post_url 2026-09-08-gunfeel-01-learning-to-see %})
- [2. Recoil Needs a Shoulder]({% post_url 2026-09-08-gunfeel-02-recoil-needs-support %})
- [3. The Transitions Carry the Weight]({% post_url 2026-09-08-gunfeel-03-connected-weapon-handling %})
- [4. Why Passing Feet Still Look Wrong]({% post_url 2026-09-08-gunfeel-04-walking-contact-evidence %})
- [5. Testing Without Taking My Mouse]({% post_url 2026-09-08-gunfeel-05-testing-without-interruption %})
- **6. Small Results, Honest Evidence** — this post

---

_Written with [GPT-6](https://openai.com/) (exact model ID unavailable) via Codex._
