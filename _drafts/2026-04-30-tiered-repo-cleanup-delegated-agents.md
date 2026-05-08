---
title: Tiered repo cleanup with delegated agents
date: 2026-04-30 21:30:00 -0300
categories: [Tooling, Workflow]
tags: [refactor, agents, claude-code, python, testing, monorepo]
description: How I shrank a four-month-old test framework from three orchestrators to one in a single session, with strict tier boundaries and delegated builder agents that kept diffs out of my context window.
pin: false
math: false
mermaid: false
---

mOSdat is my multi-OS test framework — Proxmox VMs, GPU passthrough, VLM-driven UI checks. After four months of organic growth the repo had three smoke orchestrators, twelve top-level result dirs, a 735-line runbook, hardcoded paths everywhere, and a ghost directory nobody dared delete. I had a couple of hours and an Opus 4.7 session, so I tried something I hadn't before: tier the cleanup, delegate every mechanical edit to a builder agent, and keep the architect on the steering side.

## The setup

A snapshot of the repo before:

```
mOSdat/
├── automation/                  ← 15 flat Python files
├── os/                          ← 7 distros × 6 bash scripts each
│   ├── manjaro/                 ← ghost dir, only config.sh
│   └── manjaro-linux/           ← real one
├── shared/
│   ├── tests/                   ← Linux smoke .sh
│   ├── tests-functional/        ← YAML
│   └── tests-windows/           ← PowerShell
├── tools/                       ← single-file dir
├── results/                     ← 12 dated dirs, 130MB, three naming schemes
├── .sisyphus/                   ← agent scratch in tree
├── .knowledge/pending/          ← agent scratch in tree
├── AGENTS.md                    ← 735 lines
└── (no pyproject, no installable CLI, .venv often committed)
```

Three smoke runners coexisted: bash `os/<distro>/full-test.sh`, Python `automation/runner.py`, plus Python `automation/functional_runner.py` for the VLM flow. Two of them did the same job in different languages. The runbook still contained absolute paths from before the repo was renamed. The repo was cloned locally as `test-framework/` even though the GitHub project name was `mOSdat`.

I had been carrying the mess for months. Whenever I needed to actually run a test I knew where things were. But every time someone — including a fresh AI session — asked "where do I start?", they got lost.

## Triage before refactor

Before touching anything structural, audit unsafe state:

```bash
for d in mOSdat Rocket.Chat.Electron electron-linux-testing; do
  echo "=== $d ==="
  (cd "$d" && git status -sb && git log @{u}..HEAD 2>&1 | head -5)
done
```

Findings:

- `mOSdat`: 17 dirty files, 3 unpushed commits — VLM port + automation hardening from the past month, all local
- `electron-linux-testing`: no remote configured at all, four commits offline
- `Rocket.Chat.Electron`: detached HEAD on tag `4.12.0-alpha.2` (safe, anchored by the tag) plus a 748MB untracked build-backup directory

Five minutes saved a month of work. Commit and push the dirty mosdat tree, create a private GitHub remote for the orphan repo with `gh repo create … --source=. --remote=origin --push`, archive the legacy repo on GitHub once its content was clearly superseded, then delete the local clone. Reclaim 748MB by removing the build backup that didn't need tracking.

## Three tiers with explicit risk

I split the cleanup into tiers with explicit risk levels:

- **Tier 1 — quick wins, mechanical, no decisions.** Delete the manjaro ghost, move the misplaced pytest file out of the runtime package, gitignore `.venv/` and `__pycache__/`, fold `tools/` into `automation/`, audit one floating helper script.
- **Tier 2 — structural, medium risk.** Rename `shared/tests*` to symmetric `shared/scenarios/{smoke-linux,smoke-windows,functional}`, submodule the flat `automation/` into themed packages (`proxmox/`, `transport/`, `runners/`, `vlm/`, `reporting/`), add `pyproject.toml` with a `mosdat` console script, split the 735-line `AGENTS.md` into focused runbooks under `docs/runbooks/`.
- **Tier 3 — strategy decisions.** Which smoke runner is canonical? I picked Python because it already owned the functional runner, had `state.py` with resumable runs, and used the VNC channel the bash scripts never had. Bash kept the per-OS adapters for build, deploy, and gpu primitives only.

Tasks went into a task list with explicit blocks-on dependencies. T2.1 (rename `shared/`) and T2.4 (split runbook) could parallelize — they touched different files. T2.2 (submodule reorg) blocked on the runner decision in T3.1. T2.3 (pyproject) blocked on T2.2 because the package layout dictates the entry point. Easy graph.

## Delegating mechanically — the part that matters

The principle that keeps the architect's context window clean: **never read source for a mechanical edit**. The orchestrator writes a brief. A `builder-fast` or `builder-smart` agent reads, edits, verifies, and reports. Three rules carried every dispatch:

1. **The brief is exhaustive on scope and constraints.** Every dispatch listed exactly the files in scope, exactly which edits were allowed, and explicit "DO NOT touch" lines. Half my prompts ended with three to five negatives.
2. **Verification is the agent's job, not mine.** Every brief asked the agent to grep for any remaining references to old paths after the edit, run a syntax check on shell scripts, run `python -c "import ..."` on Python modules, run the test if applicable, and report the result inline.
3. **Report back is a checklist.** "Files changed (count + list), commit hash + push status, surprises." The architect reads a report; the architect does not re-read the diff.

Example constraint block from the submodule reorg brief:

```
Constraints:
- The CLI entry `python -m automation.main` MUST continue to work after the reorg.
- DO NOT change behavior — purely a reorganization.
- DO NOT add pyproject.toml (Tier 2.3).
- DO NOT rename the package itself (still `automation`).
- DO use `git mv` for every move (history preservation).
```

The builder moved twelve files, created five `__init__.py` files with re-exports of the public symbols, updated seventeen import statements across nine files, and verified `python -c "import automation.proxmox; import automation.transport; ..."` for every subpackage before committing. I read a 600-character report and approved.

## Where it almost went sideways

Three pitfalls deserve calling out — together they argue for the verification rule above.

**The transitive import trap.** After the submodule reorg, `python -c "import automation.runners.smoke"` raised:

```
ModuleNotFoundError: No module named 'Crypto'
```

The smoke runner imports nothing crypto-related. The chain: `runners/smoke.py` triggers `automation.transport` package init, which re-exports `VncClient` from `transport/vnc.py`, which has `from Crypto.Cipher import DES` for RFB password authentication. So even though the smoke runner never touches VNC at runtime, importing it at module load pulls the whole crypto dependency through the package init. The `pyproject.toml` had `pycryptodome` under `[project.optional-dependencies.functional]`, treating it as VLM-only. It isn't. Five other deps had the same problem — Pillow, openai, PyYAML, websockets. Promoted all five to base `[project.dependencies]`.

The lesson: **transitive imports through package `__init__.py` re-exports defeat optional dependencies.** If you want true optional deps, lazy-import inside functions or skip the re-export. Otherwise pin them to the base layer.

**Test path break after `git mv`.** The pytest file `tests/test_if_visible.py` loaded its module under test by absolute file path:

```python
_spec = _ilu.spec_from_file_location(
    "functional_runner",
    Path(__file__).parent.parent / "automation" / "functional_runner.py",
)
```

After moving `functional_runner.py` to `runners/functional.py`, that path no longer resolves. Static path strings inside Python source escape `git mv`'s grasp. The fix wasn't only the path — `_mod.__package__ = "automation"` had to become `"automation.runners"` so the relative imports inside the moved file resolved correctly, and three `sys.modules` stub keys had to flip from `automation.vlm_client` to `automation.vlm.client` to match the new layout.

The lesson: **when the brief says "fix all imports", remember dynamic loaders too.** A grep for `import` won't find `spec_from_file_location` calls.

**Naming drift in `results/`.** Twelve dated directories with three different conventions: theme (`gpu-passthrough`), per-OS (`fedora42-test`), full-matrix (`full-matrix-4.12.0-alpha.2`), or none of the above. Reorganizing existing dirs wasn't enough — a future run would just produce another inconsistent name. The fix had to push *into the runners*: `runners/smoke.py` now writes to `results/smoke/<date>_<label>/`, `runners/functional.py` writes to `results/functional/<date>_<label>/`, and `reporting/aggregate.py` walks the typed subdirs (with a fallback for the legacy flat layout). The same commit added `.gitignore` rules for screenshots and rebuildable packages — `results/**/*.png`, `results/**/*.deb`, etc. — followed by `git rm --cached` for the sixty already-committed artifacts. Local files preserved, repo size dropped.

The lesson: **a naming convention you don't enforce in code isn't a convention.** It's an ad hoc agreement that breaks the next time anyone is in a hurry.

## The receipt

Nine commits, in order:

```
04bc788 chore: Tier 1 cleanup — delete ghosts, relocate misplaced files
2d3a800 refactor: drop bash matrix runner — Python is canonical
ff2cb2c refactor: rename shared/tests* to shared/scenarios/*
dd900d0 docs: split AGENTS.md into focused runbooks
a6be353 refactor: submodule automation/
552a52e fix(tests): repair test_if_visible.py after reorg
cf16f0a build: add pyproject.toml + mosdat CLI
34b55f2 refactor(results): split by run type, gitignore binaries
4c63d4b chore: remove agent scratch + fix base deps for smoke imports
```

T2.1 and T2.4 ran in parallel because they touched different files. The rest serialized through the dependency graph.

Final repo: pip-installable, `mosdat run|test|functional` CLI, fifteen previously flat Python files in five themed subpackages, three symmetric scenario dirs, five focused runbooks, typed result dirs with a written retention policy, no agent scratch in tree, no hardcoded user paths anywhere a stranger would copy from.

## Takeaway

Two patterns I am keeping for next time.

**Tier the cleanup, then dispatch.** Tier 1 is mechanical, no architecture decisions, parallel-safe. Tier 2 is structural, mostly serial. Tier 3 is the strategy call you make at the keyboard. Resist mixing them — the moment you slip a Tier 3 question into a Tier 1 brief, the agent will pick the wrong answer for you and you will not notice until three commits later.

**Write briefs that survive the agent picking up cold.** The agent has no session memory and no idea why this matters. It has the brief and the repo. If the brief does not list every "DO NOT", the agent will faithfully refactor exactly the thing you wanted to leave alone. Writing a paragraph of constraints feels like overhead. It is the cheapest insurance you can buy.

Total session: under two hours. Total architect tokens spent reading source code: nearly zero — the agents kept the diffs in their own context, not mine.

---

*Written with [Claude Opus 4.7](https://www.anthropic.com/claude/opus) (`claude-opus-4-7[1m]`) via Claude Code.*
