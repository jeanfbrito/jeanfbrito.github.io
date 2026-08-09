---
title: "The Week My UI Bugs Started Upgrading My Tools"
date: 2026-08-09 01:30:00 -0300
categories: [AI, Tooling]
tags:
  [
    electron,
    claude-code,
    fuselage,
    svg,
    design-systems,
    agent-skills,
    code-review,
    devtools,
  ]
description: "A Chrome-style download indicator took 28 commits and four designs. The worst bugs passed every test — so I taught them to the tools that will write my next UI."
pin: false
math: false
mermaid: false
---

I spent a week building a Chrome-style downloads indicator for [Rocket.Chat Desktop](https://github.com/RocketChat/Rocket.Chat.Electron) — the little arrow in the titlebar with a progress ring that fills as your download advances. Twenty-eight commits, four competing glyph designs, one design reviewer with strong opinions, and a handful of bugs that passed every single automated check I had. The feature shipped ([PR #3443](https://github.com/RocketChat/Rocket.Chat.Electron/pull/3443)), but the thing I actually want to write about is what happened _after_ each bug: instead of just fixing them, I fed every lesson back into the tooling — repo docs, agent skills, a design-system linter, and two upstream bug reports. By Friday, the tools that will build my next feature already knew everything this week taught me.

## The setup

The task sounded simple: replace a pill-shaped download badge with a Chrome-style indicator — an icon button whose circle fills with blue as downloads progress, a completion dot that waits until you acknowledge it, and a percentage label controlled by a settings toggle.

Two early investments turned out to carry the whole week:

**A simulation entry point.** Before polishing any visuals, I added a `Simulate Download` item to the app's developer menu. It replays two staggered fake downloads through the _real_ Redux lifecycle — same actions, same reducers, same UI — one finishing in ~8 seconds, the other in ~14, so the averaged percentage, the filling ring, and the completion dot all demo themselves in one click. It paid for itself the first day: wiring it up exposed a real bug where downloads interrupted by an app restart rehydrated as "downloading forever."

**A comparison row instead of iteration.** When the design was contested, I didn't iterate-replace-iterate. I built four variants — Chrome-style solid arrow, an arc traced over the stock icon's own circle, a full redraw with a darker track, and the original ring — as a `variant` prop, rendered side by side in the titlebar behind the developer-mode flag. The reviewer picked a winner by looking at all four _in the running app, in real state_. Cleanup deleted the losers in one pass: **−581 lines**.

## What worked: verifying pixels, not assertions

The recurring theme of the week: component tests cannot see paint. Electron gave me a better channel. The dev build exposes the main-process Node inspector (`--inspect`), and from that one WebSocket you can drive the entire app — no renderer devtools needed:

```javascript
const targets = await fetch("http://127.0.0.1:9339/json").then((r) => r.json());
const ws = new WebSocket(targets[0].webSocketDebuggerUrl);
// ... minimal JSON-RPC plumbing for Runtime.evaluate ...

// `require` is NOT in eval scope — go through process.mainModule
const REQ = "process.mainModule.require";

// Click real menu items (this is how the simulation gets triggered)
await ev(`(() => { const { Menu } = ${REQ}('electron');
  Menu.getApplicationMenu()?.getMenuItemById('simulateDownload')?.click();
  return 'clicked'; })()`);

// Read the renderer DOM as ground truth
await ev(`(() => { const { BrowserWindow } = ${REQ}('electron');
  const w = BrowserWindow.getAllWindows().find((w) => !w.isDestroyed());
  return w.webContents.executeJavaScript(
    "getComputedStyle(document.querySelector('[data-testid=downloads-glyph]')).opacity"
  ); })()`);

// Screenshot a region of the titlebar
await ev(
  `(() => { /* webContents.capturePage({x, y, width, height}) → PNG */ })()`,
);
```

Real menu clicks, real Redux, real paint. Every design iteration this week ended with this loop: trigger the simulation, read computed styles as truth, screenshot the titlebar strip, look at the actual pixels.

## Where it almost went sideways

Four bugs, and every one of them passed the gates that were supposed to catch it.

### The invisible ring

The progress arc — an SVG circle with `stroke-dashoffset` driven by download progress — simply didn't render. Every DOM attribute inspected correct: right radius, right dasharray, right stroke. All unit tests green. The circles were being drawn **24 pixels below the viewBox** and clipped into nothing.

The cause is a genuinely nasty corner of the SVG spec: the `transform` _attribute_ maps onto the CSS `transform` _property_. My styled-component wrapper set a CSS `transform-origin`, which then stacked onto the origin already baked into the attribute's `rotate(-90 16 16)` — double-applying the offset and shoving the artwork out of frame. jsdom-level tests can never catch this; only a bounding-rect-versus-viewport check in the live app did.

The rules that came out of it: keep start-angle rotation as an attribute _on the shape itself_, never set an unconditional CSS `transform-origin` near SVG, and scope `transform-box: fill-box; transform-origin: center` to the animating state only.

### The lying screenshots

Twice I "caught" the indicator frozen mid-download — screenshots showed 19%, then 29%, unmoving across ten seconds. I diagnosed timer bugs that did not exist. The app was fine; my _camera_ was broken: macOS stops painting occluded windows, and Electron's `capturePage` happily returns the last painted frame while the DOM keeps moving underneath.

The fix is one line (`win.show(); win.focus()` before every capture), but the lesson generalizes beyond Electron: **when a UI element looks stuck, first prove your observation channel is live** — read the DOM state as truth before debugging the UI.

### The token that typechecked and still looked broken

The completion dot used a design-system token that _sounded_ right: a "status background success" color. It typechecked against the installed types. It passed the lint rule that bans raw hex values. And in light theme it was a washed-out pastel mint, because `status-background-*` tokens are pale _badge backgrounds_ designed to sit behind darker text — the correct family for a small solid dot is the presence-bullet one.

This is the bug class that reframed my week: **type and lint gates prove that names exist and literals are absent. They cannot prove intent.** No gate can know you meant "solid dot" when you typed a background token. A related trap: a `var(--token, #fallback)` fallback hex is _not_ the themed value — tokens resolve differently per theme, injected at runtime, so eyeballing the fallback tells you nothing about what users see.

### The vanishing staged files

The strangest one wasn't UI at all. Three times in a row, `git add` succeeded — the files echoed back, `git ls-files` listed them — and by the next command they had _vanished from the index_. Not ignored (`git check-ignore` said no), not untracked, just gone. One attempt lost 6 of 16 files inside a single atomic `add && commit` invocation.

Git wasn't broken. A background code-indexing tool was analyzing my repo — including its linked worktrees — and mutating their git index while it ran. Killing the process fixed everything instantly. The same tool turned out to be touching watched source files, which explained days of "phantom" dev-server restarts I had blamed on everything else.

Rule earned the hard way: **when git violates its own invariants, hunt for concurrent tooling before questioning git.** `pkill` the suspect and retry — that's the diagnostic. Both behaviors are now reported upstream ([#2906](https://github.com/abhigyanpatwari/GitNexus/issues/2906), [#2907](https://github.com/abhigyanpatwari/GitNexus/issues/2907)) with the full repro.

## Closing the loop: bugs as tool upgrades

Here's the part I'm most pleased with. Each of those lessons would normally live in my head for a month and then evaporate. Instead, every one of them got promoted up a ladder of permanence, each rung outliving the one below:

1. **The fix** — dies with the PR that ships it.
2. **Repo docs** — a `desktop-ui-guidelines.md` in the app repo now carries the token-semantics table, the SVG transform-origin pitfall, the animation-timing standards, and the layout traps. The agent-guidance files (`AGENTS.md`/`CLAUDE.md`) point at it, so any coding agent — not just mine — reads it before styling titlebar controls.
3. **A runbook skill in the repo** — the inspector-driving technique above became `skills/dev-app-verify/SKILL.md`, plain Markdown any agent can follow, with the occlusion/watcher/singleton pitfalls documented as first-class warnings. I had rewritten that script from scratch roughly fifteen times during the week; now it's a lookup.
4. **The design-system tool** — I maintain [fuselage-craft](https://github.com/jeanfbrito/fuselage-craft), an agent skill that gates UI work against the Fuselage design system (type gate + literal-banning lint gate). The token bug proved those gates have a semantic blind spot, so [PR #1](https://github.com/jeanfbrito/fuselage-craft/pull/1) gave it the missing layer: an intent→token-family knowledge file every command must consult, and a new resolver category that reports each token's **light and dark values live from the installed package** — so "the fallback isn't the themed value" went from a lesson I remember to a fact the tool proves per token.
5. **The loop itself, as a skill** — the process of feeding gaps back (classify the gap → knowledge vs resolver vs lint rule → honor the contribution contract) is now `craft-evolve`, a skill that ships _inside_ fuselage-craft. It lives in the repo deliberately: the contribution contract evolves in the same PRs that change the engine, so it can't drift the way external docs do.
6. **Upstream issues** — for the bugs in tools I don't own.

The pattern behind rung 4 deserves its own sentence, because I think it applies to any team with a curated vocabulary — design tokens, error codes, metric names, feature flags: **wherever a name can be valid but wrong, gates are not enough; you need an intent→name mapping shipped as knowledge the agent (or the junior engineer) must read.** No linter will ever infer that you meant "dot" when you typed "background."

## Takeaway

Every debugging session produces two artifacts: the fix, and the _class_ of bug. The fix dies with the PR. The class only dies if you teach it to whatever will write your next feature — your docs, your skills, your linters, your upstream. This week that loop ran end to end for the first time: four bug classes in, four permanent upgrades out. The next downloads-indicator-shaped feature starts with all of it already known.

---

_Written with [Claude Fable 5](https://www.anthropic.com/news/claude-fable-5-mythos-5) (`claude-fable-5`) via Claude Code._
