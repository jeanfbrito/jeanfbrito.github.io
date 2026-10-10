---
title: Benchmark subagent models the way you run them
date: 2026-10-10 07:18:33 -0300
categories: [AI, Tooling]
tags: [claude-code, subagents, agents, benchmarking, token-efficiency, llm, workflow]
description: I replayed real builder briefs on the Claude 5.5 models. Sonnet lost, Haiku nearly matched Opus at a quarter of the cost, and a sequential test hid the rest.
pin: false
math: false
mermaid: false
---

When the Claude 5.5 models arrived, I asked my agent framework a simple question: should the subagent roles move to different models? The quick answer is to read the price table and shuffle tiers. I measured first instead. The measurement moved three roles to new models, removed my middle tier, and showed that my own benchmark had a blind spot. An earlier run of my own had already exposed it.

## The setup

My [agentic workflow framework](https://github.com/jeanfbrito/agentic-workflow-framework) runs on Claude Code. An orchestrator in the main chat delegates to roles. Each role is a subagent file with `model:` and `effort:` in its frontmatter. Before this change, the scouts (`finder`, `researcher`, `tester`, `watcher`) ran on Haiku, `builder-fast` and `reviewer` ran on Sonnet, `builder-smart` ran on Opus, and `planner` and `auditor` inherited the session model.

The new price cards (first-party API list prices, as of October 2026):

| Model | Input $/MTok | Output $/MTok | Cache read $/MTok |
| --- | --- | --- | --- |
| Haiku 5.5 | 0.10 (prompt up to 100K tokens), 0.50 above | 0.50, 2.50 above | 0.1x input |
| Sonnet 5.5 | 2 | 10 | 0.20 |
| Opus 5.5 | 4 | 20 | 0.20 |
| Fable 5.1 | 10 | 50 | 0.25 |

Read naively, Opus costs 2x Sonnet and Haiku costs 20x less. On my workload, neither ratio held.

## Measure first: what did each role really run on?

Claude Code writes each subagent transcript to `~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl`. The role name sits in a matching `.meta.json`. Every assistant message carries `model` and `usage`. A small script reads them all and reprices the same turns on each model. It now lives in the repo as `scripts/role-spend.py`:

```bash
python3 scripts/role-spend.py --days 60 --whatif
```

Over 60 days it found 245 subagent runs worth $656 at list prices. I am on a subscription, so these are API-equivalent numbers. Five facts came out of it:

1. **The aliases had already moved.** A one-line probe shows what an alias resolves to today:

   ```bash
   claude -p --model haiku --output-format json "Reply with ok." | jq '.modelUsage | keys'
   ```

   That returned `["claude-haiku-5-5"]`. But every Haiku-role transcript before 2026-09-26 shows `claude-haiku-4-5-20251001`. The upgrade happened without an edit.
2. **`effort: high` on my Haiku roles had done nothing.** Haiku 4.5 has no effort parameter. Haiku 5.5 does, with a default of `medium`. A line I wrote for an older model started to change behavior on its own.
3. **Cache reads dominate subagent spend.** Sonnet 5.5 and Opus 5.5 charge the same $0.20 per MTok for a cache read. Repriced on the same turns, `builder-fast` costs $176 on Sonnet and $237 on Opus: 1.35x, not 2x. The `reviewer` costs $1.79 and $3.11.
4. **Haiku has a price step.** 61% of `builder-fast` turns had prompts above 100K tokens, where Haiku 5.5 costs 5x more. On Haiku, that role would cost $36. That is 5x cheaper than Sonnet, not 20x.
5. **The biggest line was not a role.** 51 of 73 `general-purpose` runs were cycles of a loop skill that named no subagent type. Each cycle rode the session model, Fable 5.1. That was 35% of all subagent spend.

Fact 3 settled two cheap moves. `reviewer` went to Opus, and `auditor` (called only after two failed attempts) went to Fable. Both are low-volume judgment roles, so the real premium is a few dollars.

## Then test: replay real briefs

`builder-fast` was the expensive question: 58 runs and 27% of spend. Public benchmarks do not know my repos, so I replayed my own past briefs. The harness is `scripts/role-ab.py`. For each task and each arm, it creates a git worktree at the task's original base commit and runs the role headless. A task-specific script grades the result. Then a blind Opus judge ranks all arms per task:

```bash
claude -p --agent builder-fast --model haiku --effort high \
  --output-format stream-json --verbose --no-session-persistence \
  --strict-mcp-config --settings '{"disableAllHooks":true}' \
  --permission-mode bypassPermissions --max-budget-usd 15 \
  --disallowedTools "Bash(git push:*)" "Bash(gh:*)" "Bash(*install.sh*)" \
  < brief.md
```

One detail mattered for safety. Deny rules from `--disallowedTools` still apply under `bypassPermissions`. I checked that with a probe before the real runs, because one base commit held an old `install.sh` that would overwrite my live `~/.claude`.

I picked three briefs because each one has an objective grade:

- **A PR fix in an open-source Electron app.** Merge a pinned dev commit, fix 5 failing specs, and answer a review-bot finding about a race. The grader runs the specs, `tsc`, and lint, and the judge compares the race fix with the one I committed.
- **A headless Godot checker for a ragdoll's joint limits** (a personal project). The checker must FAIL on the old rig and PASS on a later, legal rig. The checker that the original builder wrote in September flagged 5 of the 7 expected joints and raised 4 false alarms on the legal rig.
- **A Simplified Technical English rewrite of three doc files** with 25 hard linter findings. The grader counts findings and protected tokens, and the judge checks that the meaning survived.

Two rounds gave 7 arm-runs per task, 21 in total. Sonnet medium and Haiku high ran twice:

| Arm | Mean rank (1 = best) | Judge score (/7) | Cost per 3 tasks | Wall time | Turns |
| --- | --- | --- | --- | --- | --- |
| Opus 5.5, medium | 2.00 | 6.67 | $2.21 | 507 s | 40 |
| Haiku 5.5, high | 3.00 | 6.50 | $0.52 | 1122 s | 95 |
| Opus 5.5, low | 4.67 | 6.33 | $1.29 | 323 s | 28 |
| Sonnet 5.5, high | 5.00 | 5.67 | $1.26 | 574 s | 43 |
| Sonnet 5.5, medium (old `builder-fast`) | 5.17 | 5.67 | $0.97 | 379 s | 34 |

Sonnet was never the best choice. Haiku beat it on quality and cost, and Opus at `low` beat it on quality and speed. Raising Sonnet to `high` did not help, so the gap is the model, not the effort level.

The Godot task explains Haiku's rank best. Godot's 6DOF joint limits use a sign convention that is easy to get wrong. In the Haiku run I inspected, it wrote small probe scenes to measure the convention before it trusted it. Both Haiku runs flagged every expected joint, with 2 and 0 false alarms on the legal rig. Opus at `medium` also flagged every joint, with 0 false alarms. Sonnet and Opus at `low` raised 4 to 8 false alarms, which is the same trap the September builder fell into. More turns are not always waste.

Haiku was weaker on prose for a public repo. It ranked 5th and 6th on the STE rewrite. One run restructured a list and reflowed a sentence that had no finding. The other fixed a synonym pair in the wrong direction, from `STOP` to `HALT`.

## Where it almost went sideways

**The first round had a confound.** It compared Haiku at `high` effort with Sonnet at `medium`. "Haiku wins" and "high effort wins" looked the same. The second round added Sonnet at `high` and Opus at `medium`, plus repeats, and rejudged all seven candidates per task together.

**Worktrees share refs with their repository.** An arm can `git show` a later commit that holds the answer. One Haiku arm did inspect the real branch tip, after it had already committed its own fix. Before trusting any result, I scanned every transcript for git reads of other refs. No arm used a reference answer, but the harness now documents the risk.

**The ground truth moved.** The Godot brief targeted Godot 4.5, and the installed binary is 4.7.2. Before the runs, I ran the original checker and a later, fixed checker from the project history on both rigs with the installed binary. Those outputs became the reference.

**Haiku's cost varies a lot.** The same arm cost $0.17 and then $0.05 on one task, and $0.21 and then $0.51 on another. One run per cell would have told a different story.

**The benchmark itself was sequential.** This was the important one. My single-builder A/B said Haiku is 2 to 6 times slower per task. But on an earlier challenge, I had seen the opposite. Opus alone needed 10 rounds. Opus orchestrating Haiku workers needed 35 rounds at about the same cost, and finished in about 20% of the time. When I mentioned this, the agent first read my 20% backwards and fit it to its own data. Both results are true. In sequence, the strongest model always takes fewer turns and less wall time. In parallel, the job finishes when the slowest worker finishes. The extra rounds and the orchestrator's own re-reads at Opus prices use up Haiku's per-token saving, which is why the cost came out equal. The time is where parallel work pays.

**A coda about structure.** The first push broke CI on shellcheck, and the fix commit went out with two hard STE findings in its message. Lint, commit, and push had run as one command chain, so the lint result stopped nothing. The repo now has a `commit-msg` hook that rejects such a message, and `verify.sh` proves it rejects that exact commit message. It is the same lesson as [my earlier post about doctrine prose and hooks]({% post_url 2026-08-09-doctrine-prose-deterministic-hooks %}).

## What changed

- `builder-fast` runs on Haiku at `high` effort. `builder-smart` (Opus) also takes a failed `builder-fast` attempt and any prose for a public repo.
- `reviewer` runs on Opus and `auditor` on Fable. No role runs on Sonnet now.
- The orchestrator dispatches independent subagent work in parallel by default, without a request from me. Builders run together only when their write scopes do not overlap. A builder gets its own worktree only when the project can run its checks there, because a fresh worktree has no `node_modules`.
- Script-run `Workflow` fan-outs stay opt-in per task. Claude Code itself requires that opt-in: the keyword `ultracode` in a prompt, `/effort ultracode` for a session, or the `ultracode` setting for every session. I chose per task.

## Takeaway

Benchmark the system you will run, not the model alone. A sequential, one-agent test always favors the strongest model on turns and wall time. Use it as a quality gate for each piece of work. Then pick the dispatch shape, and price the whole job per completed task, with the orchestrator included.

---

_Written with [Claude Opus 5.5](https://www.anthropic.com/claude/opus) (`claude-opus-5-5`) via Claude Code._
