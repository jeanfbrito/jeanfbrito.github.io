---
name: blog-publish
description: 'Promote a draft from _drafts/ to _posts/, commit, and push the blog repo. Use when the user wants to publish a blog post. Trigger: "publish blog", "publicar post", "promover draft", "push blog".'
---

# Blog Publish — Promote Draft → Posts → Push

Moves a draft from `_drafts/` to `_posts/`, commits, and pushes to GitHub Pages so it goes live on `jeanfbrito.github.io`.

## Resolve the blog repo path

At the start of every run, resolve the blog repo path in this order:

1. Use `$JEANFBRITO_BLOG_REPO` if set in the environment.
2. Check if `~/projects/jeanfbrito.github.io` exists (historical Hermes path).
3. Check if `~/Github/jeanfbrito` exists and is a git repo.
4. If none of the above resolves, stop and ask the user for the path.

```bash
if [ -n "$JEANFBRITO_BLOG_REPO" ]; then
  BLOG_REPO="$JEANFBRITO_BLOG_REPO"
elif [ -d "$HOME/projects/jeanfbrito.github.io" ]; then
  BLOG_REPO="$HOME/projects/jeanfbrito.github.io"
elif git -C "$HOME/Github/jeanfbrito" rev-parse --git-dir >/dev/null 2>&1; then
  BLOG_REPO="$HOME/Github/jeanfbrito"
else
  echo "Blog repo not found. Set JEANFBRITO_BLOG_REPO or clone jeanfbrito.github.io first."
  exit 1
fi
```

## Workflow

### 1. Confirm scope

List available drafts and ask which one(s) to publish:

```bash
ls -la "$BLOG_REPO/_drafts/"
```

If the user specified a particular post, skip the listing and go straight to it.

### 2. Verify the post date is not in the future

**BLOCKING CHECK.** Read the `date:` line from the draft's front matter and compare against the shell. If the front-matter date is greater than `date "+%Y-%m-%d %H:%M:%S %z"`, Jekyll silently drops the post (this site has no `--future` flag in `_config.yml`) and it won't render on GitHub Pages until that timestamp passes. The user has been bitten by this twice — do not skip.

```bash
NOW=$(date "+%Y-%m-%d %H:%M:%S %z")
POST_DATE=$(grep -m1 '^date:' /home/jean/projects/jeanfbrito.github.io/_drafts/YYYY-MM-DD-<slug>.md | sed 's/^date:[[:space:]]*//')
echo "now:  $NOW"
echo "post: $POST_DATE"
# If post > now: edit the draft's date: line to NOW verbatim BEFORE the move/commit/push.
# Do not "round" or "add buffer" — copy the shell output as-is.
```

If the date is in the future, edit the draft's `date:` field to the current shell timestamp before continuing. Mention the correction in your final report.

### 3. Move draft to posts

```bash
mv "$BLOG_REPO/_drafts/YYYY-MM-DD-<slug>.md" \
   "$BLOG_REPO/_posts/YYYY-MM-DD-<slug>.md"
```

### 4. Commit

```bash
cd "$BLOG_REPO" && git add "_posts/YYYY-MM-DD-<slug>.md"
git commit -m "Publish: <title from front matter>"
```

Extract the title from the file's front matter for the commit message. Keep it under 60 chars.

### 5. Push

```bash
git push
```

### 6. Report back

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
