---
title: "When C++ Audio Work Waits Before It Plays"
date: 2026-10-28 11:08:48 -0300
categories: [Game Development, Godot]
tags: [godot, game-development, game-audio, acoustics, debugging, benchmarking, testing, pitfalls]
description: "A Godot audio callback can start late even when its C++ work is short. Trace admission, queue residence, preparation, and callback onset separately."
pin: false
math: false
mermaid: false
---

An NPC footstep in my Godot game sounded late. The audio work lived in C++, so I first wanted to know what the C++ code was doing for so long. That question mixed two different durations: time spent executing a sound, and time spent waiting for the sound's turn. I needed a timeline that kept them apart.

## The setup

The game uses a C++ acoustic engine through a Godot GDExtension. A sound enters a queue, and a planner computes its route to the player. The same legacy planner also processes hearing jobs for NPCs. Those jobs keep each listener's masking history in order. A separate worker handles some physical player events, but the current game route does not send legacy NPC footsteps through that worker.

The legacy planner takes one eligible job, finishes it, and takes another. A hearing job can wait for a probe field or a prepared path before it completes. The planner's condition-variable wait releases the probe-cache mutex, but it still occupies the **planner thread**. Later sounds cannot enter that thread until the job finishes or the scheduler selects another eligible job.

That is why moving arithmetic to C++ does not, by itself, guarantee an on-time sound. The relevant question is not just “how long does this sound compute?” It is also “when does the sound reach the thread that publishes it?”

## What worked

### Give each boundary its own clock

The first clue was one NPC step with `queue_ms=257.4 ms` and only about `0.5 ms` of planner CPU time. Its callback started about 259 ms after the planned start. I first treated `queue_ms` as pure queue residence. That was wrong: the code assigned it again after geometry preparation and lock acquisition. I added timestamps at admission and removal, then recorded each stage that follows:

| Stage | Question it answers |
| --- | --- |
| Admission | How long did the submit call take before queue insertion? |
| Queue residence | How long did the job wait before a planner removed it? |
| Geometry wait | Did the planner wait for a worker or do geometry work itself? |
| Field preparation | Did pre-planning work hold the planner? |
| Planning lock | Did another caller hold a required lock? |
| Acoustic work | How long did the final sound calculation and publication call take? |
| Callback start | When did the mixer actually start the voice? |

Each planned sound retains its voice ID. The session recorder uses that ID to join the planned result with the `audio_start` callback receipt. Without that join, a planned publication is easy to mistake for an audible start. The callback is a stronger timing observation, although it does not prove that the sound had the right level or that a person heard it.

I kept wall time and thread CPU time separate. If wall time grows while CPU time stays short, the planner may be waiting for another worker or for scheduling. CPU time alone cannot say which one. The code needs a clock on the exact wait site to answer that.

### Trace the dependency, not only the delayed sound

A late step can have a short final acoustic stage. That tells me the step itself did not spend the whole delay in its final calculation. It does not identify the earlier work. I therefore record the preceding job's sequence, kind, wall time, and thread CPU time. The preceding job is a lead, not necessarily the only job that delayed the step.

In one windowed run, 39 NPC steps produced 39 callback receipts. The median queue residence was 148.5 ms, while the median final acoustic stage was 0.4 ms. The callback started a median of 162.7 ms after the planned start. Twenty-four of those steps started more than 50 ms late. Here is an excerpt of the report, with only the relevant fields:

```text
KIND step started=39/39 late_over_50ms=24
  wait_to_dequeue_ms: n=39 median=148.5 p95=915.0 max=1119.3
  acoustic_ms: n=39 median=0.4 p95=1.0 max=1.2
  callback_delay_ms: n=39 median=162.7 p95=914.7 max=1120.0
```

I also put opt-in timing at two hearing dependencies: the wait for a probe field and the wait for prepared paths. Both use condition variables. The older `flood_ms` and `path_ms` totals can include those waits, so adding them to the wait fields would count some time twice. The report shows the fields side by side instead.

The same run logged 12 slow NPC hearing jobs. Eight spent more time waiting for paths than fields. One job spent 1,137.6 ms waiting for paths, but used only 0.3 ms of CPU on the planner thread. The excerpt removes the listener key and retains the measured stages:

```text
HEAR_TRACE n=12 errors=0 hear_rejections=0
HEAR_WAIT field_dominant=4 ways_dominant=8
SLOW_HEAR seq=22 wall_ms=1165.2 cpu_ms=0.3
  field_wait_ms=0.0 ways_wait_ms=1137.6 source_ms=27.4
```

This run also ties that hearing job to one late step. Step 248 lists hearing job 22 as its preceding planner job. It spent 1,119.3 ms waiting to leave the queue, then 0.4 ms in its final acoustic stage. Its callback delay was 1,120.0 ms:

```text
SLOW_STEP sequence=248 wait=1119.3 acoustic=0.4 cpu=0.5
  callback_delay=1120.0 depth=239 preceding=22 kind=2
  preceding_wall=1165.3 preceding_cpu=0.4
```

Here `kind=2` means an NPC hearing job. The prior job spent 1,165.3 ms on the planner thread, mostly waiting for prepared paths. The trace identifies this blocker for this step. It does not prove that the same job delayed every step in the report.

A small Python harness runs the windowed game with explicit planner flags and a real audio device. It writes the run log and a report beside the session data. Another script analyzes an existing session without starting the game again. Its tests check the voice-ID join and make a missing callback visible rather than silently treating it as an on-time start.

A reproducible command takes this form:

```bash
python3 tools/perf/run_plan_stages.py diagnosis 95 \
  --sample_profile=/absolute/path/to/private-profile.json
```

The profile path above is a placeholder, not a file to publish. The harness takes the Village timing lock and enables detailed hearing logs only in its child process. It passes the planner settings explicitly. The session's UI option snapshot does not establish which native settings ran, so the recorded command arguments matter.

## Where it almost went sideways

### A metric named “queue” included preparation

The second assignment to `queue_ms` happened after other stages. It was useful as elapsed time since submission, but not as proof that the job sat untouched in the queue. Renaming a chart would not fix that. Separate timestamps let the report distinguish queue residence from preparation and lock wait.

### One slow sound did not name its blocker

Subtracting a sound's CPU time from its callback delay gives a large remainder. That remainder is not automatically a single preceding job. It can include queue residence, geometry work, a dependency wait, scheduling, and the mixer's callback boundary. The diagnostic now records these boundaries instead of assigning the remainder to an attractive suspect.

### A busy machine can turn a diagnosis into a benchmark by accident

The machine can be busy for reasons outside the game. This run's load averages were 37.44 before and 84.67 after. They were far above my acceptance threshold of about 10. The trace shows *which stage waited* in this run, not the normal delay distribution. I will repeat it on a quiet machine before making a performance claim or changing the game default.

The headless Dummy audio driver presents a different trap. It renders large blocks, so its callback timing does not measure the windowed device path. Native tests can check ordering and PCM. The windowed run checks onset on the real audio path. Listening and level checks still matter when an acoustic change follows.

## Takeaway

A fast function is not the same as a timely sound. Measure the complete path from submission to the callback, and separate CPU work from wall-clock waits. When a queued sound starts late, trace the work that occupies its planner before changing its acoustic math.

---

_Written with `cx/gpt-6-sol-high` via Claude Code. A public model page for this runtime ID was not available._
