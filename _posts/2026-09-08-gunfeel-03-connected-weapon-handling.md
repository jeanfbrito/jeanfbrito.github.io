---
title: "Building Gunfeel 3: Weight Lives in the Transitions"
date: 2026-09-08 13:02:00 -0300
categories: [Game Development, Godot]
tags: [godot, animation, aiming, locomotion, testing, game-development]
description: "Aiming, sprinting, crouching, and reloading looked better once I tested the transitions between them and kept the weapon, view, and supporting hands connected."
pin: false
math: false
mermaid: false
series: Building Gunfeel
series_order: 3
---

A sprint pose can look convincing in a still image and still feel wrong the moment the player tries to fire. A reload can look connected while standing still and lose that connection during an ordinary jog. I kept finding the same pattern: the individual action was only part of the work. The transition into the next action was where the weight either remained believable or disappeared.

[The recoil investigation]({% post_url 2026-09-08-gunfeel-02-recoil-needs-support %}) had already made support a useful way to describe the problem in **Shoot to Thrill**. This post follows that idea through aiming, sprinting, stance changes, and reloads. The implementation remains private; the transferable part is how the experiments changed what I chose to inspect.

## Aiming starts before the sights line up

My preferred interaction is toggle aim: press once to aim, press again to leave that state. It sounds like a small input preference, but it exposed a broader distinction between what the player intends and what the button is doing right now.

Once aiming is latched, the button can be up while the player still intends to aim. Any movement behavior that only looks at the current button state can disagree with the weapon presentation. The important observable contract is that movement and presentation respond to the same intended action, including after the initial press has ended.

There was also a visual problem at the beginning of the transition. An aiming motion can finish in the correct sight picture while briefly traveling the wrong way at its onset. If I only checked the final pose, I would miss the most noticeable part of entering aim.

The useful question became whether the first visible movement carried the weapon toward the intended view. Changing transition speed was not enough when the direction itself was wrong. That distinction saved the investigation from treating every aiming complaint as a timing preference.

## A moving body changes the comparison

Standing still is a good place to make an action repeatable. It is also an easy place to stop testing too early. The player can turn, translate, change stance, and interrupt an action while the weapon is still moving toward its next posture.

I began comparing transitions under movement rather than assuming the stationary version would generalize. An aiming path needed to remain connected while the player turned. A carry pose needed to resolve into a usable firing posture after the player left a sprint. The relevant observation was the whole route, including the first and last visible frames.

That also changed how I interpreted reference footage. [Project Killhouse](https://www.devunallocated.com/projects/project-killhouse) was useful for observing handling continuity, but I needed to match the action I was actually testing. A sprint clip was not automatically evidence about our ordinary jogging reload. A reference only helped if I kept the comparison specific.

## Sprinting gave the weapon somewhere to go

The prototype needed a distinct two-handed sprint carry. The aim was not simply to move the rifle farther out of the way. It needed to look carried, retain readable support, and have a connected route back to a ready posture.

The first reviewed carry route was an improvement, but it placed too much of the receiver and forearm below the viewport. That was useful feedback because it separated the route from its framing. I could adjust the presentation without pretending the entire idea was wrong or redesigning unrelated motion.

The more interesting cases were the interruptions. What happens when the player aims from a sprint? What happens if they tap fire and release before the weapon is ready? What if they keep holding automatic fire, or start a reload instead? These are different intentions, so the visible response should not treat them as interchangeable.

I wanted readiness to be visible. A shot should occur after the weapon has returned to a usable posture, and a canceled action should not leave an old intention waiting to surprise the player later. The exact implementation is private, but the player-facing requirement is straightforward: the next action should agree with what the weapon appears ready to do.

## Small interruption cases were more useful than a long demo

<video class="embed-video file" controls preload="metadata" playsinline width="1280" height="720" poster="{{ '/assets/img/shoot-to-thrill/prototype-ready.png' | relative_url }}" aria-label="Shoot to Thrill: twenty-second scripted handling sequence">
  <source src="{{ '/assets/img/shoot-to-thrill/handling-sequence.mp4' | relative_url }}" type="video/mp4">
  <a href="{{ '/assets/img/shoot-to-thrill/handling-sequence.mp4' | relative_url }}">Download the twenty-second handling clip</a>.
</video>

_An earlier handling checkpoint, played at its recorded 60 FPS without audio. The sequence brings sprinting into toggle aim, firing, and a tactical reload. It provides a concrete view of those transitions; it is not an after-change recording of the unresolved walking work in part four._

Rendering and animation by Jean Brito. Rifle: [TastyTony, “Low-Poly M4a1”](https://sketchfab.com/3d-models/low-poly-m4a1-8cab1cbeb82c4396a154f9fc8771417b), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Arms adapted from [FPS-animation-POC](https://github.com/rdstrcorpse/FPS-animation-POC), [MIT](/assets/img/shoot-to-thrill/arm-visuals-license.txt).

![Ten scripted handling phases across twenty seconds, with a shot counter rising once during the semi tap and then to fourteen during held auto.](/assets/img/shoot-to-thrill/handling-timeline.png)
_Recorded input-phase labels and cumulative shots from the same take. The bars describe what the script requests. They do not independently prove that an animation has finished or that the weapon is ready. The horizontal axis uses the fixture's frame clock; it is not a claim of exact alignment with encoded video frames._

The timeline gives the clip a reading order. First watch how the rifle leaves the sprint posture; then return to the same sequence and watch the support hand. The cumulative count also makes the single tap and the sustained burst easy to distinguish without inferring shots from the size of the animation. [Download the plotted measurements](/assets/img/shoot-to-thrill/measurements.json).

A long demonstration can make a feature feel complete because it contains many actions. It may still avoid the particular boundary where two actions disagree. I found short, deliberate sequences more useful for that stage of the work.

| Sequence | Question it answered |
|---|---|
| Sprint into aiming | Does the carry return connect to the aiming motion? |
| Sprint, tap fire, release | Is a brief firing intention handled predictably during recovery? |
| Sprint into held fire | Does visible readiness precede sustained firing? |
| Sprint into reload | Does the new action cancel incompatible pending behavior? |
| Sprint, then stop | Does the weapon settle with the player? |

The point was not to collect a large list of passing checks. Each sequence represented an intention a player could express. If the weapon's visible response contradicted that intention, the test had found something more important than a missing decorative movement.

Once a sequence worked mechanically, I still needed to review the recording. A system can satisfy an ordering rule and still make the transition feel disconnected. Mechanical checks told me whether the intended events happened in the right relationship; the rendered take told me how that relationship read.

## Crouching exposed a relative-motion problem

The crouch and stand transitions produced another useful surprise. The body movement had already been eased, but the camera's response added another delay. The rifle and the eye therefore disagreed during the change in stance, creating a visible plunge or heave in the first-person view.

The problem was not that crouching needed more elaborate animation. It was that two related parts of the presentation were responding differently to the same movement. Treating the relative motion as the thing to measure made the correction much more focused.

This is a recurring lesson in first-person work. A world-space path can look reasonable in isolation and still produce an awkward view when combined with the camera. I needed to judge the change from the player's perspective and keep the already-reviewed secondary motion in scope, rather than flattening every movement to make one trace look cleaner.

## Reloading turned a movement test into a reach test

The sprint work exposed a reload issue that also existed during ordinary jogging. That mattered for diagnosis: the new sprint sequence made the problem visible, but it did not establish that sprinting caused it. Reproducing the same behavior outside the new action kept the explanation accurate.

The visible symptom involved the supporting hand's relationship to the weapon. Looking more closely showed that some requested hand positions were beyond the available reach of that presentation. Asking a solver to work harder could not make an unreachable target reachable without changing something else.

The resulting correction preserved the relationship between the rifle and its actual handling targets. I did not want a hand to look attached only because a test tolerance had become more forgiving. Nor did I want a fix for one weapon presentation to alter another presentation that did not show the same issue.

The useful public lesson is about responsibility. When contact looks wrong, inspect both the target and the thing trying to reach it. A poor result can come from the solver, the requested position, or the way the surrounding motion moves that position over time. Those causes call for different experiments.

## What this checkpoint established

Focused reload, moving-reload, and sprint checks recorded 241 passing assertions across two weapon presentations. Guarded rendered comparisons also supported the bounded sprint, stance, and reload improvements described here. Those results apply to the actions and source state that were reviewed; they are not a blanket acceptance of later animation changes.

That limit became especially important when walking received more attention. A change to the lower body can alter the context in which the upper body was judged. I could keep the earlier improvement as evidence of progress while still requiring another review after the supporting motion changed.

The takeaway is that weight persists through transitions when the player, view, weapon, and support continue to agree. A convincing resting pose is a useful starting point. The real test is what happens when the player changes their mind halfway through the next action.

## Continue the series

- [1. Learning to See Weight]({% post_url 2026-09-08-gunfeel-01-learning-to-see %})
- [2. Recoil Needs a Shoulder]({% post_url 2026-09-08-gunfeel-02-recoil-needs-support %})
- **3. The Transitions Carry the Weight** — this post
- [4. Why Passing Feet Still Look Wrong]({% post_url 2026-09-08-gunfeel-04-walking-contact-evidence %})
- [5. Testing Without Taking My Mouse]({% post_url 2026-09-08-gunfeel-05-testing-without-interruption %})
- [6. Small Results, Honest Evidence]({% post_url 2026-09-08-gunfeel-06-evidence-outside-context %})

---

_Written with [GPT-6](https://openai.com/) (exact model ID unavailable) via Codex._
