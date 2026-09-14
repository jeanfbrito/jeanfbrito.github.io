---
name: blog-cover
description: "Create a cover image for a jeanfbrito.github.io post using the agent's own image-generation tool, save it under assets, and set it as the post's Chirpy `image:` so the link preview and post header use it. Trigger: 'make a cover', 'cover image for this post', 'gera a capa', 'thumbnail for the post'. Only run when the user explicitly asks for a cover; never proactively."
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# /blog-cover — Cover Image for a Post

Produces one good cover for a draft or published post: builds a prompt from the post's actual
content, generates the image with **whatever image-generation tool this agent has** (Grok,
Codex, Gemini, Claude with an image tool, Hermes `image_generate`, etc.), crops it to the
1200x630 Open Graph frame, saves it under `assets/img/covers/`, and wires it into the post's
front matter. Chirpy then shows it as the post hero and as the `og:image` / `twitter:image`
link preview.

This skill does not call any API itself. If the agent running it has no image-generation
tool, stop at step 2 and say so.

**Only on explicit request.** Do not run this skill because a draft lacks an image, and do not
suggest it unprompted. The user asks for a cover; otherwise posts rely on the first body image
or the site avatar for previews.

**Never commit or push.** The user reviews the cover in the preview server first.

## Resolve the blog repo path

Same order as the other blog skills:

```bash
if [ -n "$JEANFBRITO_BLOG_REPO" ]; then
  BLOG_REPO="$JEANFBRITO_BLOG_REPO"
elif git -C "$HOME/Github/jeanfbrito" rev-parse --git-dir >/dev/null 2>&1; then
  BLOG_REPO="$HOME/Github/jeanfbrito"
elif [ -d "$HOME/projects/jeanfbrito.github.io" ]; then
  BLOG_REPO="$HOME/projects/jeanfbrito.github.io"
else
  echo "Blog repo not found."; exit 1
fi
```

## Workflow

### 1. Pick the post

If the user named a post, use it. Otherwise take the most recently modified file in `_drafts/`,
then `_posts/`. Confirm the choice in one line. `SLUG` is the filename without the
`YYYY-MM-DD-` prefix and `.md`.

If the front matter already has `image:`, say so and ask whether to replace it. Never
overwrite an existing cover file unless told to.

### 2. Confirm you can generate images

Use your native image-generation capability. Do not write curl calls, do not look for API
keys, do not draw a placeholder with ImageMagick, do not grab a stock image. If you have no
image tool, tell the user exactly that and stop; the rest of this skill is useless without one.

### 3. Build the prompt from the post

Read the post: title, `description`, the first two H2 sections, and the concrete nouns
(hardware, tools, data shapes, the thing that broke). The cover must come from what the post
is about, not from the title alone.

Assemble the prompt in this order, under 120 words:

1. **Subject**: one concrete visual metaphor for the post's core idea. Prefer objects and
   systems over people. Examples: a GPU die glowing under a magnifier for a benchmark post;
   a tangle of cables resolving into one clean line for a refactor; a film strip turning into
   a waveform for a transcript tool.
2. **Style** (fixed across posts, so the index reads as one publication):
   `editorial tech illustration, flat shading with subtle grain, isometric or three-quarter
   view, dark slate background, one accent color`. Pick the accent from the post's domain:
   amber for hardware, teal for tooling, violet for AI/ML, red for security.
3. **Composition**: `wide 16:9 frame, subject centered with generous negative space, clean
   edges, no clutter`. The image is center-cropped to 1200x630, so nothing important near
   the edges.
4. **Hard negatives**: `no text, no letters, no numbers, no logos, no watermarks, no UI
   screenshots, no photorealistic faces`. Generated text is always garbled and logos are a
   trademark risk.

Series posts (`gunfeel-03`, `seeing-recoil-2`): reuse the subject and accent of the earlier
part so the parts look related. Find the earlier prompt in that post's `image.alt` or in
`git log` for its cover.

Example prompt for a post about a YouTube-transcript CLI:

> Editorial tech illustration of a film strip unspooling from a small reel and turning into a
> clean audio waveform that flows into an open notebook page, teal accent on a dark slate
> background, flat shading with subtle grain, three-quarter view, wide 16:9 frame, subject
> centered with generous negative space, clean edges, no clutter. No text, no letters, no
> logos, no watermarks, no UI screenshots, no faces.

### 4. Generate

Ask your image tool for **two** candidates at 16:9 (or the widest landscape it offers) using
the same prompt. Save the raw files to a scratch location, then look at both. Pick the one
whose subject reads at thumbnail size and has no text artifacts. If both are weak, adjust the
prompt once and regenerate. Do not loop more than twice; show the user what you have and let
them decide.

### 5. Crop and save

Normalize the chosen image to the Open Graph frame and keep it light:

```bash
mkdir -p "$BLOG_REPO/assets/img/covers"
magick <chosen-raw> -resize 1200x630^ -gravity center -extent 1200x630 \
  -strip -interlace Plane -quality 82 "$BLOG_REPO/assets/img/covers/$SLUG.jpg"
ls -la "$BLOG_REPO/assets/img/covers/$SLUG.jpg"
```

Target under 300 KB. If larger, re-encode with `-quality 75`. If `magick` is missing, use
`sips -z 630 1200` on macOS as a fallback, or ask the user to `brew install imagemagick`.

### 6. Wire it into the post

Add to the post's front matter (Chirpy schema). Write a real `alt` describing what is in the
picture, not a repeat of the title:

```yaml
image:
  path: /assets/img/covers/<slug>.jpg
  alt: <what the illustration shows, one sentence>
```

Edit the front matter only; do not touch the body. If the post previously relied on the
first-body-image fallback for its link preview, the explicit `image:` now wins. That is
intended.

### 7. Verify in the preview

If a Jekyll server is listening on 4001, reuse it; otherwise start one per the `blog-preview`
skill (background, `--drafts`). Then confirm the meta tags and the hero picked it up:

```bash
curl -s "http://localhost:4001/posts/$SLUG/" \
  | grep -oE '<meta property="og:image" content="[^"]*"|class="preview-img[^"]*"'
```

Expected: `og:image` ends with `/assets/img/covers/<slug>.jpg` and one `preview-img` match.

### 8. Report back

1. Post URL on the preview server, first line: `http://localhost:4001/posts/<slug>/`
2. Cover path and file size
3. The prompt used, verbatim, so the user can ask for a variation
4. Reminder that nothing was committed; the cover ships with the post on `blog-publish`

## Edge cases

- **No image tool in this agent**: stop at step 2 and say so. Only acceptable failure.
- **Generation refused or errored**: show the tool's exact message, offer a toned-down prompt,
  do not retry blindly.
- **User supplies their own image**: skip step 4, run steps 5 to 8.
- **Cover exists and the user wants a new one**: save to `<slug>-new.jpg`, show both side by
  side, replace only on confirmation.
- **Post already has good screenshots**: `_plugins/auto-og-image.rb` uses the first body image
  for link previews automatically, so a cover is optional. Still make one when asked, or when
  the first screenshot makes a poor thumbnail.

## Related

- `blog-post` writes the draft; covers are added separately, only when asked.
- `blog-preview` serves the site for step 7.
- `blog-publish` ships the cover together with the post.
