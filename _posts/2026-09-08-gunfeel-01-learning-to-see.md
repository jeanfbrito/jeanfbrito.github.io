---
title: "Building Gunfeel 1: Learning to See Weight"
date: 2026-09-08 13:00:00 -0300
categories: [Game Development, Godot]
tags: [godot, gunfeel, animation, prototyping, references, game-development]
description: "Starting a private Godot FPS prototype taught me to turn vague complaints about weight into useful observations, careful comparisons, and smaller experiments."
pin: false
math: false
mermaid: false
series: Building Gunfeel
series_order: 1
---

The rifle moved upward when I fired. It returned toward its starting position. Holding the trigger produced a stream of shots. The basic behavior was there, but my reaction was still: this feels weightless. That complaint became the beginning of a much larger investigation into recoil, walking, weapon handling, and how to tell whether an animation change actually helped.

This is the first post in **Building Gunfeel**, a series about developing **Shoot to Thrill**, my first-person prototype in Godot. The code is still private. I am sharing the observations, experiments, and engineering lessons. The work is ongoing, and some of the most useful results are the ones that showed me what I had not solved.

![Shoot to Thrill's prototype rifle and arm in a gray test room, with a scripted settle label above the scene.](/assets/img/shoot-to-thrill/prototype-ready.png)
_An earlier handling checkpoint in the test room. This still establishes the presentation used in the clips later in the series; movement needs the sequence around it. It does not show the current walking candidate._

Prototype rendering and animation by Jean Brito. Rifle visuals adapted from [“Low-Poly M4a1” by TastyTony](https://sketchfab.com/3d-models/low-poly-m4a1-8cab1cbeb82c4396a154f9fc8771417b), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); arm visuals adapted from [FPS-animation-POC](https://github.com/rdstrcorpse/FPS-animation-POC), [MIT notice](/assets/img/shoot-to-thrill/arm-visuals-license.txt). [Media notes and credits](/assets/img/shoot-to-thrill/CREDITS.txt).

## The project before the investigation

The early task was concrete: make the weapon behave sensibly near an obstacle. A first-person rifle occupies space, and that space has to remain believable as the player approaches a wall. An animation can look fine in the middle of a room and become obviously disconnected from the environment at a doorway.

That gave the prototype an initial focus on boundaries. Where was the weapon pointing? Could the muzzle enter geometry? Did aiming preserve a usable sight picture? These were useful questions because they made individual defects reproducible. Walk toward the same surface, perform the same action, and inspect the same part of the frame.

But satisfying a geometric constraint did not answer the next question: did the object feel like something a person was carrying? A weapon could remain clear of the wall and still float in front of the camera. It could point in the right direction and still respond to firing like a lightweight decoration. Correct placement was one part of the work, not the whole experience.

## Full auto made the weakness easier to see

Adding sustained automatic fire was useful partly because repetition exposed the animation. A single shot gives the viewer relatively little time to notice the return path. A longer burst makes timing, accumulation, repetition, and recovery much easier to compare.

My first complaint was that the recoil looked like a pattern. My next complaint was more specific: the gun pointed upward, but it did not appear to kick back into the shoulder. That second sentence gave the investigation a direction. It named a relationship between objects rather than asking for a larger effect.

The distinction mattered. Increasing visible movement might have made the rifle more active while leaving the missing relationship unchanged. I needed to watch the rifle, the hands, the shoulder area, the view, and the background together. If they told different stories about the same shot, the result would still feel artificial.

## Choosing references for different questions

[Project Killhouse](https://www.devunallocated.com/projects/project-killhouse) became the main visual target. Its published material provides a useful place to study first-person weapon presentation and handling. I was interested in how connected the action looked: movement leading into aiming, a weapon changing carry posture, and a disturbance resolving back into control.

I also used Road to Vostok as a secondary gameplay reference. That did not make every part of its movement a target. After playing it, I did not want to adopt its overall movement feel. A reference can help answer one question while being unconvincing for another. Keeping that distinction explicit prevented the project from inheriting a whole set of preferences by accident.

Real firing footage added another perspective. External views helped with relationships around the upper body. Eye-position footage helped with what changes in the sight picture. Those views complement each other, but they do not measure the same thing. A camera attached to a person also moves, so the visible motion cannot automatically be assigned entirely to the firearm.

I ended up treating the references as a collection of observations with different scopes. A convincing sprint in a game was useful for carry transitions. A firing clip was useful for shot disturbance. Neither automatically answered whether our walking feet were supporting the character properly.

## Turning a reaction into a testable question

The phrase “make it more realistic” was too broad to guide a small edit. It mixed several possible complaints: timing, scale, contact, camera behavior, repetition, and even the quality of the placeholder body. I started translating each reaction into a question that a comparison could answer.

| Initial reaction | More useful question |
|---|---|
| The rifle feels weightless | Which supporting relationship stops being convincing? |
| Recoil looks fake | Is the problem in onset, accumulation, or recovery? |
| Walking looks strange | Are the feet, body, camera, and rifle moving coherently? |
| Aiming feels wrong | Does the transition move toward the sight picture from its first visible frames? |
| The new version looks better | Better during which action, from which view, against which baseline? |

These questions did not make artistic judgment unnecessary. They made it possible to act on that judgment. If the problem was the first few frames of aiming, changing the entire walking rhythm was unlikely to help. If the hands visibly lost their relationship to the weapon, more camera shake would only add another moving part.

A useful experiment also needed a clear stopping point. I wanted to know what observation would support the change, what would reject it, and which questions would remain open afterward. That made a small improvement worth keeping without requiring it to solve every aspect of realism.

## Keeping the scope narrow enough to learn

It would have been easy to keep adding game systems around the prototype. Pickups, doors, inventory, and broader survival mechanics all create visible progress. They also create more reasons for something to look unfinished. I deliberately kept the work centered on gunplay and feel.

The same principle applied to presentation. Polished models can improve a first impression, but I did not want asset work to substitute for movement work. The immediate goal was to understand what the player should perceive during firing, walking, aiming, sprinting, and reloading. Those relationships needed to make sense before a final visual pass could do its job.

This narrowed scope did not make the task small. Each action had transitions into the others, and each transition could expose a problem that the isolated action hid. What it did was keep those discoveries relevant. A problem with the return from sprinting belonged in the investigation; a new interaction system did not.

## Where comparison can mislead

The most tempting shortcut was to treat a reference as a complete specification. A video looks rich in information because every frame contains so much detail. Yet important facts remain unknown: exact input, camera placement, weapon setup, animation blending, and the conditions immediately before the clip.

That uncertainty does not make visual references useless. It changes the claim they can support. I can say a motion relationship looked more convincing in one clip. I cannot recover a universal physical constant just because the clip is sharp. The better the footage, the more carefully I need to separate what I can see from what I am inferring.

The same caution applies to my own prototype. A good screenshot does not prove a good transition. A pleasant short burst does not prove sustained fire. A forward walk does not prove backward or diagonal movement. Each result has a boundary, and writing down that boundary is part of keeping the work honest.

## The lesson that set up the rest of the work

The first useful improvement was in how I described the problem. “Weightless” became a set of relationships I could observe. That gave later work on recoil, carry transitions, foot contact, and automated evidence a common purpose.

The project has not reached the point where I can claim complete realism or exact parity with a reference. What changed was the process: I stopped treating movement as a collection of effects to make larger and started asking which visible relationships each effect needed to preserve. The next post follows the first of those questions into recoil.

## Continue the series

- **1. Learning to See Weight** — this post
- [2. Recoil Needs a Shoulder]({% post_url 2026-09-08-gunfeel-02-recoil-needs-support %})
- [3. The Transitions Carry the Weight]({% post_url 2026-09-08-gunfeel-03-connected-weapon-handling %})
- [4. Why Passing Feet Still Look Wrong]({% post_url 2026-09-08-gunfeel-04-walking-contact-evidence %})
- [5. Testing Without Taking My Mouse]({% post_url 2026-09-08-gunfeel-05-testing-without-interruption %})
- [6. Small Results, Honest Evidence]({% post_url 2026-09-08-gunfeel-06-evidence-outside-context %})

---

_Written with [GPT-6](https://openai.com/) (exact model ID unavailable) via Codex._
