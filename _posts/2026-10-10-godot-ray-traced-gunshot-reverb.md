---
title: "Ray-Traced Gunshot Reverb in Godot, Checked Against Physics"
date: 2026-10-10 07:15:39 -0300
categories: [Game Development, Godot]
tags: [godot, game-development, game-audio, ray-tracing, acoustics, testing, reproducibility, pitfalls]
description: "Rebuilding Bodycam's room-aware gunshot reverb in Godot 4.7 with a ray tracer, a measured reverb, and a physics reference that caught six bugs on the way."
pin: false
math: false
mermaid: false
---

Bodycam's second devlog says its system makes "every detonation physically react to its environment". In a small bathroom "the bass becomes overwhelming", and a big room gives longer tails. Walking outside while firing has "no sudden audio switch". I wanted to rebuild that in Godot 4.7. The reverb itself was the quick part. Proving that it was right was most of the work, and the checks found three bugs in my measuring code and three in the renderer.

![Ray paths in four test spaces. The tiled bathroom is full of short blue paths. The corridor, the concrete hall, and the open yard follow, and in the yard most rays leave as orange lines.](/assets/img/audio-study/ray-views.png)
_The tracer's debug view. Blue paths fade as they lose energy, orange paths escape, green dots are reflection points that become early echoes._

## The setup

I started from the [devlog](https://www.youtube.com/watch?v=Oz66Ek1RYWU) itself. I pulled the transcript with [yt2txt]({% post_url 2026-09-14-yt2txt-youtube-transcripts-for-agents %}) and grabbed frames at the reverb chapter. The narration describes the system from the outside, but two frames show more. At 01:52 there is a grid of vertical debug rays in a corridor. At 02:48 a green fill covers the floor, stops at walls, and flows through doors. So rays were a reasonable starting point.

Then I checked what Godot 4.7.2 can actually do, by asking the engine instead of the docs:

```gdscript
extends SceneTree
func _init():
	print(ClassDB.get_inheriters_from_class("AudioEffect"))
	for m in ClassDB.class_get_method_list("AudioEffectInstance", true):
		print(m.name, " ", m.args.map(func(a): return type_string(a.type)))
	quit()
```

Two answers shaped the whole design. There are 27 audio effects and none is a convolution reverb. And `AudioEffectInstance._process` takes its buffers as raw pointers passed as `int`, so a GDScript class cannot process audio samples. The 4.7 docs agree: only GDExtension can use it.

That gave me a two-layer plan:

- **Rays do the analysis.** A tracer on the Jolt physics scene measures the room per shot.
- **Godot plays the result with parts it already has.** A dry shot, early echoes, a stock reverb set from the ray results, and a recorded outdoor tail.
- **An offline reference keeps it honest.** Python convolves the dry shot with the ray-traced impulse response. That is what full convolution would sound like, and the Godot output must match its decay and level.

### A test range before any effect

I built five spaces from a JSON file:

- a tiled bathroom, 2 × 2 × 2.4 m
- a room with an open window
- a 30 m corridor with a side room
- a 30 × 20 × 8 m concrete hall
- a yard with one brick facade

Godot's Movie Maker mode renders at a fixed 60 fps and writes a WAV next to the frames:

```bash
Godot --path godot --write-movie out/f.png --resolution 1280x720 -- \
  --scenarios=res://scenarios/step1.json --id=hall_gun
```

I captured two scenarios twice, and each pair was bit-identical (maximum sample difference 0.0). That matters more than it sounds: every later change in a capture came from my code, not from run-to-run noise.

The analyzer computes Schroeder energy-decay curves and fits T20, T30 and EDT per band. Before trusting it on game audio, I fed it synthetic noise decays with known RT60 values of 0.3, 1.0 and 2.5 s. It measured all 15 cases within 10 %, the worst at 2.4 %.

Then the baseline. The same dry pistol shot in all five spaces, with Godot's built-in 3D audio:

![Five level curves for the same shot in five spaces, drawn on top of each other. The largest gap between them is 0.00 dB.](/assets/img/audio-study/baseline-identical.png)

Identical. Godot's 3D audio knows distance and direction, nothing about the room. Two more facts came out of the baseline. An impulse at 0.52 m and at 34.3 m arrives at the same time, so there is no propagation delay. And a source directly behind the listener pans exactly like one in front.

## What worked

### A reference tracer, checked against textbook acoustics

The reference tracer sends 4096 rays from the gun. Each bounce removes energy per band (125–500, 500–2000, 2000–8000 Hz) and scatters some of it diffusely. Air absorption follows ISO 9613-1. A sphere around the listener counts the energy that passes through it, in 1 ms bins. That histogram is the echogram.

In the closed rooms, the traced decay matched Eyring's formula within 0.4–5.7 % in every band. The mean free path in the bathroom came out at 1.408 m against a theoretical 4V/S of 1.412 m. One GDScript ray cast on Jolt costs 2.42 µs.

![Bar chart of mid-band RT60 per space for the traced decay, Eyring, Sabine, and the runtime probe. In each room the four bars agree within about 13 percent.](/assets/img/audio-study/rt60-summary.png)

One thing had to change before any of this worked: the materials. Bare-surface absorption from tables (about 0.02 for concrete) predicts a 19 s reverb in the hall and needs about 700 bounces per ray. Real rooms have clutter. I switched to effective values, which put the rooms between 0.9 s (bathroom) and 4.4 s (hall).

### A cheap probe for runtime

The reference takes up to 3.4 s per position. At runtime each shot gets a probe: 128 rays, 4 bounces, about 2 ms. It estimates the mean free path, the absorption, the room volume as (4π/3)·mean(r³), how many rays escape, and an Eyring RT60. Its RT60 landed within 4–10 % of the reference.

A sweep from 64 to 1024 rays was the surprise. More rays cut the spread from about 5 % to 1 %, but the bias did not move. The bathroom stayed at 0.90 of the reference and the corridor at 1.10. A second sweep over bounce count showed why. With the gun near a wall, the first segments are short. The mean free path climbs from 1.14 m at 2 bounces to 1.39 m at 16. In the corridor the mean free path was already right, and the probe probably just sees more concrete than side room. I kept 4 bounces.

### Early echoes for free

For each wall the probe finds, I mirror the gun through it (the image-source method). Two rays then check that both ends can see the reflection point. A positional player plays the dry shot at the image position. Godot's own inverse-distance law gives the right level for the full path, and the panning gives the right arrival direction. The only missing part is the delay, which needs sample accuracy:

```gdscript
## Copy of a 16-bit WAV with `delay_s` of leading silence (sample-exact).
static func delayed(src: AudioStreamWAV, delay_s: float) -> AudioStreamWAV:
	var bytes_per_frame := (2 if src.format == AudioStreamWAV.FORMAT_16_BITS else 1) * (2 if src.stereo else 1)
	var data := PackedByteArray()
	data.resize(int(round(delay_s * src.mix_rate)) * bytes_per_frame)
	data.fill(0)
	data.append_array(src.data)
	var s := AudioStreamWAV.new()
	s.format = src.format
	s.mix_rate = src.mix_rate
	s.stereo = src.stereo
	s.data = data
	return s
```

All echoes start on the same frame as the dry shot. So their timing against the dry shot is exact, even if `play()` itself starts on a mix-block boundary.

### Measuring Godot's reverb instead of guessing

`AudioEffectReverb` does not say how `room_size` and `damping` map to a decay time, so I measured 45 settings with an impulse.

![Godot reverb T20 in the mid and high bands, and output level, for nine room sizes and five damping values.](/assets/img/audio-study/reverb-calibration.png)

Mid-band T20 covers 0.52–8.94 s, which fits every test room. `damping` behaves like reflectivity: at room size 1.0 the high band rings 0.61 s at damping 0 and 4.47 s at damping 1. The docs describe it as "how reflective the imaginary room's walls are", so the name misleads, not the docs. The renderer interpolates the table and picks the setting closest to the probe's RT60.

### The result

I compare each runtime impulse capture with the ray-traced impulse response, both scaled to the same direct-sound energy:

![Left: mid-band decay time per room for the traced reference, the probe target, and the captured Godot output. Right: reflected-to-direct energy per room for the reference and for Godot.](/assets/img/audio-study/runtime-vs-reference.png)

| Space | Late decay, Godot / reference | Reflected vs direct, Godot / reference |
| --- | --- | --- |
| Bathroom | 0.82 / 0.93 s | +9.0 / +8.7 dB |
| Room with window | 0.83 / 0.93 s | +2.6 / +1.0 dB |
| Corridor | 1.95 / 1.70 s | +3.1 / +1.7 dB |
| Hall | 4.51 / 4.61 s | −9.1 / −10.2 dB |

## Where it almost went sideways

### A run that never ended

The first 4096-ray trace ran for over five minutes and printed nothing. `ps` showed two Godot processes under 1 % CPU: idle, not tracing. New `class_name` scripts are unknown to command-line runs until an import rebuilds the class cache. The parse failed, the main scene had no script, and nothing ever called `quit()`. Now a script runs `--headless --import` and `--check-only` on every file before any capture. I proved the check by planting a bad script. It exits 1 with the exact message.

Movie Maker had two of its own surprises. In `--headless` mode it crashes with `ERROR: Parameter "t" is null.` in the dummy renderer, so captures run in a window. And its AVI writer produced an audio header that ffprobe read as `pcm_u8` lasting 2399.9 s for a 3 s file. The PNG writer's WAV was fine.

### The renderer was right, the ruler was wrong

The first comparison said Godot's reverb was 6–8 dB too quiet in every room. A gap that uniform smelled like measurement, and it was. Three bugs, all in my analysis code:

1. **The reference IR had about three times too much reflected energy.** Each band's echogram is relative to that band's share of the direct sound. Its noise must carry the band's share of a unit impulse, not the full energy.
2. **A mono mixdown hid 3 dB.** Godot's reverb is decorrelated left and right. Averaging two uncorrelated channels halves their energy, while the centred direct sound loses nothing. Energy is now summed per channel.
3. **A hall decay of "0.01 s".** When the reverb is 12 dB below the direct sound, a fit from −5 to −25 dB lands on the drop after the direct sound. Decay is now measured from 50 ms.

With the ruler fixed, the gap flipped: Godot was now about 6 dB too loud in three of the four rooms. That one was real. I calibrated the reverb's broadband output, but the target was a mid-band ratio. The reverb's mid-band output is about 7 dB above its broadband output. Per-band calibration brought every room within 1.6 dB.

### My own check failed, and physics settled it

The plan said: walk out of a house while firing every 0.5 s. The reverb level must not change by more than 6 dB between shots. The first run changed by 17 dB. I could have moved the threshold. Instead I ran the 4096-ray reference at all 17 walk positions to see what physics does at a door.

Physics also drops fast there: 7.0 dB between two shots. A per-shot limit depends on walking speed and fire rate, so it was the wrong test. The right test compares the renderer with the traced walk. That test exposed two real problems:

- **The volume estimate exploded at the door.** Rays leaving through the door hit the ground far outside, and their r³ swamped the mean: 120 m³ became 39,915 m³. Rays that escape now add no volume.
- **I counted the door twice.** The diffuse formula already treats escaping rays as absorption, and I then multiplied by (1 − openness) again, so the reverb faded one shot early.

Rather than guess a replacement, I scored six level models against the traced truth on 22 cases. The winner uses the room's own surfaces, scaled by the openness seen from the gun and from the listener. It has 1.7 dB RMS error, against 2.5 dB for the old one.

![Reflected energy along the walk for the ray-traced reference and for the renderer. Both fall about 13 dB between 1.4 m inside and 1.2 m outside the door, then level out.](/assets/img/audio-study/walk-vs-physics.png)

The renderer now follows the traced walk with 1.3 dB RMS error and 3.7 dB at worst. It still turns about 0.3 m early at the door, and its RT60 near the door follows the gun rather than the room. Those go to the next step, propagation.

## Takeaway

Build the reference before the effect. A ray tracer that matched textbook acoustics within 6 % turned "does this sound right?" into numbers. It caught three bugs in my measuring code before I tuned the renderer against them. When a check fails, ask the physics before you move the threshold.

The shots come from [The Free Firearm Sound Library](https://opengameart.org/content/the-free-firearm-sound-library) on OpenGameArt (CC0). Next comes propagation: sound through corridors and doors, occlusion, and the outdoor escape the devlog describes.

---

_Written with [Claude Opus 5.5](https://www.anthropic.com/claude/opus) (`claude-opus-5-5`) via Claude Code._
