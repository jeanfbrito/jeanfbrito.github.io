---
name: blog-publish
description: Promote a draft from _drafts/ to _posts/, commit, and push the blog repo. Use when the user wants to publish a blog post. Trigger: "publish blog", "publicar post", "promover draft", "push blog".
allowed-tools: Bash, Read
---

# Blog Publish — Promote Draft → Posts → Push

Moves a draft from `_drafts/` to `_posts/`, commits, and pushes to GitHub Pages so it goes live on `jeanfbrito.github.io`.

## Resolve the blog repo path

At the start of every run, resolve the blog repo path in this order:

1. Use `$JEANFBRITO_BLOG_REPO` if set in the environment.
2. Check if `~/Github/jeanfbrito` exists and is a git repo (`git -C ~/Github/jeanfbrito rev-parse --git-dir 2>/dev/null`).
3. Check if `~/projects/jeanfbrito.github.io` exists.
4. If none of the above resolves, stop and ask the user for the path.

```bash
if [ -n "$JEANFBRITO_BLOG_REPO" ]; then
  BLOG_REPO="$JEANFBRITO_BLOG_REPO"
elif git -C "$HOME/Github/jeanfbrito" rev-parse --git-dir >/dev/null 2>&1; then
  BLOG_REPO="$HOME/Github/jeanfbrito"
elif [ -d "$HOME/projects/jeanfbrito.github.io" ]; then
  BLOG_REPO="$HOME/projects/jeanfbrito.github.io"
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

### 1b. Guard against a future date

Jekyll silently drops posts dated after build time (`Skipping: ... has a future date`), so a
draft with a future `date:` would publish as a commit but never appear on the live site. Check
before moving:

```bash
POST_DATE=$(grep -m1 -E "^date:" "$BLOG_REPO/_drafts/YYYY-MM-DD-<slug>.md" | sed 's/^date: *//')
POST_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$POST_DATE" +%s 2>/dev/null || date -d "$POST_DATE" +%s)
[ "$POST_EPOCH" -le "$(date +%s)" ] && echo "date ok" || echo "FUTURE DATE: $POST_DATE"
```

If it prints `FUTURE DATE`, stop. Re-stamp `date:` with the current time
(`TZ=America/Sao_Paulo date '+%Y-%m-%d %H:%M:%S %z'`), rename the file if the day changed, and
re-run the check. Also confirm the filename's `YYYY-MM-DD` prefix matches the `date:` day.

### 2. Move draft to posts

```bash
mv "$BLOG_REPO/_drafts/YYYY-MM-DD-<slug>.md" \
   "$BLOG_REPO/_posts/YYYY-MM-DD-<slug>.md"
```

### 3. Commit

```bash
cd "$BLOG_REPO" && git add "_posts/YYYY-MM-DD-<slug>.md"
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
- Live URL: `https://jeanfbrito.github.io/posts/<slug>/` (Chirpy permalink is `/posts/:title/`; the slug is the filename without the date prefix)
- Note that GitHub Pages may take 1-2 minutes to deploy

## Edge cases

- **No drafts available:** tell the user the `_drafts/` directory is empty
- **Draft filename doesn't match date format:** warn the user — Jekyll requires `YYYY-MM-DD-slug.md`
- **Draft has a future `date:`:** never publish it as-is; re-stamp with the current time (step 1b)
- **Git has uncommitted changes in repo:** commit them first or ask the user
- **Push fails (auth, network):** stop and report the error
- **User wants to preview before publishing:** suggest `blog-preview` skill instead

## Safety

- **Never auto-push without confirming.** Show the file being promoted and ask for a quick "yes" unless the user explicitly said "just do it".
- **Never delete from `_drafts/` without moving first.** The `mv` command handles this atomically.
- **Never force push to main.** This is a public-facing repo.

---

Adapted for Claude Code from the Hermes Agent skill at `skills/hermes/blog-publish/SKILL.md`. Substance is the same; only paths, platform commands, and tool names changed.
