---
title: Doctrine prose degrades; deterministic hooks don't
date: 2026-08-09 01:40:00 -0300
categories: [AI, Tooling]
tags: [claude-code, hooks, agents, llm, bash, automation, workflow]
description: Auditing a stranger's npm package turned my agent framework's "MANDATORY" markdown rules into lifecycle hooks that mechanically enforce them.
pin: false
math: false
mermaid: false
---

I run a personal multi-agent framework on top of Claude Code: an orchestrator in the main chat delegates to builder/finder/tester subagents, and the shared state lives in a small file ledger — a todo board with definition-of-done cards, an append-only done log, a blockers file. The rules for maintaining all of this live in a markdown doctrine file, and the enforcement mechanism was, honestly, "the model follows instructions." Which it does — in short sessions. In long, messy sessions, exactly when the ledger matters most, discipline decays: a builder finishes, the card never moves to the done log, and nobody notices until the next session starts from stale state.

This week I pointed the agent at a repo I had lying around — [openwolf](https://www.npmjs.com/package/openwolf), an open-source context/memory layer for coding agents — with the question "anything here worth stealing?" The most valuable thing it found wasn't a feature. It was a stance: **every "MANDATORY" paragraph in that project's protocol is backed by a lifecycle hook doing a cheap mechanical comparison.** The prose says "update your memory file every session"; a Stop hook checks the file's mtime against session activity and injects an `ACTION REQUIRED` warning when the prose was ignored. The check is the useful part. The prose is just documentation for it.

## The setup

Openwolf itself turned out to be orthogonal to my framework — it's a single-agent memory layer with zero multi-agent machinery — so this wasn't adopting a dependency, it was adopting a pattern. The survey also produced a healthy "not worth it" pile: its file indexer (I already have a code graph for that), its dashboard, its keyword heuristics for detecting repeated mistakes. And one deliberate difference: openwolf's hooks warn but never block, which is the right call for a package installed into strangers' repos and the wrong ceiling for a personal framework, where hard enforcement is exactly the point.

Four mechanisms survived the triage, all implemented as plain bash hooks wired into Claude Code's hook events:

1. **A budgeted SessionStart digest.** My old SessionStart hook printed unbounded file pointers. The new one packs a digest in strict value order — pending audit warnings, then blockers, then open cards, then handoffs — under a hard character budget, dropping overflow instead of taxing every session with a growing ledger.
2. **A PreCompact snapshot.** The orchestrator chat is the longest-lived context in the system, so it's the one that gets compacted mid-arc — after which it can genuinely re-dispatch work that's still running. A PreCompact hook snapshots the in-flight cards; when the session resumes with `source: compact`, the SessionStart hook injects a "do NOT re-dispatch — check your running tasks first" warning with those card titles.
3. **A Stop-hook ledger auditor.** The star of the show, and the direct port of openwolf's stance. More below.
4. **Lock-guarded ledger appends.** Parallel builders all appending to the same markdown files is a lost-update waiting to happen. A tiny helper serializes appends with an `mkdir` spinlock (macOS has no `flock`), with a deliberate failure mode: on lock timeout it appends anyway and marks the entry, because a rarely-interleaved entry beats a silently dropped one.

One process note that paid off immediately: before writing any of this, I had a research agent verify the hook API against the [current Claude Code hooks docs](https://code.claude.com/docs/en/hooks) instead of trusting training data or the surveyed repo's assumptions. Two findings shaped the design. First, Stop hooks *do* support injecting context into the conversation via `hookSpecificOutput.additionalContext` — documented, not folklore. Second, the session transcript's JSONL format is explicitly undocumented, so anything parsing it must treat the schema as hostile: skip unparseable lines, never hard-fail on drift.

## What worked

The Stop auditor is the piece I'd tell anyone to build first. At session end it gets the transcript path on stdin, counts the session's `Write`/`Edit` tool calls, and runs three checks that are nothing more than `stat` and `grep`:

- three or more source files written, but the done log's mtime predates the session → "N files changed but done.md has no new entry";
- a card still marked `[doing]` with no board update all session → "card left open: close it, block it, or hand it off";
- the blockers file and the board disagreeing about what's blocked.

Findings go two places: injected same-turn through the Stop hook's JSON output, and written to a pending-audit file that the next session's digest injects at the very top. Doctrine violation used to be silent; now it's the first thing the next session reads.

```json
{
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": "ACTION REQUIRED: 6 files changed but done.md has no new entry — append the completion entry or write a handoff."
  }
}
```

The append lock is small enough to show whole. The interesting part is the exit strategy, not the lock:

```bash
lock=".localdev/workflow/.done.md.lock"
deadline=$((SECONDS + 2))
until mkdir "$lock" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    break   # append anyway — a rare interleave beats a dropped entry
  fi
  sleep 0.05
done
printf '\n%s\n' "$entry" >> .localdev/workflow/done.md
rmdir "$lock" 2>/dev/null
```

And because a hook suite that silently breaks is worse than no hooks at all, the framework's verify script doesn't re-describe what the hooks should do — it *executes* them against fixture directories on every install: fake board, fake blocker, synthetic transcript, then asserts the digest ordering, the snapshot lifecycle, and the audit warnings, end to end.

## Where it almost went sideways

Three wrong turns, in ascending order of embarrassment.

**The heredoc that ate its own stdin.** The hooks embed Python inside bash for JSON handling, and the first version read the hook payload like this:

```bash
# BROKEN — the heredoc IS python's stdin; the piped payload is never seen
python3 <<'PY'
import sys, json
data = json.loads(sys.stdin.read() or "{}")
PY
```

A heredoc piped to an interpreter is that process's stdin. `sys.stdin.read()` inside it returns the empty string — silently, every time, while everything else works. The fix is to capture stdin in bash first and pass it through the environment:

```bash
HOOK_STDIN_JSON="$(cat)"
export HOOK_STDIN_JSON
python3 <<'PY'
import os, json
data = json.loads(os.environ.get("HOOK_STDIN_JSON") or "{}")
PY
```

The nasty part is that this shipped. The first hook's tests all passed, because every fixture asserted on file-derived output and none asserted on a stdin-derived field. It was only caught one card later, when a fixture finally checked a value that could only have come from the payload. New testing rule: every hook fixture must assert at least one field that only stdin can supply.

**The fixture inside the exclusion list.** The Stop auditor ignores writes to scratch and ledger paths, so they don't count as "session activity." My first positive-case fixture lived in the session's scratch directory — one of the excluded paths. The check "failed to fire," and it took a beat to realize the filter was working perfectly and the test was standing inside it. If you're testing exclusion logic, put the fixture somewhere neutral first.

**The arc that was "done" but not deployed.** This is the one that stings. Six cards shipped, every definition-of-done green, an independent validation pass confirmed the whole chain — install, verify, uninstall, all hooks firing end to end. I declared the arc closed. Then one question: *"all we have running already?"*

No. Every test had — correctly — run against throwaway `$HOME` directories. Nobody, at any point, had run the installer against the real environment. The live config still had the old hook and none of the new ones. A framework built specifically to catch silent non-compliance was itself silently not running, because the deployment step belonged to no card and no check.

The immediate fix took one command. The durable fix is the same medicine as everything above: the arc-close rule now includes a live install-and-verify, and the obvious next hook is a drift check comparing the repo's hook scripts against the installed copies. Sandbox-validated is not deployed.

## Takeaway

If a rule for an LLM agent matters, don't leave it as prose — back it with a mechanical check that makes violations loud, because instruction-following degrades precisely in the long sessions where the rules earn their keep. And apply the same skepticism to your own process that you apply to the agent's: my definition of done validated everything except the step that made any of it real.

---

*Written with [Claude Fable 5](https://www.anthropic.com/news/claude-fable-5-mythos-5) (`claude-fable-5`) via Claude Code.*
