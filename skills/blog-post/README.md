# `blog-post` — Claude Code skill

A [Claude Code](https://docs.claude.com/en/docs/claude-code) skill that converts the current working session into a publishable draft post for this Jekyll Chirpy blog.

- **Trigger:** `/blog-post` (also: "blog this", "turn this into a post")
- **Output:** a draft Markdown file in [`_drafts/`](../../_drafts/) at the repo root
- **Never:** auto-publishes, auto-commits, or auto-pushes — drafts only, manual promotion via `mv _drafts/<slug>.md _posts/<slug>.md`

## How it works

The skill mirrors three patterns from skills I already use:

- **`/commit`** — uses [`context-mode`](https://github.com/jeanfbrito/context-mode) to keep raw transcript out of the main context window.
- **`/learn`** — classifies what's worth preserving (struggle / discovery / principle).
- **`/mm-extract`** — distills one session into one shaped artifact instead of a single ramble.

Output structure: hook → setup → what worked → pitfall → takeaway. Front matter is Chirpy-flavored.

## Privacy

Hard rules baked in. The skill refuses to publish anything from private/client repos, redacts paths and proper nouns, and surfaces a redaction log + uncertainty list with every draft so I can verify nothing was over-stripped (or under-stripped) before I promote.

## Wiring

The canonical skill lives here in this repo. Claude Code picks it up via a symlink:

```bash
ln -s /Users/jean/Github/jeanfbrito/skills/blog-post \
      ~/.claude/skills/blog-post
```

Edit `SKILL.md` here, and the next Claude Code session reads the update. The skill is excluded from the Jekyll build via `_config.yml`'s `exclude` list, so it does not render as a page.

See [`SKILL.md`](./SKILL.md) for the full skill definition.
