---
title: Splitting an Electron Release Pipeline Into Parallel Jobs
date: 2026-09-21 23:06:33 -0300
categories: [Engineering, Testing]
tags:
  [
    ci,
    github-actions,
    electron,
    electron-builder,
    code-signing,
    release-engineering,
    pitfalls,
  ]
description: How the installer and release builds of an Electron app went from 45–82 minutes to 12–16 by dropping duplicate tests and splitting packaging per target — and the one file that breaks if you split naively.
pin: false
math: false
mermaid: false
---

Earlier today I wrote about taking the PR test pipeline of the [Rocket.Chat desktop app](https://github.com/RocketChat/Rocket.Chat.Electron) from 34 minutes to 5 ([Your CI Did Not Get Slower]({% post_url 2026-09-21-ci-did-not-get-slower %})). That left two slower pipelines untouched: the one that builds installers for a labelled PR, and the one that builds, signs and publishes a release when a tag is pushed. This post is about those two, and about the small file that would have broken auto-update if I had split the release build the obvious way.

| Pipeline                                      | Before       | After        | Change           |
| --------------------------------------------- | ------------ | ------------ | ---------------- |
| PR installer builds (all 3 OSes)              | 45 to 49 min | 11 to 12 min | about 4× faster  |
| Release build (all 3 OSes, signed, notarized) | 54 to 82 min | 16 min       | 3.3 to 5× faster |

## The setup

Both pipelines had the same shape: one job per operating system, and each job did everything. Install dependencies, lint, run the full Jest suite, build the app bundle, then run electron-builder for every installer target in sequence. On Windows that meant NSIS, then MSI, then AppX, each for x64, ia32 and arm64, followed by code signing through a cloud KMS and signature verification. On macOS a universal build of dmg, pkg, zip and the App Store target, plus notarization. On Linux AppImage, deb, rpm, tar.gz and snap, plus a Snapcraft upload.

Per-step timings from the last two release builds:

| OS      | Job          | Lint + tests | Package + sign |
| ------- | ------------ | ------------ | -------------- |
| Windows | 54 to 56 min | 29 min       | 21 to 22 min   |
| macOS   | 40 to 48 min | 19 to 23 min | 18 to 21 min   |
| Linux   | 35 to 36 min | 23 min       | 11 min         |

Two things jump out. Lint plus tests were 55 to 66% of every job, and they were the same suite the PR pipeline had already run on the same commit. And the packaging step was a sequence of independent electron-builder invocations that happened to share a runner.

## What other Electron apps do

Before redesigning, I had the release workflows of Bitwarden Desktop, Element Desktop, GitHub Desktop and Rancher Desktop pulled and compared. The patterns were consistent:

- One job per OS everywhere. Nobody splits Windows per installer target.
- Nobody runs the unit test suite in the release workflow. Tests gate PRs; the release workflow only builds. Bitwarden adds cheap post-build jobs that install and launch each package instead.
- Signing and notarization stay inside the build job. Only Rancher separates signing into a downstream job, and it pays for it by shipping multi-gigabyte artifacts between jobs.
- macOS is one universal build on one runner. Bitwarden splits macOS into two jobs, one for the GitHub release and one for the App Store.

So the industry answer to "should I run tests in the release build" was a clear no, and the answer to "should I split Windows per target" was "nobody does, but nobody has your 21-minute sequential step either".

## What worked

### Drop the duplicate gate

Both pipelines lost their lint and test steps. For the PR installer build that is obviously safe: the same PR runs the test pipeline in parallel. For the release build the argument is one step longer. Tags are cut by a script that refuses any commit not already on the development, main or a release branch, and every commit on those branches got there through a PR that passed the test pipeline. Re-running the suite on three more runners at tag time added 19 to 29 minutes per job and no new signal.

This alone was most of the gain.

### Split packaging per installer family

The release build went from three jobs to seven, plus one tiny job up front:

| Job            | Targets                                                 |
| -------------- | ------------------------------------------------------- |
| windows-nsis   | nsis for x64, ia32, arm64; sign and verify              |
| windows-msi    | msi for the same three; sign and verify                 |
| windows-appx   | appx for the same three; no signing, the Store signs it |
| macos-dmg      | dmg, zip and pkg, universal, notarized                  |
| macos-mas      | the App Store target, universal                         |
| linux-appimage | AppImage, deb, rpm, tar.gz                              |
| linux-snap     | snap, plus the Snapcraft upload                         |

The release action that wraps electron-builder gained a `targets` input, so each job runs a single invocation with its own list. Windows packaging went from 21 minutes sequential to about 9 in parallel. macOS is now bounded by the App Store job at about 13 minutes, but the files users actually download are on the draft release after 6.

### A prepare job to kill a race

The release action finds or creates a draft GitHub release for the tag, then uploads its files into it. With three jobs that finished minutes apart, the find-or-create never raced. With seven jobs, two of which take about the same time, it would have, and the result would be two draft releases for one tag. A `prepare` job now creates the draft first, and every build job depends on it. It costs under a minute.

### A dry run that needs no tag

Release workflows only run on tag push, with real signing keys and real notarization. That makes them hard to change safely: the first time you find out the new workflow is wrong is when a release is on the line. I added `workflow_dispatch` to the workflow as an always-dry-run mode. It builds and signs every target exactly as a tag would, skips the GitHub release and the store upload, and drops each job's output into a workflow artifact. The action itself got a `mode` input with `build`, `prepare` and `dry-run` values.

That dry run is how the numbers in this post were measured, from the branch, before anyone considered merging it.

### Trim the PR installer build too

The PR pipeline that builds installers on demand got the same treatment plus a few smaller cuts: macOS builds only the dmg, Windows only NSIS, the snap is still built and uploaded but no longer published to the store's edge channel on every push, and adding the label now triggers a build immediately instead of waiting for the next commit. 45 to 49 minutes became 11 to 12.

## Where it almost went sideways

### The update metadata file

electron-updater reads a small YAML file per platform, `latest.yml` on Windows, `latest-mac.yml` on macOS, `latest-linux.yml` on Linux. electron-builder writes it at the end of a run, and it lists every artifact that run produced with sizes and SHA-512 checksums. The updater downloads the file, finds the entry for its platform, checks the hash, installs.

Now split Windows into three jobs. Each job's electron-builder writes its own `latest.yml`. The NSIS job's copy lists the four exe installers. The MSI job's copy lists nothing the updater can use. The AppX job's copy likewise. All three upload a file with the same name to the same release, and whichever finishes last wins. Two out of three orderings leave every Windows user unable to update.

The fix was a rule rather than code: exactly one job per platform owns the metadata file, the job that builds the artifact the updater consumes. NSIS on Windows, dmg plus zip on macOS, AppImage on Linux. The action got an `upload_update_metadata` flag, and every other job sets it to false so the yml files are filtered out of its upload list. The dry run then confirmed each owner's file listed the same entries as the last shipped release, with checksums that matched the signed binaries. The Windows one has an extra wrinkle: signing changes the file, so the checksums in `latest.yml` are rewritten after signing, and that rewrite has to live in the NSIS job too.

### Signing steps that assume everything is present

The Windows signing code globbed for exe and msi files and threw if it found none. That was correct when one job built everything. In the AppX job it would have failed the build, because AppX packages are signed by the Store and there is nothing for the KMS signer to do. The signing and verification steps are now skipped when a job builds neither NSIS nor MSI.

### A GitHub outage on the first run

The first dry run had six green jobs and one red. The NSIS job failed inside the app build with `HTTPError: Response code 500` from GitHub's own release download for the Electron binary. A rerun passed. It is a reminder that the more jobs you fan out, the more often you meet transient failures, and that caching the Electron download is worth doing even when it saves no time on the happy path.

### The unsigned dmg that turned out to be normal

While checking the macOS output I ran Gatekeeper's assessment on the dmg and got `rejected, source=no usable signature`. That looked like a regression until I ran the same command on the dmg of the last shipped release and got the same answer. electron-builder does not sign the dmg container unless told to. Gatekeeper evaluates the notarized, stapled app inside it, and that one passed. Worth knowing before you file a bug against your own pipeline.

## Takeaway

When a workflow does several independent things in sequence on one runner, the split itself is easy. The hard part is finding the shared state that only worked because everything ran in one process. Here it was one 500-byte YAML file, and the answer was ownership: one job writes it, everyone else stays out. And build yourself a way to run the release pipeline without releasing anything. Every number above came from that dry run, and I would not have wanted to learn any of it on a real tag.

The changes are public in [PR #3512](https://github.com/RocketChat/Rocket.Chat.Electron/pull/3512) and [PR #3513](https://github.com/RocketChat/Rocket.Chat.Electron/pull/3513), with every run id and measurement in their descriptions.

---

_Written with [Claude Fable 5.1](https://www.anthropic.com/claude/fable) (`claude-fable-5-1`) via Claude Code._
