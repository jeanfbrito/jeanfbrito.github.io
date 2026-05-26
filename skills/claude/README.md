# Claude Code Skills

This directory contains blog-management skills for [Claude Code](https://claude.ai/code), adapted from the Hermes Agent skills in `skills/hermes/`.

## Structure

```
skills/claude/
├── blog-post/       # Write blog post drafts from session knowledge
├── blog-preview/    # Start local Jekyll preview with drafts
├── blog-publish/    # Promote draft → posts → commit → push
└── README.md        # This file
```

## Install

Claude Code auto-detects skills placed under `~/.claude/skills/`. Symlink from inside the cloned blog repo:

```bash
ln -s "$(pwd)/skills/claude/blog-post"    ~/.claude/skills/blog-post
ln -s "$(pwd)/skills/claude/blog-preview" ~/.claude/skills/blog-preview
ln -s "$(pwd)/skills/claude/blog-publish" ~/.claude/skills/blog-publish
```

Skills are picked up on the next Claude Code session. If the harness loads them live, you can invoke `/blog-post`, `/blog-preview`, and `/blog-publish` immediately.

Pulling repo updates keeps the symlinks fresh — no resync needed.

## Blog repo detection

All three skills auto-detect the blog repo at runtime (no hardcoded path). Resolution order:

1. `$JEANFBRITO_BLOG_REPO` env var if set
2. `~/Github/jeanfbrito` if it exists and is a git repo
3. `~/projects/jeanfbrito.github.io` if it exists
4. Ask the user

Set `JEANFBRITO_BLOG_REPO` in your shell profile if you keep the repo in a non-standard location.
