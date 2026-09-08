---
title: "Seeing Recoil 4: Tip First, Then the Rails"
date: 2026-09-08 12:30:00 -0300
categories: [Computer Vision, Game Development]
tags: [computer-vision, recoil, yolo, pose-estimation, opencv, game-feel, tips]
description: "Locking a tip-point-first recipe — pose aim, farthest strong edge, short greens, cyan on midline, magenta clipped to the box — finally made barrel-axis Δ trustworthy."
pin: false
math: false
mermaid: false
series: "Seeing Recoil"
series_order: 4
---

After [the green lines lied](/posts/seeing-recoil-03-wrong-lines/), I stopped asking rails to invent a muzzle. The locked recipe is tip-point-first: find a tip candidate as an object, then let short edges and a midline explain it. Only after that pair looks inevitable do I trust a magenta axis enough to talk about weapon-axis angle Δ for game feel.

This is part **4** of **Seeing Recoil**:

- [1. Why YouTube Became My Lab](/posts/seeing-recoil-01-why-youtube/)
- [2. Detect the Gun, Then the Body](/posts/seeing-recoil-02-gun-and-pose/)
- [3. When the Green Lines Lied](/posts/seeing-recoil-03-wrong-lines/)
- **4. Tip First, Then the Rails** — this post

## The locked recipe

The steps below are the working order on the pilot clip. They assume the earlier pipeline already produced an associated gun box and pose, usually on an enhanced working copy as described in [part 1](/posts/seeing-recoil-01-why-youtube/) and [part 2](/posts/seeing-recoil-02-gun-and-pose/).

### 1. Prefer tip priors from pose

Wrists and elbows give an aim direction even when the muzzle is low-contrast. I build a coarse aim ray from the associated pose — roughly shoulder/torso through the wrist cluster — and use that ray as a prior for where "forward" means inside the gun ROI. The prior is not the measurement. It is a bias that keeps tip search from wandering toward the stock or a second person's rifle.

### 2. `tip_raw` = farthest strong edge along aim

Inside the gun box (and often a tighter forward crop), I look for strong edge responses along the aim prior and keep the farthest plausible peak as `tip_raw`. "Farthest" is measured along the aim direction, not as a raw image-coordinate maximum that simply loves the top of the frame.

This is the philosophical break from part 3. The tip is allowed to exist before any rail bundle wins a vote. If `tip_raw` is weak, I skip the frame. I do not fall back to an AABB corner.

### 3. Short greens around the tip

Only after `tip_raw` exists do I gather short line candidates near that neighborhood — the greens. Their job is local support: confirm that metal structure near the tip agrees with a small bundle of orientations. They are witnesses, not authors.

Long LSD/Hough rails across the whole forward third are demoted. Short greens near the tip are promoted. That swap removes a lot of handguard democracy.

### 4. Cyan = tip on the midline

I refine `tip_raw` onto a local midline estimate so the cyan marker sits on the tip rather than on the brightest neighboring corner. Visually, cyan is the point I should be able to defend while scrubbing. Numerically, cyan is the anchor for Δ.

If cyan and the green bundle disagree too loudly, that is a reject, not a blend. Blending was how I used to hide the disagreement until the plot looked smooth.

### 5. Magenta clipped to the box — after the tip exists

The magenta axis is now a line that must explain the cyan tip inside the associated ROI. Clipping magenta to the gun box is finally legitimate because the line was born from tip geometry rather than from an exterior hypothesis that needed cosmetic trimming. Yellow marks the rear reference on the axis for reading direction in stills.

On successful pilot frames the overlay text shifts into a tip-guided reading — on frame 240 the full scene label lands around `tip_guided +7.3`, with a companion rifle nearby around `+6.7`. Those are image-plane angle readouts from this recipe on those frames, not universal recoil constants. The important part is that I can point at cyan and believe it.

## What the success stills show

![Tip-first full frame 240 with cyan tips and magenta axes on both rifles](/assets/images/blog/weapon-cv/05-tip-first-full-f240.jpg)

*Frame 240, full enhanced scene: tip-guided magenta axes terminate at cyan muzzle markers instead of box corners. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

![Closer tip-first overlay on frame 240](/assets/images/blog/weapon-cv/05-tip-first-f240.jpg)

*Frame 240 detail of the tip-first stack: short greens support a cyan tip; magenta follows. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

![Tip-first crop focused on the muzzle neighborhood at frame 240](/assets/images/blog/weapon-cv/05-tip-first-crop-f240.jpg)

*Forward crop at frame 240: the recipe is judged here first — if cyan is wrong in the crop, the full-frame plot does not get a vote. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

![Tip-first result on frame 599](/assets/images/blog/weapon-cv/05-tip-first-f599.jpg)

*Frame 599 under the same tip-first recipe. Later frames still need association discipline from part 2; geometry cannot rescue a mismatched ROI. Source: [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc).*

## Overlay legend

When you read these stills, the color language is:

| Color | Meaning |
|---|---|
| Red box | Associated gun ROI from the detector |
| Orange box | Optional tighter forward crop for tip search |
| Green segments | Short local edge/rail witnesses near the tip |
| Cyan point/segment | Refined tip on the midline — the measurement anchor |
| Magenta line | Barrel-axis hypothesis constrained by the tip and clipped to the ROI |
| Yellow point | Rear reference along the magenta axis |
| Green skeleton | Pose used for association and aim priors |

If a still breaks this legend — cyan floating in the sky, magenta across a torso diagonal — it belongs in [part 3](/posts/seeing-recoil-03-wrong-lines/), not in the success folder.

## What Δ is allowed to mean now

With tip-first locked, weapon-axis angle Δ becomes a comparison tool again:

- Compare Δ time series across algorithm versions on the same clip.
- Compare onset sharpness between two public takes of similar weapons without pretending the cameras are calibrated twins.
- Translate qualitative feel notes ("too floaty on recovery") into questions about the measured recovery slope.

It still is not a ballistics report. Camera roll, lens compression, and shooter stance all live inside the number. For game feel reference, that is acceptable as long as the failure modes are visible.

## Honest leftovers

Tip-first fixes the class of bugs where rails elected a fake muzzle. It does not erase:

- Multi-box jitter from part 2 when NMS is too polite.
- Muzzle flash frames where `tip_raw` jumps to the brightest bloom.
- Profile shots where the tip is real but the bore direction is nearly depth-aligned and image-plane Δ shrinks for geometric reasons unrelated to soft game recoil.
- Vertical shorts in the seed set that still need human triage.

Those are open. They are also scoped. I would rather publish a narrow honest instrument than a wide quiet one.

## What's next

The next experiments, still in the same public framing, are about richer references rather than a bigger scrape:

- **Hands as first-class contacts** — using pose wrists not only for association but for a support relationship when interpreting recoil as a whole-body event.
- **Optic locus** — a second point on optics or iron sights so tip Δ can be compared against sight-picture motion in the same clip.
- **Stream overlay** — a live debug view that paints the legend while the video plays, so bad cyan placements are caught during scrubbing instead of later in a CSV.

I am intentionally not documenting private ops, host setup, or internal tooling here. The portable part is the measurement order: tip as a thing, then rails as witnesses, then Δ as a reference for feel.

## Takeaway

Detect the tip as a thing before fitting lines. Short greens may support it. Magenta may explain it. Cyan must be it. Until that order holds, recoil plots are just confident fiction.

## Source footage

Success stills are analysis overlays on the public pilot video [WwZBpixr4Yc](https://www.youtube.com/watch?v=WwZBpixr4Yc). The seed playlist for the lab is:

- https://www.youtube.com/shorts/FPXuHKrMTwE
- https://www.youtube.com/watch?v=WwZBpixr4Yc
- https://www.youtube.com/shorts/RbRxdz8ofSs
- https://www.youtube.com/watch?v=b2wOTXJ3wXk
- https://www.youtube.com/watch?v=2umbSAzgk-8

## Continue the series

- [1. Why YouTube Became My Lab](/posts/seeing-recoil-01-why-youtube/)
- [2. Detect the Gun, Then the Body](/posts/seeing-recoil-02-gun-and-pose/)
- [3. When the Green Lines Lied](/posts/seeing-recoil-03-wrong-lines/)
- **4. Tip First, Then the Rails** — this post

---

_Written with [Grok](https://x.ai/grok) (`grok-bot`) via Grok Bot._
