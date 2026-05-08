---
name: blog-publish
description: 'Promote a draft from _drafts/ to _posts/, commit, and push the blog repo. Use when the user wants to publish a blog post. Trigger: "publish blog", "publicar post", "promover draft", "push blog".'
---

# Blog Publish — Promote Draft → Posts → Push

Moves a draft from `_drafts/` to `_posts/`, commits, and pushes to GitHub Pages so it goes live on `jeanfbrito.github.io`.

## Workflow

### 1. Confirm scope

List available drafts and ask which one(s) to publish:

```bash
ls -la /home/jean/projects/jeanfbrito.github.io/_drafts/
```

If the user specified a particular post, skip the listing and go straight to it.

### 2. Move draft to posts

```bash
mv /home/jean/projects/jeanfbrito.github.io/_drafts/YYYY-MM-DD-<slug>.md \
   /home/jean/projects/jeanfbrito.github.io/_posts/YYYY-MM-DD-<slug>.md
```

### 3. Commit

```bash
cd /home/jean/projects/jeanfbrito.github.io && git add _posts/YYYY-MM-DD-<slug>.md
git commit -m "Publish: <title from front matter>"
```

Extract the title from the file's front matter for the commit message. Keep it under 60 chars.

### 4. Push

```bash
git push
```

### 5. Report back

Tell the user:
- Commit hash and message
- Live URL: `https://jeanfbrito.github.io/YYYY/MM/DD/<slug>.html`
- Note that GitHub Pages may take 1-2 minutes to deploy

## Edge cases

- **No drafts available:** tell the user the `_drafts/` directory is empty
- **Draft filename doesn't match date format:** warn the user — Jekyll requires `YYYY-MM-DD-slug.md`
- **Git has uncommitted changes in repo:** commit them first or ask the user
- **Push fails (auth, network):** stop and report the error
- **User wants to preview before publishing:** suggest `blog-preview` skill instead

## Safety

- **Never auto-push without confirming.** Show the file being promoted and ask for a quick "yes" unless the user explicitly said "just do it".
- **Never delete from `_drafts/` without moving first.** The `mv` command handles this atomically.
- **Never force push to main.** This is a public-facing repo.
