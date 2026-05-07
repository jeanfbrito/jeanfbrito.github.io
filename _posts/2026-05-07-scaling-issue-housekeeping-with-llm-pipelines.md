---
title: "Running Issuer at Scale: Closing 42 Issues Without Losing Control"
date: 2026-05-07 09:30:00 -0300
categories: [Tooling, Automation]
tags: [llm, sqlite, github, automation, config-management, issue-tracking, open-source]
description: "A sequel to the issuer architecture post: how SQLite state, config.yaml, kanban workflow, and LLM-assisted judgment made large-scale issue triage safe."
pin: false
math: false
mermaid: false
---

In the previous post, I wrote about the architecture of **issuer**: a local-first issue triage tool built around SQLite, LLM-assisted classification, and a kanban-style state machine.

That post was about building the machine.

This one is about operating it.

After the initial version was working, I used issuer on a real open-source Electron Desktop app repository. The goal was straightforward: take a backlog of stale, ambiguous, or possibly-resolved GitHub issues and move them through a careful closeout process.

The result: **42 issues closed**, one by one, with generated comments, manual verification, and a full post-run analysis.

That number is small enough that a human can still reason about every decision, but large enough to expose whether the workflow is actually usable. Forty-two issues is where a tool either starts saving time or starts creating more work than it removes.

The most important lesson was not “let the AI close issues.”

It was the opposite:

> Use automation to prepare decisions, not to hide them.

Issuer worked because the automation generated structure, comments, reports, and state transitions — while the actual destructive actions stayed reviewable and explicit.

This post covers what changed when issuer moved from architecture demo to production-ish maintenance tool.

---

## The starting point: issuer as a local triage pipeline

Issuer began as a local pipeline for managing GitHub issue work:

1. Pull issues from GitHub.
2. Store them in SQLite.
3. Use LLMs to triage, summarize, and draft comments.
4. Move tasks through a kanban state machine.
5. Let the maintainer verify and act.

The database was intentionally boring. SQLite held the issue metadata, generated comments, current kanban state, timestamps, and processing history.

The LLMs were intentionally not the source of truth. They were used for judgment-heavy tasks: summarization, classification, and drafting close messages. But the durable record lived in tables, not in model output.

The kanban state machine made the pipeline auditable. An issue could be imported, analyzed, assigned a proposed action, given a draft comment, manually reviewed, posted, closed, and marked done.

That model worked well for a prototype. But when I tried to run the pipeline across dozens of issues, two operational problems showed up immediately:

- configuration was messy and unsafe
- auto-posting comments was too risky without a review loop

Both had to be fixed before issuer could safely touch a real repository.

---

## 1. The `config.yaml` pattern

The first production-readiness bug was not glamorous: credentials.

The project had started organically, which is a polite way of saying that API keys and endpoint values had accreted across scripts. There were hardcoded keys in six scripts and one cron daemon.

That is fine for a throwaway local experiment. It is unacceptable for a repo that might be shared, forked, or even just pushed to GitHub after a long evening of debugging.

The refactor was simple and high leverage:

```text
~/.issuer/config.yaml       # Real config, gitignored, lives outside the repo
config.yaml.example         # Template committed to the repo
src/issuer/config.py        # Centralized loader
```

The real configuration moved into the user’s home directory:

```yaml
github:
  token: "ghp_..."
  owner: "example"
  repo: "desktop-app"

llm:
  providers:
    kimi:
      endpoint: "https://..."
      api_key: "..."
      models:
        craft: "kimi-k2.6"
    openai:
      endpoint: "https://..."
      api_key: "..."
      models:
        close_message: "gpt-5.5-high"
        report: "gpt-5.5-high"

issuer:
  database_path: "~/.issuer/issuer.sqlite3"
```

The committed template contained the same shape, without secrets:

```yaml
github:
  token: "YOUR_GITHUB_TOKEN"
  owner: "YOUR_ORG_OR_USERNAME"
  repo: "YOUR_REPO"

llm:
  providers:
    kimi:
      endpoint: "YOUR_KIMI_ENDPOINT"
      api_key: "YOUR_KIMI_API_KEY"
      models:
        craft: "YOUR_CRAFT_MODEL"
    openai:
      endpoint: "YOUR_OPENAI_ENDPOINT"
      api_key: "YOUR_OPENAI_API_KEY"
      models:
        close_message: "YOUR_CLOSE_MESSAGE_MODEL"
        report: "YOUR_REPORT_MODEL"

issuer:
  database_path: "~/.issuer/issuer.sqlite3"
```

Then every script stopped reading environment variables, parsing ad hoc flags, or embedding endpoints. Instead, each one used the centralized loader:

```python
from issuer import config

endpoint = config.endpoint("openai")
model = config.model("close_message")
github_token = config.github_token()
```

That looks like a small cleanup. In practice, it changed the project.

Before this refactor, issuer was a personal pile of scripts. After it, issuer became shareable. The repository could be published without leaking credentials. A new user could copy `config.yaml.example`, fill in the blanks, and run the same pipeline.

It also removed a whole class of “which model is this script using?” mistakes. When the close-message generator, the report generator, and the cron daemon all load through `src/issuer/config.py`, there is one place to inspect and one place to change.

For LLM applications, this pattern matters more than it seems. Model endpoints, model names, and API keys change frequently. Hardcoding them makes every script brittle. Centralizing them makes the system operable.

The pattern is now one of the first things I would add to any local automation tool:

```text
real config outside the repo
example config inside the repo
one loader module used everywhere
```

It is boring infrastructure, and boring infrastructure is exactly what makes an LLM tool feel less like a demo.

---

## 2. One-by-one verification workflow

The most important safety decision in issuer was this:

> The pipeline may generate GitHub comments, but it must not blindly post them.

A stale issue closeout workflow is sensitive. A bad closure comment is not just a technical error; it is a public interaction with a user who took the time to report something. If automation posts an irrelevant or dismissive message, the project looks careless.

So issuer uses LLMs to draft, not to decide invisibly.

The closeout flow for the Electron Desktop repository looked like this:

1. Generate close messages with an LLM.
2. Save those messages into SQLite.
3. Review each issue manually on GitHub.
4. Compare the generated message against the real issue context.
5. Post the comment if it is accurate.
6. Close the issue.
7. Mark the kanban task as done.

The generation step used a two-model pattern:

- **Kimi K2.6 craft** generated the first version of the close message.
- **GPT-5.5-High refinement** polished the wording and made the tone more consistent.

The important detail is where the generated result landed. It did not go directly to GitHub.

It was stored in the `task_comments` table.

Conceptually:

```sql
CREATE TABLE task_comments (
    id INTEGER PRIMARY KEY,
    task_id INTEGER NOT NULL,
    issue_number INTEGER NOT NULL,
    comment_type TEXT NOT NULL,
    body TEXT NOT NULL,
    model TEXT NOT NULL,
    created_at TEXT NOT NULL,
    posted_at TEXT,
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);
```

This made the generated comment inspectable before posting. Each issue had a proposed close message, but the message was just data until a human acted on it.

The actual manual loop was deliberately slow:

```text
for each issue:
    open issue on GitHub
    read the original report
    read recent comments, labels, and linked PRs
    read the generated close message
    decide whether it is correct
    post comment
    close issue
    mark task done in issuer
```

This is the part people often skip when talking about LLM automation. They want to jump from “the model generated a plausible comment” to “the bot can close the issue.”

That is the dangerous step.

The generated message is useful because it reduces writing effort. It is not a substitute for checking the actual issue.

In several cases, the LLM-produced comment was basically right but needed a small adjustment. Maybe the issue was not fully resolved, but had become unactionable because the reporter never provided reproduction details. Maybe the issue was actually about the web app, not the desktop app. Maybe the wording needed to be softer because the reporter had provided a thoughtful bug report.

Manual verification caught those cases.

Issuer’s job was not to eliminate judgment. It was to make judgment cheaper.

---

## 3. Categorization patterns from the 42 closed issues

After closing the 42 issues, I wanted to know what had actually happened.

Were these issues mostly fixed already? Mostly invalid? Mostly environment-specific? Mostly duplicates? Without a summary, closing a backlog can feel productive while teaching you nothing.

The 42 closed issues fell into these categories:

| Category | Count |
| --- | ---: |
| Already Implemented / Resolved | 14 |
| Not Desktop-Specific | 9 |
| Packaging / Environment | 7 |
| Outdated / One-Time | 7 |
| OS-Controlled | 3 |
| Usage Question | 1 |
| Other | 1 |

The two largest categories were the most useful.

First, **14 of 42 issues were already implemented or resolved**.

That is roughly **33%**.

These were issues where the requested behavior or bug fix no longer applied. Maybe the app had changed. Maybe a dependency update fixed the problem. Maybe a later release introduced the missing feature.

This is a common pattern in active open-source projects. The issue tracker accumulates historical state, but the application keeps moving. If nobody periodically reconciles the two, users keep seeing old reports that no longer describe reality.

A third of the closed issues being already resolved suggests a maintenance opportunity: add a periodic issue audit after releases. When major desktop behavior changes, the issue tracker should be rechecked for reports that are now obsolete.

Second, **9 of 42 issues were not desktop-specific**.

That is roughly **21%**.

For an Electron Desktop app repo, that matters. Some reports were really about shared product behavior, backend behavior, account state, or web app functionality. They landed in the desktop repo because that was where the user happened to be when they experienced the problem.

This is not user error. Users do not think in terms of repository boundaries. They report the problem where they encounter it.

But from a maintainer perspective, this category points to a routing and documentation problem. If a fifth of the stale desktop issues are not actually desktop-specific, then the project probably needs better issue templates, clearer labels, or a triage path that routes cross-platform reports to the correct place.

The next two categories were also instructive.

**Packaging / Environment** accounted for 7 issues. These were problems involving installation, local setup, distribution, dependency versions, OS packages, or environment-specific behavior.

Electron apps often live at the boundary between web code and native operating systems. That boundary is messy. Packaging bugs may not reproduce across platforms, and environment bugs can become obsolete as OS versions, app signing, installers, and dependencies change.

**Outdated / One-Time** also accounted for 7 issues. These were reports that were either tied to a transient outage, an old version, or a situation that could no longer be reproduced.

This category is a reminder that not every issue needs a code change. Some issues are historical artifacts. Closing them is not sweeping work under the rug; it is keeping the tracker representative of current reality.

Finally, there were a few smaller categories:

- **OS-Controlled**: 3 issues where the behavior was governed by the operating system rather than the app.
- **Usage Question**: 1 issue that was really a support or how-to question.
- **Other**: 1 issue that did not fit cleanly.

The statistics did not just justify the closeout work. They created feedback for future project maintenance:

- If many issues are already resolved, schedule periodic stale issue audits.
- If many issues are not desktop-specific, improve routing and templates.
- If many issues are packaging-related, invest in installation diagnostics.
- If many issues are outdated, add clearer reproduction requirements and version prompts.

That is the difference between “we closed 42 issues” and “we learned what kind of backlog we have.”

---

## 4. LLM-powered report generation

The first instinct for categorization is usually to write rules.

For example:

```python
if "already fixed" in comment:
    category = "Already Implemented / Resolved"
elif "not desktop" in comment:
    category = "Not Desktop-Specific"
elif "windows" in issue.body or "macos" in issue.body:
    category = "Packaging / Environment"
```

This works until it doesn’t.

Issue classification is full of judgment calls. A report can mention macOS without being OS-controlled. A close comment can say “this appears to be resolved” without meaning it was fixed by a specific implementation. A desktop issue can involve shared backend behavior and still have desktop-specific symptoms.

Instead of hardcoding classification rules, issuer used an LLM-powered report generator.

The script collected all 42 issues and their final closure comments from SQLite, then sent them to **GPT-5.5-High** with a single prompt asking it to:

- categorize each issue
- produce aggregate counts
- identify patterns
- format the output as a professional markdown report
- include observations useful to maintainers

The input was structured data, not a vague request. Each issue included the title, body excerpt, labels, generated close comment, and final state.

The prompt was intentionally direct:

```text
You are analyzing a completed issue closeout pass for an open-source
Electron Desktop repository.

Given the following issues and closure comments, categorize each issue
into a small set of meaningful maintenance categories.

Then produce a professional markdown report with:
- an executive summary
- a table of categories and counts
- percentages
- notable patterns
- recommendations for future triage, testing, and documentation

Prefer judgment over keyword matching. If an issue fits multiple
categories, choose the category that best explains why it was closed.
```

This is exactly the sort of task where LLMs are useful. The work is not deterministic transformation. It is editorial classification.

A keyword classifier would have been faster and cheaper, but worse. It would have encoded my assumptions before I had looked at the data. The LLM, given the full issue text and closure comments, could handle ambiguity better.

The result still needed review. But it gave me a strong first report in one pass: categories, counts, percentages, and recommendations.

This reinforced a broader lesson from issuer:

> Use LLMs where judgment, summarization, and language are the hard parts. Use SQLite where state, auditability, and recovery are the hard parts.

The report generator did not need to own the workflow. It did not need to update GitHub. It did not need to mutate state. It only needed to read completed records and produce an analysis.

That made it low risk and high value.

---

## Why SQLite mattered at scale

Forty-two issues is not “scale” in the distributed systems sense. It is scale in the human workflow sense.

At one issue, you can keep everything in your head.

At five issues, a checklist is enough.

At forty-two issues, you need state.

SQLite made the pipeline resumable. If a model call failed halfway through, the generated comments already written to `task_comments` were still there. If I stopped reviewing for the day, the kanban state told me exactly where to resume. If I wanted to generate a report after closing everything, the historical data was available locally.

The database also created a boundary between stages:

- issue import
- LLM analysis
- comment generation
- manual review
- GitHub posting
- closeout
- reporting

Each stage could be rerun, inspected, or improved independently.

That is what made the tool safe. Not because SQLite is magical, but because durable intermediate state prevents the pipeline from becoming an invisible chain of side effects.

A fragile version of issuer would have looked like this:

```text
fetch issue
ask LLM for close message
post comment
close issue
move on
```

That version is fast. It is also terrifying.

The safer version looks like this:

```text
fetch issue
store issue
ask LLM for close message
store generated comment
review generated comment
post manually or through explicit command
record posted state
close issue
record closed state
generate report
```

It is slower, but it is controllable. And for public maintainer actions, controllable beats fast.

---

## The operating model: automation as a maintainer assistant

The most productive framing for issuer is not “AI maintainer.”

It is “maintainer assistant.”

The assistant can:

- collect issues
- summarize context
- draft polite closure comments
- classify completed work
- produce reports
- maintain local workflow state

The maintainer still:

- verifies facts
- decides whether closure is appropriate
- posts public comments
- handles edge cases
- owns the final judgment

This division of labor is important. It avoids both extremes.

On one side, there is fully manual triage, where maintainers spend their limited energy rewriting the same closure comments and reconstructing old context.

On the other side, there is reckless automation, where a bot performs public actions based on probabilistic text generation.

Issuer sits between those. It makes the repetitive parts cheap while keeping accountability with the human.

That middle ground is where I think many practical LLM tools will live.

---

## Lessons from closing 42 issues

A few lessons stood out after the full run.

### 1. Centralized config is not optional

The `config.yaml` refactor was foundational. Once credentials and model names were centralized, the project became safer to run and easier to share.

If your LLM tool has secrets in scripts, fix that before adding features.

### 2. Never batch-post generated comments without review

LLMs can draft excellent issue comments. They can also miss context, overstate certainty, or choose the wrong tone.

For public repository actions, review is not bureaucracy. It is part of the safety model.

### 3. State machines beat vibes

The kanban workflow made progress visible. Every issue had a state. Every generated comment had a record. Every completed task could be audited.

Without that, the closeout pass would have been a pile of browser tabs and half-remembered decisions.

### 4. Backlog cleanup produces product insight

The category counts were genuinely useful. Learning that 33% of the issues were already resolved and 21% were not desktop-specific says something about release audits, issue templates, and repository boundaries.

Closing issues is maintenance. Analyzing the closed issues turns maintenance into feedback.

### 5. LLMs are better at reports than rules are

The report generator was one of the highest-leverage parts of the pipeline. Instead of spending time inventing brittle classification rules, I let the model make judgment calls from the actual issue and closure text.

The output still needed review, but it was a much better starting point than a keyword script.

---

## Conclusion

Running issuer on 42 real issues changed how I think about LLM automation.

The value was not in making GitHub issue maintenance “hands free.” That would have been the wrong goal.

The value was in turning a messy, repetitive, judgment-heavy workflow into a structured pipeline:

- SQLite stored the truth.
- `config.yaml` kept secrets and endpoints out of the code.
- The kanban state machine made progress visible.
- LLMs drafted comments and generated reports.
- Manual review protected the public actions.

That combination made the system feel less like a fragile AI demo and more like an engineering tool.

A local LLM-powered tool doesn't have to be fragile. With SQLite for state, config.yaml for secrets, kanban for workflow, and LLMs for judgment, you can build automation that's powerful and safe.

---

*Written with [GPT-5.5 High](https://openai.com/codex/)*