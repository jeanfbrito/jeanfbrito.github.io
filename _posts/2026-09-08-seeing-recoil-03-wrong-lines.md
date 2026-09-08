---
title: "Seeing Recoil 3: When the Green Lines Lied"
date: 2026-09-08 12:20:00 -0300
categories: [Computer Vision, Game Development]
tags: [opencv, hough-lines, computer-vision, recoil, debugging, yolo, pitfalls]
description: "AABB corners, long Hough rails, and clipped line segments can look like a barrel axis while measuring the sky — here is how the green lines lied."
pin: false
math: false
mermaid: false
series: "Seeing Recoil"
series_order: 3
---

This is the pitfall post. If you only read one entry in **Seeing Recoil**, read this one. I spent real time staring at overlays that looked professional — red boxes, green rail candidates, cyan tips, magenta axes — while the number on screen described a diagonal through the wrong part of the scene. Looking correct is not the same as measuring the bore.

This is part **3** of **Seeing Recoil**:

- [1. Why YouTube Became My Lab](/posts/seeing-recoil-01-why-youtube/)
- [2. Detect the Gun, Then the Body](/posts/seeing-recoil-02-gun-and-pose/)
- **3. When the Green Lines Lied** — this post
- [4. Tip First, Then the Rails](/posts/seeing-recoil-04-tip-first/)

## The seduction of a complete overlay

Once [gun↔pose association](/posts/seeing-recoil-02-gun-and-pose/) works, the next urge is immediate: draw the axis. Humans are excellent at completing a rifle from a few edges. Drawing code is also excellent at completing a rifle from a few edges. The difference is that the human still knows which end is the muzzle, and the early drawing code does not.

I tried several "obvious" constructions before I admitted they were stories about boxes and edges rather than stories about the tip. Each one produced screenshots I could have blogged as successes if I had not paused on the numeric readout.

## Failure 1 — AABB corner as muzzle

Axis-aligned boxes are rectangles. Rectangles have corners. Corners are points. A line between opposite corners is a line. None of that makes the line a barrel.

On frames where the detector returns a tight box around the rifle, the long diagonal can accidentally resemble the weapon. On frames where the box gets fat — hands, helmet, torso fringe, muzzle flash bloom — the same rule aims into the sky.

![AABB diagonal failure on frame 90: magenta axis points into the sky](/assets/images/blog/weapon-cv/02-aabb-fail-f90.jpg)

*Frame 90: a fat gun box earns a confident label, then a corner-to-corner magenta "axis" with a cyan end and a yellow opposite corner. The annotated angle here is not recoil; it is box geometry. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

![Same AABB idea looking accidentally plausible on frame 240](/assets/images/blog/weapon-cv/02-aabb-ok-f240.jpg)

*Frame 240: the same family of corner logic can look almost reasonable when the box happens to align with the rifle. "Almost" is the danger. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

The comparison is the lesson. A method that is occasionally plausible is worse than a method that is obviously broken, because the plausible frames train you to trust the readout. On the failure still, the cyan marker sits where a corner lives, not where the muzzle lives. If I had taken the printed angle seriously — the overlay on that failure frame advertises something like `+37.7 deg` — I would have imported box fatness into a game-feel curve.

## Failure 2 — long LSD/Hough rails in the "forward third"

After the corner disaster, I did the classic computer-vision pivot: find long edges near the front of the gun and call them rails. Restricting the search to a forward-third crop feels responsible. It removes the stock and a chunk of the body. It also concentrates the algorithm on the busiest metal in the frame.

Green line bundles on a handguard look fantastic in a screenshot. They are parallel-ish. They track the weapon's length. They scream "I found the rail." Then you place the cyan tip and the magenta axis using those greens as gospel, and the tip lands on a vent, a shadow, or a handguard slot while the bore continues somewhere else.

The greens were not lying about edges. They were lying about which edge class defines the shot direction. A rail cover is full of short parallel truths. The bore is one quiet truth that may not win a Hough vote if the crop is textured.

## Failure 3 — a line born outside the box, then clipped back

This one is subtle enough that I defended it in my own notes for too long. Suppose an edge detector or a line segment detector proposes a long line that only grazes the gun box. You clip the infinite line (or the long segment) to the AABB so the overlay stays tidy. The clipped segment now lives politely inside the red rectangle. The plot looks disciplined. The geometry is still inherited from a hypothesis that never belonged to the muzzle.

![Rail-line hypothesis extending outside the gun box before clipping](/assets/images/blog/weapon-cv/03-rail-line-outside-box-f240.jpg)

*Frame 240 crop: a rail-oriented line hypothesis that does not respect the gun box as a generative constraint. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

![Same idea after clipping the line to the AABB edge](/assets/images/blog/weapon-cv/03-clipped-to-box-f240.jpg)

*After clipping to the box, the overlay looks contained and intentional. Containment is not correctness. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

Clipping is a presentation operation. I had accidentally promoted it to a measurement operation. If the supporting edge votes came from outside the associated ROI, clipping the artwork does not retrofit permission.

## Failure 4 — greens correct, cyan not on the tip

The most annoying failure is partial success. The short green candidates near the muzzle look right. A human reviewer nods. Then the cyan marker — the point you will actually trust for angle Δ — sits on the front sight, the flash hider's upper edge, or a bright compression artifact beside the true tip.

![Green rail candidates look right while the cyan tip marker misses the muzzle](/assets/images/blog/weapon-cv/04-greens-ok-cyan-wrong-f240.jpg)

*Greens can be locally convincing while cyan misses the tip. If Δ is computed from cyan, the greens were only decoration. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

This frame is why I stopped grading methods by how pretty the rail bundle looked. The question became: is the tip a first-class object in the pipeline, or a leftover intersection?

## A small OpenCV Hough shape gotcha

While fighting the rail stage I also stepped on a mundane API footgun worth naming once. In OpenCV, `HoughLinesP` returns an array with shape `(N, 1, 4)` or, depending on flags and wrappers, something you will eventually flatten into `(N, 4)`. If you treat the raw return like a simple list of `(x1, y1, x2, y2)` tuples without squeezing, you can silently iterate the wrong axis, draw garbage, or keep a single segment when you thought you had many.

The gotcha did not invent the wrong bore. It did waste time that I initially blamed on "Hough being unstable on rifles." Unstable parameters are real. So are shape mismatches. When an overlay flickers between sensible and insane after a "cleanup" commit, print the array shape before you retune thresholds.

## Why wrong lines still produce smooth Δ plots

The cruel property of these failures is temporal smoothness. A fat AABB diagonal can track smoothly as the box breathes. A clipped exterior line can drift smoothly. A cyan point stuck to a front-sight cluster can bounce smoothly enough to look like micro-recoil.

Smooth ≠ true. For game feel I want a number I could defend while scrubbing the video with a friend. If I cannot point at the cyan marker and say "that is the tip," the Δ plot is a story about my bugs.

## What I changed in the grading rubric

After these stills I rewrote the acceptance checks:

1. Can a stranger identify the tip marker without reading the legend?
2. Does the magenta axis pass through the gun rather than across the torso diagonal?
3. Do green candidates support the tip, or does the tip support the greens?
4. If I hide the greens, does the cyan/magenta pair still look inevitable?

Question 4 is the harsh one. It forced the tip-first recipe in [part 4](/posts/seeing-recoil-04-tip-first/).

## Takeaway

Looking correct is not measuring the bore. AABB corners measure boxes. Long rail votes measure texture. Clipped overlays measure my desire for tidy screenshots. Until the tip is detected as a thing, the green lines are allowed to lie.

## Source footage

All failure and near-miss stills above are analysis overlays on the public pilot video [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc). Additional seed links are listed in [part 1](/posts/seeing-recoil-01-why-youtube/).

## Continue the series

- [1. Why YouTube Became My Lab](/posts/seeing-recoil-01-why-youtube/)
- [2. Detect the Gun, Then the Body](/posts/seeing-recoil-02-gun-and-pose/)
- **3. When the Green Lines Lied** — this post
- [4. Tip First, Then the Rails](/posts/seeing-recoil-04-tip-first/)

---

_Written with [Grok](https://x.ai/grok) (`grok-bot`) via Grok Bot._
