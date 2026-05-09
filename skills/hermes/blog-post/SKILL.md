---
name: blog-post
description: Convert a session, experiment, or benchmark into a publishable engineering blog post draft for jeanfbrito.github.io (Jekyll Chirpy). Trigger when the user says "blog this", "turn this into a post", "write this up for the blog", or asks to document something as a blog article. Produces a draft saved into the blog repo's _drafts/ directory so the user can review before publishing. Strips private/proprietary content, keeps reusable code, commands, and lessons.
---

# /blog-post — Session Knowledge → Blog Draft

Trigger: "blog this", "turn this into a post", "write up for blog", "escreve um blog post sobre..."

When invoked, distill the session or topic into a publishable draft for the user's Jekyll Chirpy blog at `https://jeanfbrito.github.io`. Output goes to `_drafts/` in the blog repo so the user reviews and publishes manually. **Never auto-publish. Never auto-commit. Never push.**

The blog repo lives at: `/home/jean/projects/jeanfbrito.github.io`

## Hard rules — privacy

The user works at Rocket.Chat and on closed-source/client projects. Treat every transcript as potentially leaky. **A draft that leaks anything proprietary is worse than no draft.**

**NEVER include in the draft:**

- API keys, tokens, passwords, secrets, env values, signed URLs
- Internal hostnames, IPs, internal repo URLs, JIRA ticket IDs, Slack channels, customer/employer/client names beyond Rocket.Chat-public-OSS work
- Code from private repos (Rocket.Chat private monorepo packages, client codebases). OSS Rocket.Chat OK if already public on GitHub.
- File paths that reveal employer or client (e.g. anything under employer-specific directories)
- Proprietary algorithms, internal architecture, schemas
- Real names of coworkers, customers, or third parties (Jean Brito as author = OK)
- Stack traces or logs that reveal internal infrastructure

**Always allow:**

- Public GitHub repo names, commit SHAs, PR/issue numbers for public repos
- Commands, config examples (redacted), terminal output
- General technical approaches, patterns, architecture decisions
- Personal lessons, opinions, and engineering judgments (those are why people read blogs)

## Multi-post planning

For rich sessions, generate 2+ interconnected posts. Evaluate whether the session naturally splits before writing:

- Look for clear break points (e.g. architecture vs operation, build vs test, problem vs solution)
- Generate sequentially so Post 1 can reference Post 2 as "next time"
- Each post should stand alone (someone landing on Post 2 first should be able to follow it)
- Front matter `description` on Post 2 can signal "sequel to the (Post 1)" pattern

## Drafting workflow

1. **Scan the session** for the key narrative: what problem → what solution → how it works → what happened → lessons learned
2. **Split across posts** if the material naturally divides (architecture vs scale, build vs deploy, theory vs practice)
3. **Check the date first** — run `date` before writing front matter. Timezone is -03 (BRT). Never guess.
4. **Generate drafts** via LLM call to an appropriate model — pass structured prompt with the session's technical narrative, architecture highlights, and concrete data
5. **Review against the editor's checklist** below before saving
6. **Save to `_drafts/`** with filename `YYYY-MM-DD-slug.md` (date MUST match today's system date)
7. **Report back** with the filenames, word counts, and a summary of each post's content

## Drafting — editor's checklist (before saving)

Before finalizing the draft, run through this checklist. If any check fails, regenerate the offending section:

- [ ] No internal hostnames, IPs, JIRA tickets, credential values
- [ ] No employer or client names unless they are public and relevant
- [ ] No real API keys, tokens, signed URLs, or env variable values
- [ ] Language and tone are compatible with the user's public engineering voice
- [ ] Code blocks are formatted, commands are runnable, configs are redacted
- [ ] **Numbers are accurate and real** — the user values truth over narrative drama. If they did 400+ manual closures before building the tool, say that. Don't compress the timeline for a better story.
- [ ] **Only cover what is DONE** — the user corrects hard when future/planned work is presented as present reality. If something is not yet shipped or running, either frame it explicitly as "next" or leave it for a future post.
- [ ] **Tech choices framed as strengths, not apologies** — "SQLite is a real, production-grade database" not "SQLite over a 'real' database". Don't compare down; state the choice confidently.
- [ ] **Framing: tool sits on top of existing infrastructure** — e.g. "GitHub already is the tracker, issuer automates the parts GitHub's UI does poorly" not "why not use X instead".

## Front matter template (Jekyll Chirpy)

```yaml
---
title: "Post Title Here"
date: YYYY-MM-DD HH:MM:SS -0300
categories: [Category1, Category2]
tags: [tag1, tag2, tag3, ...]
description: "One-sentence hook that appears in cards and meta."
pin: false
math: false
mermaid: false
---
```

## Pitfalls

- The user's blog is a serious engineering publication, not a diary. Every sentence should carry weight. Cut fluff, cut fanfare, cut self-deprecation.
- Don't name-drop LLM provider/model names unless they are the point. The tool is the point.
- Never write "in this post we'll explore" — just write the thing.
- When the user says "review this" they want specific line edits applied, not just a summary of issues found. Apply the corrections.
- User dislikes "why not X" framing. Present choices as "why X" instead.
- The Jekyll server may already be running from a previous preview session. Check port 4001 before starting a new one. Don't kill-and-restart unless user asks.
- **Footer model attribution format:** end every post with `---` then `*Written with [Model Name](https://openai.com/codex/)*`. Use the public model name (e.g. `GPT-5.5 High`), never the internal omnirouter tag (`gom/gpt-5.5-high`). Check published posts for exact format before saving.