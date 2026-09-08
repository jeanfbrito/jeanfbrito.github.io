---
title: "Seeing Recoil 2: Detect the Gun, Then the Body"
date: 2026-09-08 12:10:00 -0300
categories: [Computer Vision, Game Development]
tags: [yolo, pose-estimation, ultralytics, putbullet, computer-vision, recoil, roi]
description: "Dual YOLO gun boxes plus pose skeletons let me associate wrists to weapons before I trust any barrel geometry for recoil angle Δ."
pin: false
math: false
mermaid: false
series: "Seeing Recoil"
series_order: 2
---

A gun bounding box alone is a rectangle with confidence text. A pose skeleton alone is a stick figure that happens to be near a rifle. Recoil measurement needs both at once: a region that probably contains the firearm, and a body that probably owns it. Only after that association do I let edge filters argue about rails and tips.

This is part **2** of **Seeing Recoil**:

- [1. Why YouTube Became My Lab](/posts/seeing-recoil-01-why-youtube/)
- **2. Detect the Gun, Then the Body** — this post
- [3. When the Green Lines Lied](/posts/seeing-recoil-03-wrong-lines/)
- [4. Tip First, Then the Rails](/posts/seeing-recoil-04-tip-first/)

## Dual YOLO instead of a custom mythology

I did not start by inventing a detector. I started with a public dual-model pattern that already speaks the language I need: find guns, find people, then reason about the pair.

The public project I used as a reference implementation is [putbullet/firearms-detection-system](https://github.com/putbullet/firearms-detection-system) (MIT). It is built around YOLO-style detection for firearms alongside person/pose context rather than treating the gun as an isolated icon. That matches the YouTube lab problem better than a single-class toy detector trained on product photos.

On top of that idea I stay inside the ordinary [Ultralytics YOLO](https://docs.ultralytics.com/) ecosystem for the day-to-day runs: one path for gun boxes, one path for pose keypoints, both producing per-frame outputs I can draw and debug. The exact weights and glue code live in a private research tree I am not linking here. The technique is what travels.

The important architectural choice is ordering:

1. Detect candidate gun boxes.
2. Detect pose skeletons.
3. Associate boxes to skeletons using wrists, elbows, and torso proximity.
4. Only then crop or mask a region of interest for geometry.

Skip step 3 and you will eventually measure the wrong person's muzzle, or a background false positive that looks gun-shaped to a tired detector.

## What the association actually uses

Association does not need a novel network. On the pilot clip, a greedy geometric rule is enough to start:

- Prefer gun boxes whose center lies near the forearm segment between elbow and wrist.
- If two boxes compete, prefer the one closer to either wrist keypoint.
- Soft-reject boxes that sit on the wrong side of the torso relative to the aiming direction suggested by the shoulders.

That rule set is crude. It also fails honestly. When wrists are occluded, the association score collapses and I can skip the frame instead of inventing a bore line. Skipping frames is underrated. A recoil Δ built from twenty trusted frames beats a Δ averaged across two hundred half-wrong ones.

![Enhanced frame 240 with red gun boxes and green pose skeletons](/assets/images/blog/weapon-cv/01-yolo-pose-enhanced-f240.jpg)

*Pilot clip frame 240: gun boxes and pose skeletons on the CLAHE+gamma working copy. Wrists and forearms are the bridge between the red rectangles and the people who own them. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

![Enhanced frame 599 showing multi-box detection on the rear shooter](/assets/images/blog/weapon-cv/01-yolo-pose-enhanced-f599.jpg)

*Frame 599 from the same take. Overlapping gun boxes on one rifle are not a curiosity — they are the default failure mode once confidence thresholds get hungry. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

In the overlays you can see confidence labels in the `0.5`–`0.8` band on usable boxes. Those numbers are detector confidences, not geometry confidences. A `gun 0.79` box can still be fat, rotated poorly relative to the bore, or duplicated. Part 3 is about what happens when I trust the box corners anyway.

## Why hand-picked clips skip phone-versus-gun hardening

If this were a safety product for arbitrary uploads, the next month of work would be adversarial: phones held like pistols, toys, controllers, compressed thumbnails, mirror selfies, and every false positive a reviewer can screenshot. That is a real problem domain. It is not my problem domain today.

I hand-picked seed clips where:

- The object is clearly a shoulder-fired rifle in a shooting context.
- The framing is wide enough for pose.
- I am willing to discard frames instead of forcing a label.

That choice is a scope cut, not a claim that the detector is robust. By skipping phone-versus-gun hardening, I spend the engineering budget on barrel-axis geometry — the part that actually feeds game-feel reference numbers. If a future week needs open-web robustness, that becomes a different series with different metrics.

The seed set from [part 1](/posts/seeing-recoil-01-why-youtube/) stays small on purpose. Five public videos are enough to keep me honest about lighting and multi-person overlap without pretending I have solved content moderation.

## ROI before geometry

Once a gun box is associated to a pose, I treat the box as a **region of interest**, not as a measurement. That sounds obvious. It was the sentence I had to re-learn after watching beautiful overlays lie to me.

A useful ROI policy on these clips looks like this:

- Expand the associated gun box slightly so the muzzle is less often clipped.
- Optionally build a tighter forward crop around the front third for tip search later.
- Run classical edges and line hypotheses only inside those crops.
- Keep the pose available so a tip estimate can be biased by aim direction from the wrists.

Everything geometric after this point is conditional on the ROI being roughly right. If the box swallowed half a torso, every clever Hough line still inherits that mistake. If two boxes fight over the same rifle, the ROI jitter becomes angle jitter, and angle jitter becomes a fake recoil signature.

## Pitfall: multi-box and background false positives

The rear shooter in frame 599 is the teaching example. Multiple red boxes latch onto one weapon with different confidences. A naive "take the max confidence box" rule can hop between siblings across adjacent frames. The hop is small in image space and loud in angle space.

Background false positives are quieter and worse. A dark post, a tripod leg, or a second tool in the scene can earn a medium-confidence gun label. Without pose association, that box looks like any other ROI. With pose association, it usually fails the wrist test and drops out. That is the whole point of detecting the body instead of worshipping the gun head.

My practical mitigations on the pilot work:

- Non-maximum suppression with a stricter overlap threshold than the detector default when two boxes share a pose.
- Per-pose gun capacity of one unless the clip is deliberately about a handover.
- Frame skip when the winning association score falls below a conservative cutoff.

I still see leftovers. The pipeline is a lab instrument, not a courtroom exhibit.

## What this buys the recoil number

Remember the target from part 1: weapon axis angle Δ as a game-feel reference. Association does not compute Δ. It makes Δ attributable.

After this stage I can say: on frame 240, this skeleton owns this box, so the tip search in that crop is allowed to vote. On a frame where association fails, I record a gap instead of a fantasy. Gaps are visible in a plot. Fantasies look like physics.

The next post is where I stop being polite about geometry. I will walk through the wrong lines — AABB diagonals, long rail hypotheses in the forward third, lines born outside the box and clipped back in — and show how each one can look intentional while measuring the wrong thing.

## Takeaway

Detect the gun, then the body, then the relationship between them. Region of interest comes before geometry. If the wrists do not claim the box, I do not owe that box a bore line.

## Source footage

Overlays in this post are analysis frames drawn on publicly available YouTube video, especially the pilot [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc). The wider seed list lives in [part 1](/posts/seeing-recoil-01-why-youtube/).

## Continue the series

- [1. Why YouTube Became My Lab](/posts/seeing-recoil-01-why-youtube/)
- **2. Detect the Gun, Then the Body** — this post
- [3. When the Green Lines Lied](/posts/seeing-recoil-03-wrong-lines/)
- [4. Tip First, Then the Rails](/posts/seeing-recoil-04-tip-first/)

---

_Written with [Grok](https://x.ai/grok) (`grok-bot`) via Grok Bot._
