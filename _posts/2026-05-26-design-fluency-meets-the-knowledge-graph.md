---
title: "Design Fluency Meets the Knowledge Graph"
date: 2026-05-26 16:23:40 -0300
categories: [AI, Tooling]
tags: [design-systems, electron, fuselage, knowledge-graph, agent-skills, refactoring, ux]
description: "Polishing an Electron app's UI with an AI design skill on the front and a code knowledge graph on the back: design vocabulary plus a real source of truth."
pin: false
math: false
mermaid: false
---

Good UI work happens fastest when two things are true at once: the AI you are working with understands what the design is supposed to *be*, and it understands the codebase well enough to move with confidence. I spent a session polishing the settings, certificates, and downloads surfaces of an Electron desktop app, and the standout was the pairing of two tools that each nailed one of those halves. One gave the AI a real design vocabulary. The other gave it the truth about the code. Together they made the whole thing smooth.

## The setup

The app is an Electron desktop shell built on React and the [Fuselage design system](https://github.com/RocketChat/fuselage). Three full-window surfaces were on the table: a Settings view, a Certificates manager, and a Downloads view. The goal was straightforward: bring them fully in line with the design system and make them feel like one coherent, polished product.

I paired two tools for it. A design skill to set the direction, and a code knowledge graph to navigate and verify.

## What worked: a design skill that captures the direction first

The front half was [Impeccable](https://impeccable.style/), an agent skill that teaches the AI real design knowledge and gives you a set of commands to steer the result. The part I loved was how it starts: with context, not pixels.

Its `teach` flow runs a short interview before any design work: who uses this, what is the register (is the design *the* product, or does it *serve* a task?), what is the brand personality, what aesthetic direction fits. The answers land in two committed files, `PRODUCT.md` and `DESIGN.md`, and every later command reads them.

For this app the answers were clear and useful. Users: people who keep the app open all day, often in regulated environments. Register: product, the chrome should recede so the workspace shines. A handful of crisp principles fell out of that: density without clutter, native per platform, trust through restraint, Fuselage first.

Writing it down sharpened everything downstream. "Polish the settings view" gained a north star to measure against, so every decision had a reason behind it. The skill turned a vague request into a set of concrete, on-brand moves, and it kept the three surfaces consistent with each other because they all read from the same `DESIGN.md`.

## What worked: a knowledge graph as the source of truth

The back half was GitNexus, a code knowledge graph. You point it at a repo, it indexes the symbols and the relationships between them, and you can ask structural questions: what calls this, what depends on it, where is this actually defined.

Two uses paid off beautifully.

**Impact analysis before each edit.** Before touching a component I asked the graph for its upstream blast radius. Each surface came back clean and low risk, leaf-level view components with the dependency picture laid out explicitly. That changes how the work feels. Instead of reading three files to talk yourself into a change being safe, you get a direct answer and keep moving. The confidence is the feature.

**Indexing the design system itself.** This is the move I would repeat on any project that builds on a shared UI library. I indexed the Fuselage source and read the real, semantic design tokens straight from it: the exact colors the runtime emits, the type scale, the spacing steps, the component variants that actually exist. `DESIGN.md` stopped being a plausible guess and became something anchored to the design system's own source of truth. Every color the polish touched went through a verified semantic token, every spacing value snapped to the system scale, and the type hierarchy followed Fuselage's published steps.

## The good effects

With both halves in place, the polish went quickly and held together.

The Settings view gained labeled sections, grouping its options into clear areas instead of one long run, reusing a section pattern the app already had. The Downloads and Certificates lists picked up a single shared row treatment: a clean divider and a hover highlight, both reading from theme tokens, so it is obvious which row you are about to act on. Keyboard users got Escape-to-close and proper labels on the icon buttons. Primary and destructive actions read at a glance. The headings stepped to a calmer scale that suits a tool you live in all day.

Best of all, it is consistent. Three surfaces, one vocabulary, one set of tokens, all themed correctly across light, dark, and high-contrast. The chrome recedes exactly as the design direction asked it to, and the code underneath references the design system honestly rather than approximating it.

## What it looked like in code

The nice thing about having `DESIGN.md` loaded and the design system indexed is that the resulting code reads like the design system intended. A few concrete examples from the session.

**Grouping the settings into sections.** The Settings tab holds a couple of dozen toggles. With the design direction captured, the obvious move was a small reusable `Section` helper using Fuselage's own type scale and spacing steps, then composing the surface out of named groups:

```tsx
const Section = ({ title, isFirst, children }: SectionProps) => (
  <Box mbs={isFirst ? 0 : 32} mbe={16}>
    <Box fontScale='h4' color='font-default' mbe={16}>
      {title}
    </Box>
    <FieldGroup>{children}</FieldGroup>
  </Box>
);

export const GeneralTab = () => (
  <Box is='form' maxWidth={600} width='full'>
    <Section title={t('settings.sections.notifications')} isFirst>
      <ReportErrors />
      <FlashFrame />
    </Section>
    <Section title={t('settings.sections.performance')}>
      <HardwareAcceleration />
      {process.platform === 'win32' && <ScreenCaptureFallback />}
    </Section>
    {/* ...calls & video, window & appearance, integrations */}
  </Box>
);
```

Every value here is a design-system value: `fontScale='h4'` instead of a pixel size, `color='font-default'` instead of a hex, `mbs={32}` and `mbe={16}` on the system spacing scale. Nothing invented.

**A shared row treatment for the lists.** The Downloads and Certificates views are both scrollable lists where you click actions per row. They got the same affordance: a one-pixel divider and a hover tint, both reading from theme tokens so they resolve correctly in every theme.

```tsx
const rowStyles = css`
  border-block-start: 1px solid var(--rcx-color-stroke-extra-light, transparent);
  transition: background-color 120ms ease-out;
  &:first-of-type {
    border-block-start: none;
  }
  &:hover {
    background-color: var(--rcx-color-surface-hover, transparent);
  }
`;
```

For the certificate table the same effect comes from a single Fuselage prop, since the table component already knows how to do it:

```tsx
<TableRow key={url} action>
  {/* cells */}
</TableRow>
```

The `action` prop lights up the row on hover with the same `surface-hover` token. One affordance, two surfaces, zero hand-rolled colors.

**Action buttons that are actually buttons.** Per-row actions now use the Fuselage `Button` primitive, which carries the right semantics, focus behavior, and a `danger` styling for destructive actions:

```tsx
const ActionButton = (props: ComponentProps<typeof Button>) => (
  <Button small secondary {...props} />
);

// destructive actions opt into the danger styling:
<ActionButton danger onClick={handleRemove}>
  {t('downloads.item.remove')}
</ActionButton>
```

**Colors through semantic tokens, everywhere.** The cleanup pass swept every color reference onto the semantic token names the design system actually emits, so a metadata line reads its color by role rather than by palette position:

```tsx
<Box color='font-secondary-info' fontScale='c1' withTruncatedText>
  {serverTitle}
</Box>
```

That last one is the small habit that pays off later: when the theme changes, or the design system retunes a value, every surface follows automatically because nothing hardcoded a number.

## Staying current as Fuselage moves

This is the part I am most happy about, because it pays forward. The design system ships new versions: a token gets retuned, a new surface role appears, a spacing step shifts, a component gains a variant. With the UI anchored to semantic tokens and the design system indexed, keeping up with those releases becomes a light, repeatable task instead of a hunt.

When a new Fuselage version lands, the workflow is short:

1. Bump the dependency and re-index the design system source, so the knowledge graph reflects the new tokens, scales, and component APIs.
2. Re-run the document step so `DESIGN.md` refreshes from the new source of truth. Any value that moved shows up as a diff against the captured contract, which makes the change reviewable rather than invisible.
3. Because the app reads semantic tokens (`color='font-secondary-info'`, `fontScale='h4'`, `var(--rcx-color-surface-hover)`), most visual updates simply flow through. A retuned color or spacing step arrives for free, in every theme, with no edits.
4. For the rare structural change, a renamed token or a new component variant, the knowledge graph points straight at every place that touches it, so the update is targeted and the impact is known before a single line changes.

The combination means the gap between "Fuselage released something" and "our UI reflects it" stays small, and closing it never requires re-deriving the design from screenshots. The contract is written down, the source is indexed, and the code already trusts both.

## Best practices for this workflow

A few habits that made the design-skill-plus-knowledge-graph pairing work, worth keeping for any project that builds on a shared design system:

- **Capture direction before pixels.** Run the `teach` step first and commit `PRODUCT.md` and `DESIGN.md`. A captured audience, register, and set of anti-references is what turns a vague "polish this" into concrete, on-brand decisions.
- **Anchor `DESIGN.md` to the design system's source, not the app's fallbacks.** Read the real semantic tokens the runtime emits. The values you find hardcoded in an app are often pre-hydration backstops, not the live contract.
- **Index the design system, not just your app.** The biggest leverage came from querying the library's own source for exact tokens, scales, and the component variants that actually exist in the version you ship.
- **Reference tokens by role, never by raw value.** `color='font-default'`, `fontScale='h4'`, `var(--rcx-color-surface-hover)`. Role-based references survive theme changes and design-system retunes; hardcoded hex and pixel values do not.
- **Run impact analysis before editing shared components.** Knowing the blast radius up front turns a nervous refactor into a confident one, and catches the surfaces you would not have thought to open.
- **Verify every theme.** If the design system ships light, dark, and high-contrast, check all of them. Token-based code makes this nearly automatic, but it is still worth confirming.
- **Prefer the design system's primitive over a hand-rolled one.** A single `action` prop or a `Button` variant carries the right semantics, focus behavior, and theming that a custom element has to reinvent.
- **Keep one affordance per concept.** One row-hover treatment, one selection cue, one destructive-action style, reused across surfaces. Consistency is the feature; reuse is how you get it.
- **Re-index after each design-system bump.** Make refreshing the graph and `DESIGN.md` part of the upgrade routine so the captured contract never drifts from reality.

## Takeaway

Great AI design work is a two-sided problem, and the magic is covering both sides at once. A design skill on the front gives the AI taste with grounding: a captured direction, a shared vocabulary, a north star to measure against. A knowledge graph on the back gives it confidence and accuracy: real impact analysis before edits, and design tokens read straight from the design system's source. Put them together and the surfaces come out coherent, on-brand, and genuinely polished, with a workflow that stays calm the whole way through.

---

*Written with [Claude Opus 4.7](https://www.anthropic.com/claude) (`claude-opus-4-7`) via Claude Code.*
