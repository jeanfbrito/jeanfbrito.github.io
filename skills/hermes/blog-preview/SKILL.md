---
name: blog-preview
description: Start the Jekyll development server for jeanfbrito.github.io with drafts visible. Use when the user wants to preview blog posts locally before publishing. Trigger: "preview blog", "rodar blog", "ver o blog local", "serve blog".
---

# Blog Preview — Serve Jekyll with Drafts

Starts the Jekyll development server for `jeanfbrito.github.io` so the user can preview posts and drafts in the browser.

## Workflow

1. **Check for existing server** — if port 4001 is already listening on a ruby3.2 process, tell the user it is already running and give the URL. Skip the rest.

   ```bash
   sudo ss -tlnp | grep 4001
   ```

2. **Check port availability** — Docker proxy often occupies port 4000. Use **port 4001** by default. If 4001 is also occupied, try 4002.

   ```bash
   sudo ss -tlnp | grep 4001 || echo "available"
   ```

3. **Start Jekyll** — run in background with drafts enabled:

   ```bash
   cd /home/jean/projects/jeanfbrito.github.io && BUNDLE_PATH=vendor/bundle bundle exec jekyll s --drafts --host 0.0.0.0 --port 4001
   ```

   Use `terminal(background=true)` — do NOT run foreground.

4. **Wait and verify** — poll the background process until it reports the server is listening, then confirm with a curl:

   ```bash
   curl -s -o /dev/null -w "%{http_code}" http://localhost:4001/
   ```

5. **Get LAN IP and report back** to the user:

   ```bash
   hostname -I | awk '{print $1}'
   ```

   Tell the user:
   - Local URL: `http://localhost:<port>/`
   - LAN URL: `http://<ip>:<port>/`
   - Drafts are visible (they will NOT appear on the published GitHub Pages site)
   - The server stays running until killed

## Edge cases

- **bundle not installed:** `sudo apt install -y ruby-bundler`, then `cd repo && bundle install --path vendor/bundle`
- **Port in use by Docker proxy:** switch to 4001 (or next available)
- **Server already running:** just give the URL, don't start another instance
- **Blog repo missing:** stop and tell the user
