---
name: blog-preview
description: 'Start the Jekyll development server for jeanfbrito.github.io with drafts visible. Use when the user wants to preview blog posts locally before publishing. Trigger: "preview blog", "rodar blog", "ver o blog local", "serve blog".'
---

# Blog Preview — Serve Jekyll with Drafts

Starts the Jekyll development server for `jeanfbrito.github.io` so the user can preview posts and drafts in the browser.

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

### 1. Check for existing server

If port 4001 is already listening, tell the user it is already running and give the URL. Skip the rest.

Pick the check command for the current OS:

```bash
case "$(uname -s)" in
  Linux)
    # ss is part of iproute2, available on all modern Linux distros
    ss -tlnp | grep 4001
    ;;
  Darwin)
    # lsof works without sudo on macOS
    lsof -nP -iTCP:4001 -sTCP:LISTEN
    ;;
esac
```

If the command returns output, the server is already running — report the URL and stop.

### 2. Check port availability

Docker proxy often occupies port 4000. Use **port 4001** by default. If 4001 is also occupied (same check as above returns output), try 4002.

### 3. Start Jekyll in the background

Use `terminal(background=true)` — do NOT run foreground. This is the Hermes equivalent of Claude Code's `Bash(run_in_background=true)`.

```bash
cd "$BLOG_REPO" && BUNDLE_PATH=vendor/bundle bundle exec jekyll s --drafts --host 0.0.0.0 --port 4001
```

### 4. Wait and verify

Poll until Jekyll is ready, then confirm with a curl:

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:4001/
```

A `200` response confirms the server is up.

### 5. Get LAN IP and report back

Pick the command for the current OS:

```bash
case "$(uname -s)" in
  Linux)
    hostname -I | awk '{print $1}'
    ;;
  Darwin)
    # Try en0 first (Wi-Fi), fall back to en1
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null
    ;;
esac
```

Tell the user:
- Local URL: `http://localhost:<port>/`
- LAN URL: `http://<ip>:<port>/`
- Drafts are visible (they will NOT appear on the published GitHub Pages site)
- The server stays running until killed

## Edge cases

- **bundler not installed:**

  ```bash
  case "$(uname -s)" in
    Linux)
      sudo apt install -y ruby-bundler
      cd "$BLOG_REPO" && bundle install --path vendor/bundle
      ;;
    Darwin)
      # Modern Ruby from Homebrew includes bundler; no sudo needed
      brew install ruby
      cd "$BLOG_REPO" && bundle install --path vendor/bundle
      ;;
  esac
  ```

- **Port in use by Docker proxy:** switch to 4001 (or next available)
- **Server already running:** just give the URL, don't start another instance
- **Blog repo missing:** stop and tell the user
