---
title: "Building Gunfeel 2: Recoil Needs a Shoulder"
date: 2026-09-08 13:01:00 -0300
categories: [Game Development, Godot]
tags: [godot, recoil, animation, references, cameras, game-development]
description: "A rising muzzle did not make our rifle feel heavy. Comparing firing footage helped separate shot onset, recovery, body support, and camera motion."
pin: false
math: false
mermaid: false
series: Building Gunfeel
series_order: 2
---

The rifle pointed upward when it fired, but I could not see the shot loading into the person holding it. That was the most useful recoil feedback I gave **Shoot to Thrill**, my Godot prototype. It moved the conversation away from the amount of animation and toward the relationship between the rifle, its support, and the player's view.

In [part one]({% post_url 2026-09-08-gunfeel-01-learning-to-see %}), I described why Project Killhouse became a visual target and why different references needed different jobs. This post follows the recoil investigation. It is an account of what we observed and how we compared it, not a release of the private implementation or a claim to have measured firearm physics from video.

## A recoil pattern answers only part of the question

Repeated fire makes a pattern visible. The sight picture changes, shots accumulate, and the player sees the system recover when firing stops. A pattern can make these changes consistent enough to learn, but consistency alone does not make the weapon look supported or heavy.

My early reaction was that the movement looked fake. Watching more carefully, I could separate that reaction into several moments: the first disturbance, the behavior while the trigger stayed down, and the return after release. A change could improve one moment while making another less convincing.

That led to a more useful comparison than “old recoil versus new recoil.” I wanted to compare onset against onset and recovery against recovery. If the reference appeared to load backward before resolving forward, a candidate that immediately dipped into its return was following a different visual story. Increasing the size of that path would preserve the difference.

## What the references were useful for

[Killhouse's published procedural weapon animation material](https://www.devunallocated.com/projects/project-killhouse/procedural-weapon-animations) was a useful animation reference because it put weapon presentation in the context of handling. I used that material to judge visible continuity and responsiveness, rather than treating it as a set of numerical values to transfer into another engine.

Real firing footage supplied a different kind of evidence. In an external view, I could look for coordinated motion around the rifle and upper body. In a view closer to the eye, I could look at the disturbance in the optic or sights relative to the background. Those questions are related, but one view does not replace the other.

I also had to resist combining unlike examples into a single imagined standard. Different firearms, different operators, and different camera positions do not provide interchangeable amplitudes. A clip can be useful for the order of events without being useful for the amount of motion I should apply to this particular prototype.

The observations that survived that caution were qualitative: a brief readable disturbance, a recovery that remained understandable, and support that continued to look connected. They were enough to reject obviously unconvincing motion without pretending the footage contained a complete physical specification.

## The camera can hide the thing being measured

First-person animation has an awkward measurement problem: the observer moves. A rifle can travel in the world while appearing relatively stable on screen if the camera follows it. It can also appear to move strongly on screen because the camera moved, even when the weapon's relationship to the body changed very little.

This matters when the complaint is about a shoulder kick. Looking only at receiver displacement in the image can produce the wrong conclusion. The visible result combines movement of the object and movement of the viewpoint. Without another view or another measurement, I do not know how much each contributed.

I started asking three separate questions during review. What changed in the world? What changed between the weapon and the eye? What changed in the supporting relationships? This did not require publishing internal transforms or a new mathematical model. It required keeping the interpretation of each image precise.

It also explained why a single tracking point was insufficient. A point on the muzzle can describe an interesting path while leaving the receiver, the hands, or the background out of the story. A convincing recoil sequence needs more than one point to agree about what just happened.

## A practical way to review one shot

I found it useful to split a shot into visible phases without turning those phases into a claim about a universal duration. The phase boundaries were a review aid, and their timing still had to be checked in each recording.

| Moment | What I looked for |
|---|---|
| Before firing | A stable, readable supported pose |
| Initial disturbance | Motion that starts in a convincing direction |
| Disturbed sight picture | A visible consequence of the shot |
| Recovery | A connected return rather than a detached reset |
| Return to control | A usable continuation into the next action |

The first few frames were especially valuable when diagnosing direction. Normal-speed playback was more useful for deciding whether the complete action felt convincing. Both views belonged in the process. Slow playback can reveal a discontinuity, but it can also make a brief event look more important than it feels at normal speed.

I kept the full frame available for the same reason. A tight crop helps inspect a hand or an optic. It also removes context that may explain the motion. The crop and the full view answered different questions, so one could not silently replace the other.

## Sustained fire needs its own review

<video class="embed-video file" controls preload="metadata" playsinline width="1280" height="720" poster="{{ '/assets/img/shoot-to-thrill/recoil-poster.png' | relative_url }}" aria-label="Shoot to Thrill: four seconds of a scripted semi tap followed by held automatic fire">
  <source src="{{ '/assets/img/shoot-to-thrill/recoil-sequence.mp4' | relative_url }}" type="video/mp4">
  <a href="{{ '/assets/img/shoot-to-thrill/recoil-sequence.mp4' | relative_url }}">Download the four-second recoil clip</a>.
</video>

_A silent, normal-speed excerpt from an earlier Shoot to Thrill handling checkpoint: a semi tap, followed by held automatic fire. Watch the onset, the repeated disturbance, and the transition after release. This first-person view cannot establish physical shoulder displacement or real-world recoil forces._

Rendering and animation by Jean Brito. Rifle: [TastyTony, “Low-Poly M4a1”](https://sketchfab.com/3d-models/low-poly-m4a1-8cab1cbeb82c4396a154f9fc8771417b), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Arms adapted from [FPS-animation-POC](https://github.com/rdstrcorpse/FPS-animation-POC), [MIT](/assets/img/shoot-to-thrill/arm-visuals-license.txt).

For the reference side of the comparison, [the eye-position MP5 footage](https://www.youtube.com/watch?v=FPXuHKrMTwE) was particularly useful to me. It is a different firearm and camera setup. I use it to examine the sight/background relationship and the order of visible events; I do not scale our recoil from its apparent pixel displacement. The linked footage belongs to its creator and is separate from our prototype capture.

A single acceptable shot is not enough evidence for automatic fire. Repetition reveals whether the motion accumulates in a useful way, whether each disturbance remains readable, and what happens when the trigger is released. It can also expose how obviously the same small animation repeats.

The goal was bounded, coherent disturbance. I did not want sustained fire to look like an identical upward staircase, but I also did not want arbitrary variation to become a substitute for support. Randomness can make frames less identical without making the sequence more believable.

Release was part of this test. A burst does not end at the final muzzle flash from the viewer's perspective. It ends when the movement resolves into a controlled posture that can continue into aiming or movement. Cutting the recording too early would hide exactly the part I needed to compare.

That changed how I selected clips. A useful take included a settled beginning, the firing interval, and enough time afterward to judge the return. The extra context made comparisons more honest even when it made the recording less dramatic.

## Where making it bigger nearly became the answer

The obvious response to “I cannot feel the kick” is more translation or more rotation. That can be the right experiment, but it is not a diagnosis. If the support relationships separate during the added motion, the weapon may become more visibly weightless as the animation gets stronger.

Another trap was treating external placeholder anatomy as a complete first-person verdict. An external review showed coordinated rearward head, chest, and rifle motion with continued grip, while also exposing limitations in the coarse shoulder surface and sleeve presentation. Those limitations mattered, but they did not establish that the first-person recoil needed a larger amplitude.

Keeping the findings separate prevented a broad retune based on the wrong evidence. The external view could support a claim about coordinated motion and still leave anatomical surface contact unproven. The first-person view could support a bounded improvement and still leave exact physical fidelity unproven.

## The result was a narrower, stronger claim

At the reviewed checkpoint, abrupt onset, slower recovery, bounded held fire, and coherent grip were visible. A focused external recording also supported coordinated upper-body response. That was useful progress. It did not prove that every shot, every pose, or every future weapon would satisfy the same standard.

The main lesson was that recoil reads through connected relationships. A moving muzzle is evidence of movement. A convincing shot needs the rest of the presentation to explain how that movement is being supported and controlled. The next problem was preserving those relationships when the player changed actions.

## Continue the series

- [1. Learning to See Weight]({% post_url 2026-09-08-gunfeel-01-learning-to-see %})
- **2. Recoil Needs a Shoulder** — this post
- [3. The Transitions Carry the Weight]({% post_url 2026-09-08-gunfeel-03-connected-weapon-handling %})
- [4. Why Passing Feet Still Look Wrong]({% post_url 2026-09-08-gunfeel-04-walking-contact-evidence %})
- [5. Testing Without Taking My Mouse]({% post_url 2026-09-08-gunfeel-05-testing-without-interruption %})
- [6. Small Results, Honest Evidence]({% post_url 2026-09-08-gunfeel-06-evidence-outside-context %})

---

_Written with [GPT-6](https://openai.com/) (exact model ID unavailable) via Codex._
