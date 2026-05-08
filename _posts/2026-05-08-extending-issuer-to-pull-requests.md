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

## Reviewing PRs

The review command runs the full pipeline — sync + details + review:

```bash
$ issuer pr-review-all RocketChat/Rocket.Chat.Electron
```

Each PR gets its diff fetched, then analyzed by the LLM. The verdict, confidence, summary, and per-issue findings are saved to `pr_analysis`. If interrupted, already-reviewed PRs are preserved. Re-running skips analyzed PRs unless `--force` is passed.

## Posting to GitHub

The posting command is gated behind an explicit `--dry-run`:

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
> *Reviewed with DeepSeek V4 Pro*

The `posted_at` column in `pr_analysis` tracks whether a review has been posted. Currently all 96 reviews are analyzed but none posted — each needs human verification before touching GitHub.

## Results from the first run

With the pipeline complete, I ran it against **all 96 open PRs** on `RocketChat/Rocket.Chat.Electron`. The model used was `crof/deepseek-v4-pro` — a local 370B-parameter model running on a home server.

Here is what came back:

| Verdict | Count | % |
|---------|-------|---|
| approve | 35 | 36% |
| changes_requested | 23 | 23% |
| needs_more_work | 20 | 20% |
| needs_human_review | 17 | 17% |
| close | 1 | 1% |

**Confidence distribution:** high: 55, medium: 14, low: 27.

More interesting than the aggregate numbers are the **134 specific issues** the model found across these PRs:

| Severity | Count |
|----------|-------|
| critical | 15 |
| major | 46 |
| minor | 72 |
| trivial | 1 |

The critical findings included:
- Hardcoded API keys and tokens in configuration files
- Missing output validation on IPC event handlers (potential RCE vectors)
- Direct `fs` module usage inside Electron renderer processes
- Unsafe HTML rendering without sanitization
- Secrets committed to workflow YAML files

The `needs_human_review` bucket (17 PRs) was dominated by LLM failures — the model returned unparseable JSON or got confused by unusually large diffs (>8000 lines of generated code). These are explicitly flagged rather than silently accepted, which is the design intent.

The `needs_more_work` bucket (20 PRs) contained PRs that were incomplete — partial implementations, missing tests, or diffs that only added scaffolding. Several were draft PRs that shouldn't have been reviewed yet.

The single `close` verdict was for a PR that duplicated an already-merged change.

### What the model caught well

- **Security boundaries:** It reliably flagged IPC handlers without input validation, renderer-process file access, and missing Content Security Policy headers.
- **TypeScript strictness:** Missing types on function parameters, `any` usage where specific types existed, and unsafe type assertions.
- **Test gaps:** PRs that added features without corresponding test files.
- **Cross-platform issues:** Hardcoded path separators, platform-specific assumptions in shared code.
- **i18n consistency:** Missing translation keys in language JSON files.

### Where it struggled

- **Large diffs:** PRs over ~8000 lines of diff often produced truncated or malformed JSON responses. The prompt needs chunking or a larger context window.
- **Auto-generated code:** PRs that were mostly dependency updates or generated boilerplate overwhelmed the model with noise.
- **False positives in changes_requested:** About 3 of the 23 `changes_requested` verdicts were overly cautious — flagging pattern-matching code that turned out to be correctly implemented after human review.
- **Repo-specific conventions:** The model sometimes flagged patterns that were idiomatic to the project's codebase (like specific Redux-Saga patterns) as anti-patterns when they were actually intentional.

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

The configuration gained a `models.analyze_pr` key pointing to the review model (tested with `crof/deepseek-v4-pro`), independent of the issue analysis model.

The database schema grew by three tables and about 30 lines of SQL.

## Lessons

### 1. The two-pass sync is worth the complexity

I considered fetching everything in one pass. But the metadata pass is fast (5 seconds, always works), and the details pass is slow (minutes, can timeout on large diffs). Separating them means you always have a fresh PR list, and you fetch details on demand or in the background.

### 2. DeepSeek V4 Pro handled code review surprisingly well

The model found 134 issues across 96 PRs — 15 critical, 46 major. False positives were around 13% (3 of 23 `changes_requested`). Given that this is a local model running on a home server, the hit rate is practical.

### 3. Large diffs are the main failure mode

PRs with over ~8000 lines of diff consistently produced unparseable output or were placed in `needs_human_review`. For real-time code review, truncation or chunking is essential.

### 4. The confidence score is useful

When the model says "low confidence", it means something unusual — unusually large diff, ambiguous change, or output parsing issues. 27 low-confidence reviews mapped almost directly to the most complex PRs.

### 5. Draft PRs should be filtered

20 PRs with `needs_more_work` verdicts were mostly drafts or work-in-progress. Adding a `draft` filter before review would save time and reduce noise.

### 6. Posting should never be automatic

Zero reviews posted to GitHub so far — the `--dry-run` has not been removed for any PR. Every review needs human verification before it touches a public repository.

---

The issue pipeline proved the pattern worked. The PR pipeline proved the pattern generalized.

SQLite for state, `gh` CLI for data, LLMs for judgment, and explicit human review for destructive actions. That combination handled issues and now handles pull requests with the same codebase, the same configuration, and the same safety model.

What comes next is still unfolding.

---

*Written with [DeepSeek V4 Pro](https://deepseek.com/)*
