---
title: "Bootstrapping this blog, and the skill that writes it"
date: 2026-04-28 16:00:00 -0300
categories: [Tooling, Claude Code]
tags: [claude-code, jekyll, chirpy, skills, blogging, automation, meta]
description: "Setting up a Jekyll Chirpy blog and building a Claude Code skill that converts working sessions into publishable drafts — privacy-first, drafts only."
pin: false
math: false
mermaid: false
---

This is the first post on this blog, and it is a slightly unusual one: it is a write-up of the session that built the blog itself, produced by a Claude Code skill that I built in the same session. Recursive, but the point is practical — I wanted a low-friction way to turn coding sessions into shareable posts without leaking anything I should not be sharing.

## The setup

I cloned the [Chirpy starter](https://github.com/cotes2020/chirpy-starter) into a fresh repo and ended with the typical placeholder state: theme installed, `_config.yml` full of `username` strings, no posts, no avatar. The goal was not just to fill in the blanks — it was to leave the repo in a shape where future posts could be drafted *from working sessions* with as little manual work as possible.

Two distinct pieces of work, in one session:

1. Configure the blog itself — the boring but necessary part.
2. Build a Claude Code skill (`/blog-post`) that converts the current session into a draft post in this same repo.

The second piece is where it gets interesting.

## Configuring Chirpy

The minimal set of `_config.yml` edits you actually need to ship a Chirpy blog:

```yaml
title: Jean Brito
tagline: Notes on software, systems, and side quests
description: >-
  Personal blog of Jean Brito — software engineering, tooling, and experiments.
url: "https://jeanfbrito.github.io"
github:
  username: jeanfbrito
social:
  name: Jean Brito
  email: jean.f.brito@gmail.com
  links:
    - https://github.com/jeanfbrito
timezone: America/Sao_Paulo
avatar: https://github.com/jeanfbrito.png
```

A few things worth flagging:

- **`avatar` accepts a CORS URL.** GitHub serves your profile image at `https://github.com/<user>.png` — no need to commit a binary into `assets/`.
- **Comments off by default.** I overrode the post default in `_config.yml`:

  ```yaml
  defaults:
    - scope: { path: "", type: posts }
      values:
        layout: post
        comments: false
  ```

  Leaving the global `comments.provider` empty is not enough on its own; the per-post default still flips on if you don't override it. Worth knowing if you switch providers later.

- **Repo name vs URL.** This is the tripwire. A user-page repo must be named `<username>.github.io` to publish at the root domain. My repo is currently `jeanfbrito/jeanfbrito`, which means GitHub Pages serves it at `jeanfbrito.github.io/jeanfbrito/` (a project page) rather than the apex. The shipped Chirpy workflow handles both cases automatically via `${{ steps.pages.outputs.base_path }}`, so the site builds either way — but the canonical `url` you put in `_config.yml` and the repo name need to agree, otherwise SEO meta and feed URLs go sideways. I am keeping the simpler choice: rename the repo and run at the apex.

Local preview is the standard Jekyll dance:

```bash
bundle install
bundle exec jekyll s
```

If you want to preview drafts (you will, once the skill below kicks in):

```bash
bundle exec jekyll s --drafts
```

That part took maybe ten minutes. The interesting work was next.

## The meta-skill

I wanted a single command — `/blog-post` — that I could invoke at the end of any working session, and have Claude Code produce a draft article in `_drafts/` of this repo. Three constraints:

1. It must not flood the main context window with raw transcript while it works.
2. It must refuse to leak anything proprietary. I work on closed-source codebases; a careless write-up is worse than no write-up.
3. It must never auto-publish, auto-commit, or auto-push. Drafts only. I review and promote manually.

Rather than design from scratch, I cribbed from three skills I already use:

- **`/commit`** — for the [`context-mode`](https://github.com/jeanfbrito/context-mode) pattern: pipe long output (git diffs, transcript chunks) through `ctx_batch_execute` so the raw text stays indexed in a sandbox, and only your queries pull condensed slices into the main window.
- **`/learn`** — for the way it classifies signal worth preserving (struggle vs discovery vs principle) and where each lives.
- **`/mm-extract`** — for the discipline of distilling one session into multiple small, dense entries rather than a single ramble.

The `/blog-post` skill is the intersection of those three:

- Use `context-mode` like `/commit`.
- Pick narrative material like `/learn`.
- Output one well-shaped artifact like `/mm-extract`, but for a public reader instead of a private knowledge base.

The narrative shape I settled on — adapted from Julia Evans, Simon Willison, and Hillel Wayne, who I read often — is just five beats:

1. **The problem.** One concrete sentence.
2. **The approach.** What I picked, and why.
3. **The key steps.** Real commands, real code, no pseudocode.
4. **The pitfall.** This is the part another engineer pays for. Never skip if there is one.
5. **The takeaway.** One transferable lesson.

If the session has fewer than two of those with substance, the skill bails out and tells me to use `/learn` instead. A thin post is worse than no post.

## Privacy first

The single most important thing about the skill is the redaction pass. Most of what I do in Claude Code touches private code, internal hostnames, customer references, or work tickets. None of that goes on a public blog. The skill enforces this in three layers:

1. **A blocklist baked into the skill.** Paths under specific employer/client roots. Internal Slack/Jira tokens. Coworker names. Anything that smells like a secret.
2. **A redaction log in the post-write report.** Whenever the skill replaces or omits content, it tells me what and where, so I can verify nothing was over-stripped (e.g. a generic command got blocked because a customer name appeared in a flag).
3. **An uncertainty list.** Anything the skill was *unsure* was safe to publish surfaces as a flagged item for me to decide before promoting the draft.

And the most valuable rule of all: **drafts only**. The draft lands in `_drafts/`, which Chirpy ignores during normal builds. Promotion is a single `mv` I run by hand:

```bash
mv _drafts/2026-04-28-<slug>.md _posts/2026-04-28-<slug>.md
```

That manual step is not a UX gap — it is the safety net. AI-summarized work should not auto-publish. Ever.

## Where it almost went sideways

Two pitfalls worth naming, because they generalize:

**The repo-name trap.** I almost set `baseurl: ""` and `url: "https://jeanfbrito.github.io"` while the repo was still named `jeanfbrito`. That would have broken every internal link the moment GitHub Pages started serving from `/jeanfbrito/`. The Chirpy workflow papers over the build path, but the canonical URL in your config and the served path have to agree, or your RSS feed and `og:url` tags lie. Easy to miss because the site *looks* fine in the browser.

**The "let the AI publish it" temptation.** My first sketch of the skill had a final step that ran `git add` + `git commit` + `git push` once the draft passed the privacy check. I deleted it. The whole value of the skill is that it produces *a thing I review*. The moment publishing is automated, the privacy guarantees become "the model didn't catch anything" — which is exactly the failure mode I was trying to avoid.

## Takeaway

Two things worth keeping:

- **Skills can compose.** `/blog-post` is mostly a re-orchestration of patterns from `/commit`, `/learn`, and `/mm-extract`. None of those skills knew about each other when I installed them, but they share a vocabulary (`context-mode`, structured output, classification), and a new skill can just borrow from them. This is closer to Unix pipes than to monolithic agents, and it scales much better.
- **Defaults matter more than features.** "Drafts only", "no auto-publish", "redaction log on every run" are not constraints — they are the entire reason this skill is safe to use on a real working session. A capability without a paranoid default is a footgun.

The skill lives in this same blog repo at [`skills/blog-post/`](https://github.com/jeanfbrito/jeanfbrito/tree/main/skills/blog-post) and is symlinked into `~/.claude/skills/` so Claude Code picks it up. The blog is at [jeanfbrito.github.io](https://jeanfbrito.github.io). The next post will be about something other than this blog, I promise.

---

*Written with [Claude Opus 4.7](https://www.anthropic.com/claude/opus) (`claude-opus-4-7`) via Claude Code.*
