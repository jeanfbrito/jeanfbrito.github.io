---
title: "issuer × 96 PRs: A Complete LLM-Powered Code Review Pipeline"
date: 2026-05-08 22:00:00 -0300
categories: [Tooling, Automation]
tags: [llm, code-review, deepseek, pull-requests, pipeline, electron, open-source]
description: "How issuer grew from an issue manager into a 96-PR review pipeline — sync, diff analysis, LLM triage, and a web dashboard, all in Python stdlib."
pin: false
math: false
mermaid: false
---

The Rocket.Chat Electron repo has 96 open pull requests. Some are a year old. Some have conflicts. Some touch critical code paths like IPC, native modules, or the build pipeline. All of them need attention.

Rather than triage manually, I built **issuer** into a PR review pipeline. One command. One night. 96 PRs analyzed end-to-end.

This post covers the architecture, the numbers, and the lessons.

## From Issue Manager to PR Pipeline

issuer started as a CLI tool — GitHub issue management from the terminal. SQLite backend, LLM triage, cron-driven. It could sync issues, classify them, and route to Discord.

[extending-issuer-to-pull-requests/?ref=pipeline-post](/posts/extending-issuer-to-pull-requests/) covers the first PR iteration in detail. The summary:

1. **Sync**: Fetch open PRs + diffs from GitHub API
2. **Analyze**: Feed each diff to DeepSeek V4 Pro with a structured prompt
3. **Store**: Verdict, issues, and review text go into SQLite

This initial run hit **96 PRs** and stored the results. Good. But the data sat in SQLite — you'd query via CLI or raw SQL. Not exactly eye-friendly.

## Dashboard: See All 96 at Once

The dashboard was the obvious next step. Python stdlib (`http.server`), Chart.js via CDN, and a single HTML template rendered server-side.

[issuer-pr-dashboard/?ref=pipeline-post](/posts/issuer-pr-dashboard/) covers the full build. The key numbers:

- **16.7 MB** of diff text analyzed
- **96 reviews** stored in `pr_analysis` table
- **1 command to start**: `issuer dashboard --port 5199`

The dashboard gives you a bird's-eye view: stats grid, donut chart, severity bars, filterable table, and a click-to-inspect modal for each PR.

## The Architecture

```
GitHub API ──sync──▶ SQLite (pull_requests + diffs)
                      │
                      ▼ cmd: issuer pr-review
                      │
              DeepSeek V4 Pro ──analyze──▶ pr_analysis table
                      │
                      ▼ cmd: issuer dashboard
                      │
              http.server + Chart.js ──serve──▶ Browser (port 5199)
```

Everything is Python stdlib. No Flask, no Express, no React. The server is 400 lines — one file you can read top to bottom.

### Model Choice

All 96 PRs used `crof/deepseek-v4-pro` via OmniRoute at $0.40 per million tokens. Average diff size was ~175 KB per PR, so the cost per PR was negligible — well under a cent.

The prompt includes:

- Repository context and tech stack
- The full diff
- Instructions for structured JSON output (verdict, issues, confidence, summary)
- A list of known issue categories to flag

### The Verdict Schema

Every PR gets a **verdict**, **confidence level**, **issues list**, and **review text**.

```
Verdict       Count
─────────────────────
approve          35
changes_requested 23
needs_more_work   20
needs_human_review 17
close              1
```

Confidence distribution:

- **approve**: 32 high, 3 medium
- **changes_requested**: 13 high, 8 medium, 2 low
- **needs_more_work**: 8 high, 1 medium, 11 low
- **needs_human_review**: 1 high, 2 medium, 14 low
- **close**: 1 high

The pattern is clear: LLM is confident when it approves or flags for close. When it says `needs_human_review`, confidence drops — an honest model deferring to human judgment.

## Issues Found Across 96 PRs

The LLM flagged **134 issues** (15 critical) across the PRs. Categories included security (hardcoded credentials, loose regex patterns), build config typos, stale CI workflows, and potential runtime errors in native module usage.

## Lessons Learned

### 1. Structured Output Is Non-Negotiable

parse JSON out of LLM responses makes it hard to be consistent. Setting `temperature: 0.01` and demanding "OUTPUT ONLY JSON" in the system prompt helps, but you still get occasional markdown fences. The parser strips ` ```json`, ` ````, and whitespace — defensive but necessary.

### 2. SQLite Works at This Scale

96 PRs, 16.7 MB of diff text, 100+ issues. SQLite handles it effortlessly. No connection pool, no migration scripts, no Docker. A single `issuer.db` file is the entire backend.

### 3. Cost-Benefit of Deep Analysis

DeepSeek V4 Pro at $0.40/M tok is cheap enough to run on every PR. A cheaper model (GLM-4.7 Flash at $0) could handle triage, but the diff analysis needs the reasoning depth. The two-tier approach (cheap triage → expensive analysis) makes sense for **issues**, but for **PRs** where each is a one-shot review, just use the good model.

### 4. The Dashboard Changed How We Use the Data

CLI tools are fine for one-off queries. A visual dashboard — even a barebones one with `http.server` and Chart.js — turns structured data from a database you poke at into a tool you browse. The ability to filter by verdict, search by text, and inspect full reviews in a modal made it actually useful.

## What's Next

The **issue monitor** pipeline is already running: two-tier analysis where GLM-4.7 Flash triages all new issues (batch) and DeepSeek V4 Pro deep-analyzes the real ones. Results go to Discord — nothing is auto-posted to GitHub without human review.

The full stack is open source at [github.com/mortunha/issuer](https://github.com/mortunha/issuer). If you're building similar tooling for your own repos, the patterns here are repo-agnostic — any GitHub repo with open PRs can plug in.

---

*96 PRs processed, 134 issues tagged, 1 dashboard to browse them all. The LLM didn't replace code review — it made it possible to review at scale.*
