# Hermes Agent Skills

This directory contains custom skills for [Hermes Agent](https://github.com/Hermes/hermes-agent) that are synced to the blog repository and linked back via symlinks from `~/.hermes2/skills/`.

## Structure

```
skills/hermes/
├── blog-post/       # Write blog posts from session knowledge
├── blog-preview/    # Start local Jekyll preview with drafts
├── blog-publish/    # Promote draft → posts → commit → push
└── README.md        # This file
```

## How it works

Each skill lives as a regular directory under `skills/hermes/`. On the local machine, Hermes loads skills from `~/.hermes2/skills/`, so **symlinks** connect the two:

```bash
~/.hermes2/skills/blog-post    →  ~/projects/jeanfbrito.github.io/skills/hermes/blog-post
~/.hermes2/skills/blog-preview →  ~/projects/jeanfbrito.github.io/skills/hermes/blog-preview
~/.hermes2/skills/blog-publish →  ~/projects/jeanfbrito.github.io/skills/hermes/blog-publish
```

This means:
- **Editing skills on this machine:** edit inside the repo (`skills/hermes/<skill>/SKILL.md`) — changes are immediately reflected via the symlink
- **Pulling changes from GitHub:** the symlink target stays in sync with the repo
- **Fresh setup on another machine:** clone the repo, then create symlinks pointing from `~/.hermes2/skills/<name>` to `<repo>/skills/hermes/<name>`

## Skills

### blog-post
Writes a polished engineering blog post draft based on the current session or a user-provided topic. Follows Chirpy Jekyll front matter format and applies strict privacy redaction rules. See `skills/hermes/blog-post/SKILL.md` for the full workflow.

### blog-preview
Starts `bundle exec jekyll s --drafts` on port 4001 (avoiding Docker proxy on port 4000). Reports local and LAN URLs for browser preview.

### blog-publish
Moves a draft from `_drafts/` to `_posts/`, commits with the article title, and pushes to GitHub Pages.

## Creating a symlink on a new machine

```bash
# From inside the cloned blog repo
ln -s $(pwd)/skills/hermes/blog-post    ~/.hermes2/skills/blog-post
ln -s $(pwd)/skills/hermes/blog-preview ~/.hermes2/skills/blog-preview
ln -s $(pwd)/skills/hermes/blog-publish ~/.hermes2/skills/blog-publish
```

Or use the setup script if one is provided.
