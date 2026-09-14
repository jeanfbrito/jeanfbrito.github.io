---
title: "yt2txt: Giving My Agents Eyes and Ears on YouTube"
date: 2026-09-14 18:28:28 -0300
categories: [AI, Tooling]
tags: [youtube, whisper, whisper-cpp, yt-dlp, ffmpeg, claude-code, agent-skills, cli, apple-silicon]
description: "A small CLI that turns a YouTube URL into a transcript, falls back to local whisper.cpp when captions are missing, and snapshots frames without downloading the video."
pin: false
math: false
mermaid: false
---

I paste a lot of YouTube links into coding agents. Devlogs, conference talks, the one video where someone finally explains the thing the docs skip. Each time, the agent needed a transcript, and each time the same small dance happened: does the video have captions, are they manual or auto, what if there are none. I had a skill that handled the caption half and gave up on the rest. This weekend I turned it into a proper tool, [yt2txt](https://github.com/jeanfbrito/yt2txt), with a local speech-to-text fallback and a sister command that grabs frames at chosen timestamps. This is the story of the decisions, and of the one dependency list that changed my mind halfway through.

## The setup

The starting point was a Python script inside my agent-skills repo. It called `yt-dlp` for metadata, picked a caption track (manual first, then auto, in a language preference order), pulled it as `json3`, and rendered a Markdown file: frontmatter, chapters, and paragraphs of about sixty seconds each, prefixed with `**[mm:ss]**` stamps. That format was good. Agents could index it, search it, and quote timestamps back to me.

The gap was videos without captions. The script printed `no caption tracks available` and stopped. For a tool aimed at agents that is the worst possible outcome, because the agent then guesses at the content from the title.

The requirements I wrote down before touching anything:

- One command, `yt2txt <url>`, that prints the transcript. Agents shell out; they should not need an SDK.
- Captions first, always. Whisper only when there is nothing else, plus a flag to force it when auto-captions are garbage.
- Local transcription on my Mac. No cloud, no API key, audio never leaves the machine.
- Do not hog the machine. I run these while doing other work.
- Same output format regardless of source, so nothing downstream changes.

Before building, I had an agent survey what already existed. The honest summary: nothing maintained does "URL in, transcript out, local fallback" in an agent-friendly way. The closest was a desktop app with a CLI, GUI-first and around a hundred megabytes. The one direct match on GitHub had not been touched since 2024. So a thin wrapper it was.

## What worked

### Picking the speech-to-text backend on numbers, not vibes

My first draft of the plan said mlx-whisper. It is pure pip, runs on Metal through Apple's MLX, and its `whisper-large-v3-turbo` model is the most downloaded MLX Whisper repo on Hugging Face. Then Jean-of-the-future, who has to live with the install, asked the right question: is that the lightest option?

So I pulled the actual numbers instead of trusting the pitch. The PyPI metadata for `mlx-whisper` lists `torch`, `numba`, `scipy` and `numpy` as dependencies. That is roughly a gigabyte of Python packages before the model even downloads, for a tool whose own job is to shell out to `yt-dlp`.

whisper.cpp, on the other hand, is a small C++ binary from Homebrew (`brew install whisper-cpp` gives you `whisper-cli`), memory-maps a quantized model, and uses Metal too. Model sizes from the `ggerganov/whisper.cpp` Hugging Face repo:

| Model | Size |
|---|---|
| `large-v3-turbo` (fp16) | 1625 MB |
| `large-v3-turbo-q8_0` | 874 MB |
| `large-v3-turbo-q5_0` | 574 MB |
| `small-q5_1` | 190 MB |
| `base-q5_1` | 60 MB |

I went with `large-v3-turbo-q5_0` as the default. "Small" is genuinely lighter, but it is noticeably worse on Portuguese and on technical vocabulary, and a bad transcript wastes agent tokens downstream. The Python package ended up depending on `yt-dlp` and nothing else.

### The pipeline

`yt2txt` does this, in order:

1. Check the cache for `<id>-*.md`. Hit means instant output.
2. `yt-dlp -J` for metadata: title, duration, chapters, available caption tracks.
3. If a track exists and `--stt` was not passed: download it as `json3`, parse cues, group into paragraphs that also break at chapter boundaries.
4. Otherwise: `yt-dlp -x --audio-format wav` with `--postprocessor-args "ffmpeg:-ar 16000 -ac 1 -c:a pcm_s16le"`, because `whisper-cli` reads 16 kHz mono 16-bit WAV and nothing else. Then:

```bash
nice -n 10 whisper-cli -m ggml-large-v3-turbo-q5_0.bin -f audio.wav \
  -t 5 -l auto -oj -of out -np
```

The `-oj` flag writes JSON with per-segment offsets in milliseconds and the detected language, which maps straight onto the same cue list the caption path produces. From there both paths share one renderer.

The `nice -n 10` and `-t 5` (half of my ten cores) are the "do not hog the machine" requirement. There is a `--fast` flag that drops both. Measured on an M1 Max with a five-minute talk, download included:

| Mode | Wall time |
|---|---|
| default (`nice`, 5 threads) | 18 s |
| `--fast` (10 threads) | 16 s |

The gap is small because most of the work runs on the GPU. While a transcription was running, `whisper-cli` sat under 10% CPU in `ps`. So the default costs almost nothing in speed and keeps the laptop responsive.

### Frames without downloading the video

Once the transcript existed, the next question was obvious: when the speaker says "as you can see here", what was on screen? I did not want to download a video to find out.

The trick is two tools that already know how to do this. `yt-dlp -g` returns a direct stream URL for a chosen format. `ffmpeg` can seek into an HTTP URL with range requests, so with `-ss` before `-i` it only fetches the bytes around the requested keyframe:

```bash
URL=$(yt-dlp -g -f 'bestvideo[height<=720][ext=mp4]/best[height<=720]' "$VIDEO")
ffmpeg -ss 00:02:30 -i "$URL" -frames:v 1 -q:v 2 frame.jpg
```

The first spike produced a 1280x720 JPEG in 0.7 seconds. Wrapped into `yt2frame`, three frames from one video took 3.5 seconds total, including the one stream lookup. The agent loop I wanted is now real: read the transcript, pick the timestamps that mention something visual, ask for all of them in one call, look at the pictures.

```bash
yt2frame VIDEO_ID 0:45 3:20 4:55 --out ./frames
# FRAME ./frames/VIDEO_ID-000045.jpg t=45 1280x720
# FRAME ./frames/VIDEO_ID-000320.jpg t=200 1280x720
# FRAME ./frames/VIDEO_ID-000455.jpg t=295 1280x720
```

I first built this as a `--frame` flag on `yt2txt`, then split it into a second binary. Same package, one `uv tool install`, two entry points. "`yt2txt` for text, `yt2frame` for pictures" reads better in a skill than a flag does.

### The agent contract

Small things that make a CLI usable by an agent, all of which I got wrong in earlier tools:

- stdout carries only the result. Progress and `FAIL <input> <reason>` lines go to stderr.
- `--save` writes the Markdown to a cache and prints one line: `OK <path> words=N track=en/auto duration=S`. The agent reads the path; the transcript never enters its context unless asked for.
- `--format json` for when it does need to parse.
- Missing tools fail fast with the fix in the message: `whisper-cli not found on PATH (brew install whisper-cpp)`.
- Exit code 1 if any input failed, 0 otherwise.

YouTube's "sign in to confirm you're not a bot" gets one automatic retry with the browser's cookies via `--cookies-from-browser`, off by default because yt-dlp warns that heavy cookie use can get an account rate-limited.

## Where it almost went sideways

**The survey was wrong about a fact I could check.** The research agent reported that mlx-whisper was "not on PyPI directly". It is, at version 0.4.3. I only caught it because I verified backend availability with a `curl` to the PyPI JSON API before choosing. Agents summarizing the web are useful for the map; the specific claims you are about to build on need a primary source.

**The stale install.** After adding `yt2frame` I ran `uv tool install . --force`, ran the live test, and got `unrecognized arguments: --frame`. The tests passed in the project venv, so I stared at the code for a minute before realizing the installed tool was still the old build. uv had reused the cached wheel because the version number had not changed. `--force` replaces the tool entry; it does not rebuild. The fix is `--reinstall --no-cache`, or bumping the version, which I now do on every change. A `yt2txt --help | grep <new-flag>` before any live test would have saved that minute.

**The black frame.** One of the first frames I grabbed came back almost entirely black. I assumed a bug in the seek. It was a fade between two scenes at exactly that timestamp. The tool was right and I was wrong, but the lesson stuck: a frame is a sample of one instant, and instants can be transitions. The skill now tells the agent to nudge the time by a second or two when a frame is black.

**The out-of-range timestamp.** Asking for a frame at 59:00 in a five-minute video produced a wall of ffmpeg stderr about tasks finishing with `Invalid argument`. Correct failure, useless message. Matching on `received no packets` and `Nothing was written` turns it into `no frame at 3540s (past the end of the video?)`, which is what an agent can act on.

## Making the skill portable

The skill that drives all of this started life Claude Code specific. It named a context-mode indexing tool, a "haiku watcher" subagent, and a memory store. Codex and Grok Build both load skills in the same SKILL.md format from their own directories, so the last step was making the text host-neutral: describe the search index, the subagents and the memory as optional with plain-shell fallbacks, and have `install.sh` symlink the skill folder into `~/.claude/skills`, `~/.codex/skills` and `~/.grok/skills`, whichever exist. One repo, one installer, three agents.

## Takeaway

When a tool's job is to wrap other tools, read the `requires_dist` on PyPI before choosing a Python wrapper; a C++ binary behind `subprocess` often keeps your own package dependency-free and gives you `nice` and thread limits for free. And when an agent hands you a survey, treat it as a map, then verify the two or three facts your design actually rests on with a direct query.

The repo is at [github.com/jeanfbrito/yt2txt](https://github.com/jeanfbrito/yt2txt). Clone it, run `./install.sh`, paste a link.

---

_Written with [Claude Fable 5.1](https://www.anthropic.com/claude/fable) (`claude-fable-5-1`) via Claude Code._
