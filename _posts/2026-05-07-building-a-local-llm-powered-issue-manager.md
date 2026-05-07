---
title: "issuer: A Local SQLite-Backed GitHub Issue Manager Powered by LLMs"
date: 2026-05-07 09:00:00 -0300
categories: [Tooling, Automation]
tags: [sqlite, llm, github, python, kanban, issue-tracking, developer-tools]
description: "issuer is a local Python CLI that uses SQLite and LLMs to triage GitHub issues — sync, analyze, review, close."
pin: false
math: false
mermaid: false
---

# issuer: A Local SQLite-Backed GitHub Issue Manager Powered by LLMs

I maintain an open-source Electron desktop app. Over time, the issue tracker accumulated reports from different operating systems, packaging formats, hardware configurations, and workflows I had never tested myself. Some were real bugs. Some were duplicates. Some were feature requests disguised as bugs. Some were "it doesn't work" with no logs. Some were already fixed. Some were upstream Electron issues.

Manual triage does not scale. Reading each report, categorizing it, checking for duplicates, verifying if it is still actionable — that process does not get faster the more issues you have. It gets slower.

I needed something that worked differently: sync the backlog locally, use LLMs to summarize and classify each issue, track review state explicitly, and generate closure messages when it was time to clean up. Not an autonomous agent that closes everything on its own. A tool I could inspect and approve before anything touched GitHub.

So I built **issuer**: a Python CLI tool that syncs GitHub issues into SQLite, uses LLMs to analyze and summarize them, tracks review state with a tiny kanban state machine, and generates closure messages when it is time to clean up the backlog.

## The shape of the problem

Issue triage is not just sorting strings.

For my app, a typical issue might include:

- the original issue body
- several comments from the reporter
- comments from other affected users
- maintainer replies from months ago
- labels that may or may not be accurate
- screenshots, logs, stack traces, and OS versions
- references to pull requests or releases

The question I actually need answered is not “does this issue contain the word `crash`?” It is closer to:

> Is this still actionable, and what should I do next?

That requires semantic judgment. A packaging bug, an Electron regression, a duplicate feature request, and a stale support thread can all use the same vocabulary. Regex rules are good for routing known, repeated patterns. They are bad at understanding messy human reports.

That made issuer a good fit for LLMs — but not as an autonomous agent that mutates everything on its own. I wanted a boring, inspectable pipeline where the model produces analysis, SQLite stores it, and I decide what to do.

## Why SQLite

The first architectural decision was the easiest: issuer uses SQLite.

SQLite is a real, production-grade database. It is not a toy or a "lite" version of something else. It is the most deployed database engine in the world, and for single-developer tooling it is hard to beat:

- **Zero setup**: no daemon, no Docker Compose, no credentials.
- **Portable**: copy the file, back it up, commit schema migrations, move machines.
- **Queryable**: use standard SQL, `sqlite3`, Datasette, DB Browser, or ad hoc scripts.
- **Durable**: transactions are real, crashes are fine, partial work is recoverable.
- **Local-first**: the whole backlog is available without hitting the GitHub API every time.

issuer’s database stores normalized-ish snapshots of GitHub issues, comments, labels, LLM analyses, review states, and generated closure messages. It is not trying to be an enterprise data warehouse. It is a local working set.

A simplified version looks like this:

```sql
create table issues (
  id integer primary key,
  github_number integer not null unique,
  title text not null,
  body text,
  state text not null,
  url text not null,
  created_at text,
  updated_at text,
  synced_at text not null
);

create table issue_analysis (
  issue_number integer primary key,
  category text,
  severity text,
  confidence real,
  summary text,
  recommended_action text,
  raw_json text not null,
  model text not null,
  analyzed_at text not null
);

create table board (
  issue_number integer primary key,
  column text not null,
  reviewed_at text,
  closed_at text
);
```

The schema has changed as the tool evolved, but the philosophy has not: store enough data to make decisions repeatable, and keep the database simple enough that I can understand it with `select * from issue_analysis limit 5`.

## LLMs instead of keyword rules

issuer uses LLMs where they are strongest: reading unstructured text and producing structured judgment.

The key insight was that not every task needs the same model. I split work across different models based on cost, latency, and required reasoning depth.

### GLM-4.7-Flash for new-issue screening

Most issues do not need a premium model. For initial triage, issuer uses **GLM-4.7-Flash** because it is cheap and fast.

The screening prompt asks for structured JSON:

- short summary
- category
- likely root cause
- whether the issue is actionable
- missing information
- suggested labels
- confidence
- recommended next step

This is the high-volume path. When I sync a batch of issues, I want quick first-pass analysis for everything. If the model says an issue is probably a duplicate, stale support request, packaging problem, or reproducible crash, that is already useful.

The output is not treated as truth. It is treated as a draft triage note.

### GPT-5.5-High for deeper analysis and reporting

Not every issue needs the same level of scrutiny. For the high-volume first pass, GLM-4.7-Flash is enough. But when it is time to do something with the results — generate a close report, categorize a batch, or produce a professional analysis — a stronger model is worth it.

issuer uses **GPT-5.5-High** for tasks that require judgment, not just classification. It analyzes dozens of issue comments, closure messages, and labels in context, then produces structured outputs like categorized reports, maintenance recommendations, and executive summaries.

Think of it as the review layer. GLM-4.7-Flash screens the inbox. GPT-5.5-High helps you understand what the inbox actually means.

### Kimi K2.6 for closure messages

Closing old issues is emotionally harder than opening new ones. You want to be clear, kind, and concise. You do not want to sound like a robot. You also do not want to spend three minutes composing each “closing because this appears stale / fixed / duplicate” message across 100 issues.

issuer uses **Kimi K2.6** for closure message generation. It takes the issue context, the triage verdict, and the intended closure reason, then drafts a human-readable response.

For example:

> Thanks for the report. Based on the discussion here, this appears to be the same packaging issue fixed in v1.8.3. I’m going to close this to keep the tracker focused, but please open a new issue with updated logs if you can still reproduce it on the latest release.

Again, issuer does not need the message to be magical. It needs it to be a good first draft that I can approve or edit.

## Kanban as a state machine

The most important UI in issuer is not visual. It is a tiny kanban board represented by SQLite rows.

Every issue moves through three states:

1. **triage** — analysis has been generated
2. **ready** — I reviewed the analysis and approved the intended action
3. **done** — issuer closed or updated the issue on GitHub

That is it.

This sounds almost too small, but it solves the real operational problem: interruption.

Backlog cleanup happens between other work. I might triage 30 issues, get pulled into a release, come back two days later, review 10, close 5, then stop again. I need the tool to survive reboots, API failures, rate limits, model timeouts, and my own context switching.

With the kanban state stored in SQLite, issuer is naturally resumable. If a script crashes halfway through closure generation, completed rows stay completed. If GitHub returns an error, the issue remains in `ready` until the next run. If I want to audit what happened, I can query the database.

The board is not a project management metaphor. It is a durable state machine.

## Separate scripts, not a monolith

issuer is intentionally not a single magical command that does everything.

Instead, it is a collection of small scripts, each with one job:

```bash
issuer sync              # pull issues from GitHub
issuer monitor           # analyze new issues and triage
issuer list --pending    # review pending recommendations
issuer analysis --report # summarize what's in the backlog
issuer export --json     # dump data for offline processing
```

`sync` talks to GitHub and updates local tables.

`monitor` runs the triage pipeline — finds issues without analysis, calls the screening model, validates the structured JSON output, and stores the result. This is the command that runs on a cron loop to catch new issues.

`list --pending` gives me a terminal overview of recommendations I haven't reviewed yet.

`analysis --report` summarizes the current state — categories, trends, anything I need to know before deciding what to do next.

`export` dumps issue data as JSON for one-off scripts, reports, or external tools.

This separation keeps the system understandable. I can run only the sync step. I can re-run analysis for a subset of issues. I can inspect results before anything touches GitHub. I can add a new model or prompt without changing the sync code.

The result feels less like an “AI agent” and more like a set of sharp tools.

## Lessons learned

A few things became clear after using issuer on the backlog.

First, **LLMs are much more useful when their outputs are stored**. A chat window is ephemeral. A JSON analysis row in SQLite is durable, searchable, comparable, and reviewable.

Second, **human approval is not a weakness**. For maintenance workflows, I do not want full autonomy. I want compression. If issuer can turn a messy 40-comment thread into a five-line recommendation, it has already saved me time.

Third, **cheap models are good enough for most first passes**. Expensive reasoning should be reserved for places where it changes the decision quality.

Fourth, **state matters more than interface**. A beautiful dashboard would not help if it forgot where I stopped. A simple SQLite-backed state machine did.

Finally, **local tools compound**. Because issuer is just Python and SQLite, I can add one-off queries, scripts, exports, and reports whenever I need them.

## How issuer fits with GitHub

GitHub already is the issue tracker. issuer does not replace it — it sits on top of it, doing the parts that GitHub's web UI does poorly: batch triage, semantic classification, offline review, and closure management.

For a team of ten, a dedicated SaaS tracker might make sense. For a solo maintainer with hundreds of open issues on an existing GitHub repository, adding another platform means more accounts, more sync problems, more notifications, more context switching. What I needed was something that ran locally, worked on top of the data already in GitHub, and cost nothing to operate.

SQLite + LLM + kanban works because each piece does one thing well:

- **SQLite** provides durable local memory — all issue data, analyses, and state in one portable file.
- **LLMs** provide semantic triage — understanding what an issue is actually about, not just matching keywords.
- **Kanban** provides explicit progress and safe resumption — survive reboots, interruptions, and context switches.

Together, they beat a heavier tracker because they match the actual maintenance loop. Sync the world locally. Let models summarize and classify. Review decisions in batches. Push only approved actions back to GitHub.

Local is fast, cheap, and private. No API rate limits on local queries. No loading spinners for SQLite. No data leaves my machine unless I explicitly sync or post.

issuer did not make issue maintenance disappear. It made it tractable.

---

*Written with [GPT-5.5 High](https://openai.com/codex/)*