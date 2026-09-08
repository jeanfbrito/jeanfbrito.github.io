---
title: "Building Gunfeel 4: Why Passing Feet Still Look Wrong"
date: 2026-09-08 13:03:00 -0300
categories: [Game Development, Godot]
tags: [godot, locomotion, animation, testing, debugging, game-development]
description: "Walking exposed the gap between accurate foot placement and believable support. A precise solver helped, but cadence and contact tests still rejected the gait."
pin: false
math: false
mermaid: false
series: Building Gunfeel
series_order: 4
---

Walking was still strange after several useful gunplay improvements. The rifle could aim, fire, and change carry posture more convincingly, but moving through the scene made the whole presentation feel wrong again. The investigation eventually produced a precise leg-placement result and, at the same time, strong evidence that the walking animation was still unacceptable.

That combination is the subject of this post. It follows [the handling transitions]({% post_url 2026-09-08-gunfeel-03-connected-weapon-handling %}) in **Shoot to Thrill** and explains why I stopped treating a passing spatial check as proof of a convincing gait. This is an unfinished part of the prototype, and the remaining failures are part of the result.

## The first walking complaint was visible at the rifle

The repeated movement of the weapon was initially the most obvious problem. Walking made the rifle nod in a way that felt too regular and too strongly tied to each stride. Several possible causes were moving at once: the body, the camera, the shoulder response, and additional weapon motion.

It would have been easy to make all of them smaller. That might have produced a quieter image without explaining which part was responsible. Instead, we ran isolated comparisons that removed one contribution at a time and observed what remained.

The most useful result came from removing an additional rifle-pitch contribution. It reduced the repeated whole-rifle nod while retaining other movement relationships. A focused native comparison preferred that version for both ordinary and controlled walking. This was a bounded improvement to the first-person presentation, not a conclusion that the gait underneath it was complete.

That distinction became important almost immediately. Improving the view made it easier to keep examining walking, and more demanding movement sequences exposed problems lower in the body.

## Steady walking hid the transition problem

A steady forward walk is a forgiving test. Once the movement has settled into a rhythm, the same conditions repeat. Starting, braking, changing direction, or resuming movement can reveal behavior that never appears in the middle of that cycle.

In the prototype, transient measurements found roughly 389 mm of actual foot travel during one jog turn and 375 mm during braking. A lower-body recording also showed a rapid return toward a neutral placement when stopping, without a convincing recovery step. Those observations changed the task from tuning a pleasant rhythm to preserving contact through changes in motion.

There was also shallow floor penetration in measured boot geometry. That gave us another reason to inspect the final visible foot rather than assuming its intended target described what the player would see. The target and the rendered result were related, but they were not the same evidence.

None of these observations required a full locomotion theory to be useful. They named concrete situations to reproduce and visible relationships to preserve. A foot that appears planted should not slide across the floor during the part of the movement being judged as support.

## Three different questions were hiding inside one check

The investigation became clearer when I separated target quality, pose accuracy, and support over time. It is tempting to combine all three under a label such as “foot placement,” but they can disagree.

| Question | What a passing answer establishes |
|---|---|
| Is the requested position reachable? | The target is geometrically possible for the tested limb |
| Does the final foot reach it? | The pose follows the target with the measured accuracy |
| Does the character remain supported? | The sequence maintains the required contact over time |

A precise solver cannot make a poor target path convincing. A reachable target does not guarantee the final foot gets there. And accurate individual placements do not prove the sequence has the right rhythm or continuous support.

The tests needed to reflect those distinctions. Otherwise, an improvement in one measurement could conceal a remaining problem in another. It was entirely possible to get a better numerical result and still have a character that looked less like it was walking on the ground.

## More precision was useful, but it was not the finish line

One focused investigation showed that the existing leg-solving path could stop with more residual error than the contact check needed. Increasing the amount of iterative work did not produce the required improvement in that case. A more precise leg-only approach then passed an independent check across 1,456 samples with fixed bone lengths.

That was a real result. It established that the tested reachable poses could be followed accurately. It also removed one source of ambiguity from the walking investigation. If the final feet closely followed a poor target trajectory, the next question belonged to the trajectory rather than to solver precision.

The dangerous step would have been to promote that result into “walking is solved.” The independent probe did not represent the whole walking sequence, and it did not judge the player-facing motion. Its value was in making the next experiment more specific.

This is why I now like tests that make a narrow claim clearly. A limited result is not weak if its boundary is explicit. It becomes misleading when the boundary disappears from the description.

## Support made the remaining problem impossible to ignore

Positive support checks changed the verdict on the candidate. Earlier spatial measurements could look acceptable while controlled walking contained long intervals with neither foot providing the required ground contact. A stable-looking pivot was insufficient if the actual boot was not supporting the body.

Direction also mattered. A forward result did not generalize to strafing or diagonals. The latest frozen checkpoint still had unsupported intervals in four tested controlled-walking directions, even though some other directions met the same requirement.

![Unsupported frames for eight controlled walking directions: forward zero, backward zero, right sixty-two, left zero, back-right thirty-eight, forward-right thirty-two, back-left seventy-five, forward-left zero, each out of one hundred eighty.](/assets/img/shoot-to-thrill/walking-support.png)
_Measured results from the frozen candidate: 180 frames per direction at 60 FPS. The dashed line is this prototype check's allowance of at most two unsupported frames. Showing every direction makes the asymmetry visible._

These are results from this prototype and this test setup. They are not universal walking tolerances or measurements of a reference game. Their purpose is to show why a broad claim of completion would be wrong.

Cadence supplied another independent rejection. The jogging case produced 17 foot touchdowns for 11 body steps, and the sequence did not alternate as required. A foot can arrive at a plausible position and still arrive too often or in the wrong order.

![Controlled walking records nine body steps and nine alternating foot touchdowns; jogging records eleven body steps and seventeen nonalternating touchdowns.](/assets/img/shoot-to-thrill/walking-cadence.png)
_Both measurement windows contain 240 frames, or four seconds. Matching counts in one case establish a much narrower result than a successful gait across every transition._

The totals also hide the shape of a failure. Sixty-two isolated frames and several long unsupported intervals would ask different questions of the movement system. Here is the actual distribution within each direction's measurement window:

![Eight three-second contact timelines, with orange spans showing the measured unsupported intervals in right, back-right, forward-right, and back-left movement.](/assets/img/shoot-to-thrill/walking-contact-timeline.png)
_Each row starts at its own measurement window. Orange spans come from recorded contact flags; they are not illustrative placements. [Download the counts and interval data](/assets/img/shoot-to-thrill/measurements.json)._

A small standalone Python example shows how boolean observations become intervals. This is teaching code written for the article, separate from the private game implementation:

```python
def true_runs(flags):
    """Return [start, end) intervals for contiguous True values."""
    runs, start = [], None
    for index, value in enumerate([*flags, False]):
        if value and start is None:
            start = index
        elif not value and start is not None:
            runs.append((start, index))
            start = None
    return runs

assert true_runs([False, True, True, False, True]) == [(1, 3), (4, 5)]
```

The assertion uses toy data. For real measurements, `True` means the contact check recorded a frame without support. Divide the interval boundaries by the recording rate to put them on a time axis. This grouping preserves duration and order; it does not decide whether the underlying contact detector is correct.

## The largest jump was another clue, not a tuning target

The final recorded contact metrics also retained a target discontinuity of about 328 mm in one sampled frame. That is a useful symptom because it points to a short interval worth investigating. It is not a number to hide by making the acceptance threshold more generous.

Later event recording clarified an important detail: the largest global jump occurred during setup travel before a named braking window began. A large jump inside a named restart phase was separately recorded at about 313 mm. The distinction matters because a label inherited from an earlier action can misdescribe what was actually happening at the worst sample.

This exposed a limit in the measurement workflow as well as a gait problem. Named phases gave us useful coverage, but they did not automatically describe every setup interval between phases. That boundary remains explicit in the current checkpoint.

## Why the upper body has to be reviewed again

The foot investigation also involved the position of the body over the legs. That is unavoidable context for reach and support, but it means the change can affect the rifle and the camera. Earlier reviews of aiming, carry, and recoil cannot be treated as current evidence after the surrounding body motion changes.

The correct next step is therefore larger than making the foot metrics pass. The lower-body candidate still needs mechanical acceptance, a native visual review, and another look at combined walking, aiming, firing, and reloading. The earlier improvements remain useful history; they do not waive the new comparison.

At the documented pause, the combined walking run had 70 of 76 recorded assertions passing. The six failures remained visible, and no native after-contact recording had been accepted. That is the honest state of the work.

The lesson I am carrying forward is that animation tests need to ask about time and relationships, not only positions. Accuracy helped us see the remaining problem more clearly. It did not make that problem disappear.

## Continue the series

- [1. Learning to See Weight]({% post_url 2026-09-08-gunfeel-01-learning-to-see %})
- [2. Recoil Needs a Shoulder]({% post_url 2026-09-08-gunfeel-02-recoil-needs-support %})
- [3. The Transitions Carry the Weight]({% post_url 2026-09-08-gunfeel-03-connected-weapon-handling %})
- **4. Why Passing Feet Still Look Wrong** — this post
- [5. Testing Without Taking My Mouse]({% post_url 2026-09-08-gunfeel-05-testing-without-interruption %})
- [6. Small Results, Honest Evidence]({% post_url 2026-09-08-gunfeel-06-evidence-outside-context %})

---

_Written with [GPT-6](https://openai.com/) (exact model ID unavailable) via Codex._
