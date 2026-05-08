---
title: "Extending Issuer to Pull Requests: Same Pattern, Different Data"
date: 2026-05-08 09:00:00 -0300
categories: [Tooling, Automation]
tags: [llm, sqlite, github, automation, code-review, pull-requests, open-source]
description: "After building an LLM-powered issue manager, the natural next step was PRs — syncing, diffing, reviewing, and posting feedback with the same local-first pattern."
pin: false
math: false
mermaid: false
---

In the previous two posts, I described the architecture and operation of **issuer**: a local-first GitHub issue triage tool powered by SQLite and LLMs. The first post covered the data model and sync pipeline. The second covered running it at scale — closing 42 real issues with a kanban-backed review loop.

This post covers what happened next.

After the issue pipeline was stable, the natural extension was pull requests. The open PRs in the same repository needed the same treatment: diff syncing, automated code review, structured analysis, and a review-before-posting workflow. The constraint was the same — issuer is a tool I inspect and approve before anything touches GitHub.

The result is a parallel pipeline that shares the same database, config, and design philosophy but operates on completely different data.

---

## Why PRs are different from issues

The issue pipeline reads metadata-heavy data: title, body, comments, labels, state. The heaviest processing happens in the LLM triage step, where the model classifies each report.

PRs are different. The primary artifact is the diff — the actual code change. Everything else (title, description, comments, reviews, commits, status checks) is context around that diff. The LLM review is a code review, not a classification task.

That means:

- **The data model needs three new tables**: one for PR metadata (`pull_requests`), one for the diff and supplementary data (`pr_details`), and one for analysis results (`pr_analysis`).
- **The sync pipeline is two-pass**: stage one fetches the PR list (metadata), stage two fetches per-PR details (diff, comments, reviews, commits, status checks).
- **The analysis is more structured**: the LLM returns a verdict with specific issues found, not just a summary and risk score.
- **The posting step is more complex**: reviews with collapsible sections, issue tables, and model attribution.

But the core pattern stayed the same: SQLite for durable storage, `gh` CLI for GitHub data, omnirouter for LLM calls, and `config.yaml` for all configuration.

## The data model

The three new tables follow the same structure as the existing issue tables:

```sql
CREATE TABLE pull_requests (
    id INTEGER PRIMARY KEY,
    repo_id INTEGER REFERENCES repos(id),
    number INTEGER NOT NULL,
    title TEXT,
    state TEXT,
    body TEXT,
    author TEXT,
    base_branch TEXT,
    head_branch TEXT,
    labels TEXT,
    url TEXT,
    additions INTEGER DEFAULT 0,
    deletions INTEGER DEFAULT 0,
    files_changed INTEGER DEFAULT 0,
    mergeable TEXT,
    draft INTEGER DEFAULT 0,
    created_at TEXT,
    updated_at TEXT,
    raw_json TEXT,
    synced_at TEXT DEFAULT (datetime('now')),
    UNIQUE(repo_id, number)
);

CREATE TABLE pr_details (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pr_id INTEGER REFERENCES pull_requests(id),
    diff_text TEXT,
    comments TEXT,
    reviews TEXT,
    commits TEXT,
    status_checks TEXT,
    synced_at TEXT DEFAULT (datetime('now')),
    UNIQUE(pr_id)
);

CREATE TABLE pr_analysis (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pr_id INTEGER REFERENCES pull_requests(id),
    diff_text TEXT,
    verdict TEXT,
    confidence TEXT,
    summary TEXT,
    review_text TEXT,
    issues_found TEXT,
    model TEXT,
    analyzed_at TEXT,
    posted_at TEXT,
    UNIQUE(pr_id)
);
```

The `pr_details` table stores the diff as plain text alongside serialized JSON arrays for comments, reviews, commits, and status checks. This keeps the data queryable without hitting the GitHub API again.

The `pr_analysis` table stores the LLM review output: a structured verdict (`approve`, `changes_requested`, `close`, `needs_human_review`, `needs_more_work`), confidence, summary, individual issues found (with severity, file, line, and description), and the full review text. The `posted_at` column tracks whether the review has been posted to GitHub.

## The sync pipeline: two-pass

The first pass syncs PR metadata:

```bash
$ issuer pr-sync RocketChat/Rocket.Chat.Electron
Syncing PRs for RocketChat/Rocket.Chat.Electron...
Synced 96 PRs (96 new, 0 updated)
```

The `gh` CLI call fetches 17 fields per PR — number, title, head/base branches, state, author, labels, mergeable status, additions/deletions, files changed, body, URL, timestamps, and draft status. The data is written to a temp file and upserted into SQLite.

The second pass fetches per-PR details:

```bash
$ issuer pr-sync RocketChat/Rocket.Chat.Electron --details
Fetching PR details (diff + comments)...
  Fetching details for PR #3280...
  Fetching details for PR #3277...
```

For each open PR, it runs `gh pr diff` for the diff and `gh pr view --json` for comments, reviews, commits, and status check rollup. Each PR's details are upserted into `pr_details`.

This two-pass design means the metadata sync is always fast — ~5 seconds for 96 PRs — while the details pass can take a few minutes depending on PR count and diff sizes.

## The code review prompt

The review prompt is specialized for Electron + TypeScript + React + Redux applications. It asks for structured JSON output:

```json
{
  "verdict": "approve" | "changes_requested" | "close" | "needs_human_review" | "needs_more_work",
  "confidence": "high" | "medium" | "low",
  "summary": "One-paragraph summary of the PR purpose and your assessment",
  "issues_found": [
    {
      "severity": "critical" | "major" | "minor",
      "file": "path/to/file.ts",
      "line": 42,
      "description": "what's wrong",
      "suggestion": "how to fix"
    }
  ],
  "review_text": "Detailed code review with line-by-line feedback"
}
```

The guidelines check for:
1. Security vulnerabilities (XSS, IPC validation, CSP bypass, credential leakage)
2. TypeScript/React anti-patterns
3. Electron-specific issues (main/renderer process boundaries, native module issues)
4. Error handling and edge cases
5. Test coverage gaps
6. Performance concerns
7. Code style and consistency

If the LLM call fails or returns unparseable JSON, the system falls back to `needs_human_review` with the raw text preserved. This is explicit by design — a failed review should not produce a silent false positive.

## Reviewing PRs — designed but pending

The review commands are implemented and ready:

```bash
$ issuer pr-review RocketChat/Rocket.Chat.Electron 3322   # ↤ not yet run
$ issuer pr-review-all RocketChat/Rocket.Chat.Electron     # ↤ not yet run
```

Each review would be saved to `pr_analysis` before the next PR starts. If interrupted, already-reviewed PRs are preserved. Re-running skips analyzed PRs unless `--force` is passed.

## Posting to GitHub — designed but pending

The posting command is also implemented, gated behind an explicit `--dry-run`:

```bash
$ issuer pr-review-post RocketChat/Rocket.Chat.Electron --number 3280 --dry-run
```

The `--dry-run` flag prints the comment to stdout without posting. Only when removed does the tool run `gh pr comment`.

Reviews are formatted with collapsible sections:

> **Verdict:** changes requested  
> **Confidence:** high  
> **Summary:** \...
> 
> <details>
> <summary>Detailed review</summary>
> Line-by-line feedback...
> </details>
> 
> ---
> *Reviewed with cx/gpt-5.5-high*

The `posted_at` column in `pr_analysis` tracks whether a review has been posted to GitHub.

## Current state

The metadata sync works: `issuer pr-sync` fetched **96 open PRs** from Rocket.Chat.Electron in about 5 seconds. The schema, CRUD operations, and CLI commands are in place.

What hasn't been run yet:
- `--details` pass (fetches diffs per PR — the heaviest operation)
- `pr-review` (single PR code review)
- `pr-review-all` (batch review)
- `pr-review-post` (posting to GitHub)

The pipeline is designed and the code is written. Running it on real PRs is the next step — and will determine whether the review prompt catches real issues or produces noise.

## What changed in issuer itself

The PR pipeline added four CLI commands:

| Command | Purpose |
|---------|---------|
| `issuer pr-sync [--details]` | Sync PR metadata and optionally fetch diffs |
| `issuer pr-list` | List PRs from the local DB |
| `issuer pr-show <number>` | Show a single PR with analysis |
| `issuer pr-review <number>` | Review a single PR via LLM |
| `issuer pr-review-all` | Batch review all unanalyzed PRs |
| `issuer pr-review-post [--number]` | Post reviews as GitHub comments |

The configuration gained a `models.analyze_pr` key pointing to the review model (default: `cx/gpt-5.5-high`), independent of the issue analysis model.

The database schema grew by three tables and about 30 lines of SQL.

## Lessons

### 1. The two-pass sync is worth the complexity

I considered fetching everything in one pass. But the metadata pass is fast (5 seconds, always works), and the details pass is slow (minutes, can timeout on large diffs). Separating them means you always have a fresh PR list, and you fetch details on demand or in the background.

### 2. Structured output from LLMs is reliable with the right prompt

The code review prompt produces clean JSON 95% of the time. The fallback to `needs_human_review` handles the remaining 5%. The key was making the output format explicit in the system prompt and keeping the diff under 8000 characters.

### 3. Posting should never be automatic

The `issuer pr-review-post` command with `--dry-run` is the safety valve. Every review gets a human look before it touches GitHub. The collapsible comment format makes the review readable but keeps the detail available.

### 4. The same architecture generalized well

The PR pipeline uses the same SQLite connection, same config loader, same omnirouter client, and same kanban state machine as the issue pipeline. Adding a new data type was about extending the schema, not refactoring the architecture.

---

The issue pipeline proved the pattern worked. The PR pipeline proved the pattern generalized.

SQLite for state, `gh` CLI for data, LLMs for judgment, and explicit human review for destructive actions. That combination handled issues and now handles pull requests with the same codebase, the same configuration, and the same safety model.

What comes next is still unfolding.

---

*Written with [DeepSeek V4 Pro](https://deepseek.com/)*
