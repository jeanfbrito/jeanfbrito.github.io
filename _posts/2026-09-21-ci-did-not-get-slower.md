---
title: Your CI Did Not Get Slower. Your Test Suite Did.
date: 2026-09-21 17:04:48 -0300
categories: [Engineering, Testing]
tags:
  [ci, github-actions, jest, electron, typescript, testing, pitfalls, debugging]
description: How a 34-minute Electron PR pipeline dropped to 5 minutes once we stopped blaming runners and measured the Jest step — sharding, transpile-only ts-jest, and arm64.
pin: false
math: false
mermaid: false
---

Every pull request on the [Rocket.Chat desktop app](https://github.com/RocketChat/Rocket.Chat.Electron) was waiting 24 to 36 minutes for CI. The consensus explanation, repeated by more than one person and more than one AI assistant, was that GitHub's Windows runners had gotten slower. It sounded right. It was wrong, and the data to prove it wrong took one command.

Here is where it ended up, before the story of how:

|                                 | Before  | After                   | Change                        |
| ------------------------------- | ------- | ----------------------- | ----------------------------- |
| PR wall time (free runners)     | 34 min  | **5.2 min**             | **6.5× faster, −85%**         |
| Slowest Jest step               | 27 min  | ~3 min                  | 8× faster, −88%               |
| Build and smoke-launch feedback | ~30 min | 2 to 6 min, in parallel | 5 to 15× sooner, −80% to −93% |
| Jobs per PR                     | 3       | 9                       | 3× more runners               |

And how each step contributed:

| Step                                  | Wall time after | Step gain  | Cumulative |
| ------------------------------------- | --------------- | ---------- | ---------- |
| Baseline                              | 34 min          |            |            |
| Shard across jobs, coverage on one OS | 17.2 min        | 2.0×, −49% | 2.0×, −49% |
| ts-jest transpile-only (one line)     | 7.1 min         | 2.4×, −59% | 4.8×, −79% |
| Caches warm, Ubuntu shards on arm64   | 5.2 min         | 1.4×, −27% | 6.5×, −85% |

And per platform, comparing the baseline run with the final one. The longest job is that platform's critical path: before, its single job; after, the slowest of its two test shards and its build job.

Longest job per platform:

| Platform | Before   | After   | Change     |
| -------- | -------- | ------- | ---------- |
| Windows  | 34.2 min | 5.2 min | 6.6×, −85% |
| Ubuntu   | 24.7 min | 4.2 min | 5.9×, −83% |
| macOS    | 23.4 min | 5.0 min | 4.7×, −79% |

Slowest Jest step per platform:

| Platform | Before   | After   | Change     |
| -------- | -------- | ------- | ---------- |
| Windows  | 27.3 min | 3.0 min | 9.1×, −89% |
| Ubuntu   | 21.5 min | 2.9 min | 7.4×, −86% |
| macOS    | 18.5 min | 3.3 min | 5.6×, −82% |

Windows gained the most because it had the most to lose: it was the slowest platform on the per-file type-check, so removing that cost helped it most. After the changes the three platforms are within a minute of each other, and on Windows the critical path is no longer the tests at all but the build job packaging two architectures. macOS gained the least because its runner was already the fastest at the per-file Electron spawn that remains.

## The setup

The repo is an Electron app with a Jest suite of about 2,500 tests across 258 spec files. Tests run through `@kayahr/jest-electron-runner`, which executes each spec file inside a real Electron process so renderer code sees a real DOM and real Electron APIs. That runner has one hard constraint: it forces `--maxWorkers=1`. One worker, one Electron process per spec file, strictly sequential.

The PR workflow ran a single job per OS: install, lint, test with coverage, build, launch the built binary for 30 seconds as a smoke test. Three jobs, three platforms, each around half an hour.

## Measure first

Before touching anything I pulled per-step timings for one green run:

```bash
gh run view <run-id> --json jobs --jq '
  .jobs[] | .name as $j | .steps[] |
  "\($j)\t\(.name)\t\(((.completedAt|fromdate)-(.startedAt|fromdate)))s"'
```

| Platform | Test step | Job total |
| -------- | --------- | --------- |
| Windows  | 27m 15s   | 34 min    |
| Ubuntu   | 21m 32s   | 24.5 min  |
| macOS    | 18m 31s   | 23.5 min  |

Install, lint and build together were under three minutes everywhere. The Test step was 80% of the pipeline.

Then the same query, one successful run per month going back to the start of the year. The Windows Test step was about **1 minute** through April. It was 14 minutes in July and 27 in September. Install, lint and build were flat the whole time.

What changed between April and September was not the runner. It was the suite. Two waves of test-coverage work took it from roughly 280 tests to 2,500. Every one of those new spec files paid a fixed per-file cost, and nobody had measured what that cost was made of.

## What worked

### 1. Shard across jobs

With one worker per job, the only parallelism available is more jobs. Jest has had `--shard` since version 28, and the default sequencer splits by file count:

{% raw %}

```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
    shard: [1, 2]
steps:
  - run: yarn test --shard=${{ matrix.shard }}/2
```

{% endraw %}

I also split the build and smoke-launch steps into their own job so they run alongside the tests instead of after them. Build feedback went from "after 30 minutes" to "after 3 to 6 minutes".

Coverage only needs to be collected once, so only the Ubuntu shards run with `--coverage`. Codecov merges uploads for the same commit and flag on its own, so sharded coverage needs no local merge step.

Result: 34 minutes to 17.

### 2. Stop type-checking inside Jest

This was the big one, and it was one line.

ts-jest's default mode builds a full TypeScript `Program` for every spec file it transforms, type-checking as it goes. That is expensive, and CI never has a warm Jest cache, so every run pays it from zero.

I benchmarked it locally on four spec files with the cache disabled, two runs each:

| ts-jest mode                      | Wall time      |
| --------------------------------- | -------------- |
| default (type-check per file)     | 22.4 s, 23.5 s |
| isolated modules (transpile only) | 8.8 s, 11.3 s  |

Sixty percent less. The configuration change, as an inline override so `tsconfig.json` itself stays untouched:

```js
// jest.config.js
const tsJestTransform = {
  "^.+\\.tsx?$": ["ts-jest", { tsconfig: { isolatedModules: true } }],
};

module.exports = {
  projects: [{ transform: tsJestTransform /* ... */ }],
};
```

Nothing is lost. `tsc --noEmit` already runs in the lint step and already includes every spec file, so type errors in tests are still caught. They are just caught once, by the compiler, instead of 258 times by the test transformer.

Result: 17 minutes to 7. Per-shard Test time went from 11 to 14 minutes down to about 3.

### 3. Cache the things that were being re-downloaded

Two cheap ones. Yarn 4 with `enableGlobalCache: false` keeps its archive store in `.yarn/cache`, and that directory was not in the cache step, so every job re-fetched every archive even when `node_modules` restored fine. Electron's build step was also downloading the Electron zip on every run. Both are one `actions/cache` path each.

### 4. Try arm64 runners

GitHub offers `ubuntu-24.04-arm` free for public repos. I moved the Ubuntu test shards there. It works, with two catches covered below, and it is exactly as fast as x64: 167 and 175 seconds against 165 and 166. I kept it because the arm pool is separate capacity, so those shards no longer queue behind the x64 build jobs.

Final result with warm caches: **5.2 minutes** wall time, down from 34.

## Where it almost went sideways

**The arm run failed at `yarn install`.** puppeteer was in the dependency tree for an asset-generation script. Its postinstall downloads Chromium, and there is no arm64 Linux Chromium build. Nothing in the tests needs it, the one spec that imports it mocks the module, so `PUPPETEER_SKIP_DOWNLOAD=true` on the test job fixed it. Lesson: a dependency's postinstall is part of your platform matrix even if your code never calls it.

**Cache keys collided across architectures.** `runner.os` reports `Linux` on both `ubuntu-latest` and `ubuntu-24.04-arm`. A key built from `runner.os` alone would happily restore x64 native binaries into an arm64 job. Add `runner.arch` before the first arm job, not after the first confusing failure.

**The coverage flag was hiding tests.** The Jest config excluded 18 spec files whenever `--coverage` was active, because the coverage instrumentation trips a code-generation restriction inside the Electron runner's context. Since every platform ran the coverage variant, those 18 files were not gating pull requests on any platform. Switching Windows and macOS to plain `yarn test` fixed that as a side effect. If you exclude anything keyed to a flag, make sure at least one CI leg runs without the flag.

**swc was faster and still not worth it.** The natural next step after transpile-only ts-jest is `@swc/jest`, which does not type-check at all and is written in Rust. I measured it: about 20% faster on the transform, and 256 of 258 spec files passed. The two that failed depended on TypeScript's specific CommonJS output. One assigned onto `require(mod).fn` to stub a sibling export, which works because TypeScript routes internal calls through `exports`, and fails because swc emits exports as read-only getters. The other read a `const` inside a `jest.mock` factory, which swc's stricter hoisting evaluates before the `const` initializes. Projected saving was 20 to 30 seconds per shard. Rewriting two spec files and adding a native binary to every job's cache did not buy 0.4 minutes. The floor now is one Electron process per spec file, and no transformer touches that.

**Nine jobs are more exposed to queueing than three.** One run late in the day took 15.6 minutes wall time with every job green in under 5 minutes. Each had waited 7 to 10 minutes for a runner. The 5-minute figure assumes the organization's runner pool is not saturated. That is a real trade-off of fanning out, and worth stating in the PR rather than discovering in a retrospective.

## Takeaway

When a pipeline gets slow, pull per-step timings across months before forming a theory. In this case a single step had grown 27× while everything around it stayed flat, which pointed straight at the suite and away from the infrastructure. And check your test transformer's mode before adding runners: one line in `jest.config.js` was worth more than sharding, arm64 and caching combined.

The full change is in [Rocket.Chat.Electron PR #3511](https://github.com/RocketChat/Rocket.Chat.Electron/pull/3511), with every run id and measurement in the description.

---

_Written with [Claude Fable 5.1](https://www.anthropic.com/claude/fable) (`claude-fable-5-1`) via Claude Code._
