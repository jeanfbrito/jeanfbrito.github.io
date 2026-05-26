---
name: blog-post
description: Convert a session, experiment, or benchmark into a publishable engineering blog post draft for jeanfbrito.github.io (Jekyll Chirpy). Trigger when the user says "blog this", "turn this into a post", "write this up for the blog", or asks to document something as a blog article. Produces a draft saved into the blog repo's _drafts/ directory so the user can review before publishing. Strips private/proprietary content, keeps reusable code, commands, and lessons.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# /blog-post — Session Knowledge → Blog Draft

Trigger: "blog this", "turn this into a post", "write up for blog", "escreve um blog post sobre..."

When invoked, distill the session or topic into a publishable draft for the user's Jekyll Chirpy blog at `https://jeanfbrito.github.io`. Output goes to `_drafts/` in the blog repo so the user reviews and publishes manually. **Never auto-publish. Never auto-commit. Never push.**

## Resolve the blog repo path

At the start of every run, resolve the blog repo path in this order:

1. Use `$JEANFBRITO_BLOG_REPO` if set in the environment.
2. Check if `~/Github/jeanfbrito` exists and is a git repo (`git -C ~/Github/jeanfbrito rev-parse --git-dir 2>/dev/null`).
3. Check if `~/projects/jeanfbrito.github.io` exists.
4. If none of the above resolves, stop and ask the user for the path.

In all shell commands below, substitute the resolved path for `$BLOG_REPO`. Do not hardcode `/home/jean` or `/Users/jean`.

```bash
# Resolution snippet — run once at start
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

## Hard rules — privacy

The user works at Rocket.Chat and on closed-source/client projects. Treat every transcript as potentially leaky. **A draft that leaks anything proprietary is worse than no draft.**

**NEVER include in the draft:**

- API keys, tokens, passwords, secrets, env values, signed URLs
- Internal hostnames, IPs, internal repo URLs, JIRA ticket IDs, Slack channels, customer/employer/client names beyond Rocket.Chat-public-OSS work
- Code from private repos (Rocket.Chat private monorepo packages, client codebases). OSS Rocket.Chat OK if already public on GitHub.
- File paths that reveal employer or client (e.g. anything under employer-specific directories)
- Proprietary algorithms, internal architecture, schemas
- Real names of coworkers, customers, or third parties (Jean Brito as author = OK)
- Stack traces or logs that reveal internal infrastructure

**Always allowed:**

- The user's own personal projects (jeanfbrito/* repos), OSS contributions, public blog tooling
- Generic shell commands, Claude Code skill patterns, Jekyll/Chirpy config, public docs URLs
- High-level lessons (e.g. "context-mode keeps diffs out of the window" — pattern, not secret)
- Code snippets the user authored that contain no proprietary logic
- Local LLM experiments, benchmarks, hardware reviews (RTX 3090, llama-swap, etc.)

When in doubt, redact with `[REDACTED]` or paraphrase, AND surface it in the post-write report so the user can decide.

## Workflow

### 1. Confirm scope

Before doing anything else, ask the user one short question (only if not already obvious from the trigger phrase):

> "Qual parte dessa sessão você quer transformar em post?
> a) Tudo desde o início da sessão
> b) Só a tarefa mais recente: <nomear última tarefa concluída>
> c) Um tópico específico: <perguntar>"

Default to (b) if user just said "blog this" with no qualifier and a clearly bounded recent task exists.

### 2. Verify blog repo state

```bash
ls "$BLOG_REPO/_drafts/" 2>/dev/null || mkdir -p "$BLOG_REPO/_drafts/"
```

Drafts dir must exist. Chirpy renders `_drafts/` only when running with `--drafts`, which is what we want — invisible until promoted.

### 3. Capture session context

If the user has already extracted lessons or data in this session, prefer those — they are already structured summaries.

Otherwise, build context from the conversation directly. For long sessions, use context-mode tools to extract relevant portions:

```
mcp__plugin_context-mode_context-mode__ctx_batch_execute(
  commands: [
    {label: "git-log-blog", command: "git -C \"$BLOG_REPO\" log --oneline -20"},
    {label: "git-status-blog", command: "git -C \"$BLOG_REPO\" status"},
    {label: "existing-posts", command: "ls \"$BLOG_REPO/_posts/\" \"$BLOG_REPO/_drafts/\" 2>/dev/null"}
  ]
)
```

For follow-up specifics use `mcp__plugin_context-mode_context-mode__ctx_search` with targeted queries.

### 4. Extract narrative

From the session, identify in this order:

1. **The problem** — what triggered the work? One concrete sentence.
2. **The approach** — what strategy/tools were chosen, and why.
3. **The key steps** — 3–6 substantive moments. Include exact commands, code, file diffs that are *generic enough to share*.
4. **The pitfall(s)** — what went wrong, what was unintuitive, what cost time. This is the most valuable section for readers — never skip if it exists.
5. **The takeaway** — one transferable lesson. What should another engineer remember?

If fewer than two of {problem, approach, pitfall, takeaway} have non-trivial content, **stop and tell the user**: "this session does not have enough narrative for a blog post — try /learn or /mm-extract instead."

### 5. Privacy pass

Run a redaction sweep over every command, code block, path, and proper noun before writing the file:

- Replace any path containing `Rocket Engineering`, employer-specific directories, or client tokens with a generic placeholder
- Strip any Rocket.Chat internal URLs (anything not on github.com/RocketChat public repos)
- Replace customer/coworker names with role descriptors ("a teammate", "a customer")
- Scan code blocks for hardcoded secrets — refuse to include them, redact and warn
- If the session touched a private repo and the post leans on that work, the post should describe the *technique*, not the codebase

### 6. Write the draft

Path: `$BLOG_REPO/_drafts/YYYY-MM-DD-<slug>.md`

Slug: kebab-case, max 6 words, descriptive. Date: today (the user is in `America/Sao_Paulo`).

Front matter (Chirpy):

```yaml
---
title: <Concrete, specific, no clickbait. Under 60 chars.>
date: YYYY-MM-DD HH:MM:SS -0300
categories: [<top-level>, <sub>]   # 1–2 entries, e.g. [AI, Tooling]
tags: [<5–8 lowercase tags>]
description: <140–160 char summary for SEO/social>
pin: false
math: false
mermaid: false
---
```

Body structure (use H2 for sections):

```markdown
<one-paragraph hook stating the concrete problem>

## The setup

<context the reader needs — what was being built, why it mattered, what was tried first if relevant>

## What worked

<the actual approach, with code/commands. Use fenced blocks with language tags. Real commands the reader can copy.>

## Where it almost went sideways

<the pitfall(s). This is the gold. Be honest about the wrong turns.>

## Takeaway

<one or two sentences another engineer can carry to their own work>

---

<model attribution footer — see step 7>
```

**Style guide:**

- 1200–2200 words is the sweet spot. Cut ruthlessly under 1200; split if over 2500.
- Paragraphs 2–5 sentences. Use H2/H3 for skim-ability.
- Imperative voice in commands ("Run X", not "You should run X").
- First person singular ("I") is fine — it is the user's blog.
- Code fences must specify language (` ```bash `, ` ```yaml `, ` ```ts `).
- Quote errors verbatim inside backticks.
- Link to public docs/sources when claiming behavior.
- No emoji unless the user already used them in the session.
- One model attribution footer at the very end (see step 7). No other "generated by" lines anywhere in the body.

### Inter-post links (critical — breaks CI if wrong)

The blog uses `permalink: /posts/:title/` in `_config.yml`. A post named `2026-04-28-rtx-3090-power-limit-sweet-spot.md` renders at `/posts/rtx-3090-power-limit-sweet-spot/` — **not** at the raw `.md` filename.

**Always use Jekyll's `{% post_url %} tag for links between posts.** It survives slug/title changes and is what CI validates:

```markdown
[RTX 3090 Power Limit]({% post_url 2026-04-28-rtx-3090-power-limit-sweet-spot %})
```

The argument to `{% post_url %}` is the **filename without .md** (the full `YYYY-MM-DD-slug` part).

**NEVER use relative paths like `./2026-04-28-xxx.md` or `/2026-04-28-xxx/`.** These work in local preview but break htmlproofer in CI because the rendered path follows the permalink format, not the filename.

For cross-linking to drafts (not yet published): still use `{% post_url %}` — Jekyll resolves it correctly during `--drafts` preview.

### 7. Append model attribution

Every draft ends with a single italic line below a horizontal rule that names the model and version that wrote it. This is for transparency with readers and so future sessions running this skill on different models behave consistently.

**Identify the running model from the runtime context.** Sources, in order of preference:

1. The system prompt or environment string the harness gave you at session start (it usually states the model family, friendly name, and exact model id).
2. The provider SDK / CLI you are running inside (`claude`, `ollama`, `llama.cpp`, `vllm`, `lm-studio`, `openrouter`, etc.).
3. If genuinely unknown, write `[unknown model]` and surface this in the uncertainty list — do not invent a name.

**Footer format by model class:**

- **Hosted closed-source** (Claude, GPT-x, Gemini, Grok, etc.):

  ```markdown
  ---

  *Written with [<Friendly Name>](<provider model page URL>) (`<exact-model-id>`) via <runtime>.*
  ```

- **Open-weights / locally hosted** (Llama, Qwen, DeepSeek, Mistral-Open, etc., served via llama-swap, Ollama, llama.cpp, vLLM, LM Studio, MLX, etc.):

  ```markdown
  ---

  *Written with [<Model Name + size/quant>](<HuggingFace model page URL>) via <runtime>.*
  ```

  Example for a local setup:

  ```markdown
  ---

  *Written with [Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B) (GGUF via [unsloth/Qwen3.6-27B-GGUF](https://huggingface.co/unsloth/Qwen3.6-27B-GGUF)) on RTX 3090 @ 280W through llama-swap v199.*
  ```

  Use the **canonical HuggingFace repo** of the model (the org's official upload, not a re-quant), unless the runtime is loading a specific quantization repo — in that case link the quant repo and mention the quant level (e.g. `Q4_K_M`).

- **Hosted open-weights via API** (OpenRouter, Together, Groq serving Llama/Qwen, etc.): link the HuggingFace page for the underlying model and add the hosting provider in the runtime slot.

**Rules for any model:**

- One line. Italic. Below a single `---` horizontal rule on its own line.
- The model name links somewhere a reader can verify it exists.
- For local GGUF models: include both the original HF link AND the GGUF repo link, plus hardware + inference engine.
- The exact model id (or quant suffix) goes in backticks if it differs meaningfully from the friendly name.
- The runtime is the agent harness or inference server the user actually ran (`Claude Code`, `llama-swap`, `Ollama`, `llama.cpp`, `vLLM`, `LM Studio`, `OpenRouter`, etc.) — not a generic word like "AI" or "LLM".
- No co-author line. No "Generated by". No emoji. The footer is a fact line, not a brag line.

### 8. Report back

After writing, output to the user:

1. The draft path: `_drafts/YYYY-MM-DD-<slug>.md`
2. Word count
3. **Redaction log**: any line/section where you replaced or omitted content, so the user can verify nothing was over-stripped
4. **Uncertainty list**: anything you weren't sure was safe to publish — flagged for the user to decide
5. Suggested categories/tags (so the user can adjust before publish)
6. Preview command:

```bash
cd "$BLOG_REPO" && bundle exec jekyll s --drafts
```

7. Promotion command (do NOT run it — show it):

```bash
mv "$BLOG_REPO/_drafts/YYYY-MM-DD-<slug>.md" \
   "$BLOG_REPO/_posts/YYYY-MM-DD-<slug>.md"
```

## Edge cases

- **Session has nothing publishable** (privacy-blocked, trivial fix, single-file rename): tell the user, don't write a thin post.
- **Multiple distinct topics in one session**: offer to write them as separate drafts.
- **User already has a draft for this topic** (`ls _drafts/` matches similar slug): show it, ask if appending or replacing.
- **Blog repo missing**: stop and tell the user — do not create it.
- **Session contains content from a private repo even after redaction**: refuse the post, recommend `/learn` to capture personal-only lesson instead.
- **User asks to publish directly**: refuse and explain — drafts only, user reviews and promotes manually.

## Inspiration & references

This skill borrows from:

- `/commit` — context-mode batch pattern for keeping raw output out of context
- `/learn` — classifying signal worth preserving
- `/mm-extract` — distilling a session into reusable knowledge entries

Style models: Simon Willison (TILs, daily-shipping cadence), Julia Evans (honest confusion-to-clarity), Hillel Wayne (progressive disclosure). Aim for "a smart friend explaining what they just figured out" — not a tutorial, not a press release.

---

Adapted for Claude Code from the Hermes Agent skill at `skills/hermes/blog-post/SKILL.md`. Substance is the same; only paths, platform commands, and tool names changed.
