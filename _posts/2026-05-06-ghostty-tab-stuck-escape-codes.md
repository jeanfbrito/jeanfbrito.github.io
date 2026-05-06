---
title: When Ghostty starts spitting escape codes at every keypress
date: 2026-05-06 11:30:00 -0300
categories: [Tooling, Terminal]
tags: [ghostty, zsh, terminal, kitty-keyboard-protocol, tui, escape-codes]
description: A Ghostty tab started printing raw escape sequences for every key, including mouse moves. Here is what causes it, why iTerm2 never showed it, and a six-line zshrc hook that heals it.
pin: false
math: false
mermaid: false
---

A Ghostty tab of mine occasionally goes feral. Every keypress prints something like `^[[99;5u`. Mouse movement spews `^[[O^[[I` over and over. Tab autocomplete dies. The only fix I had was closing the tab and opening a new one — annoying because I was usually mid-task with shell history I wanted to keep.

I used iTerm2 for years and never saw this once. So either Ghostty was doing something different, or I had been getting lucky. Turns out the answer is "yes, both."

## The setup

Those weird codes are not random. Each one is a real terminal escape sequence with a real meaning:

- `^[[99;5u` — Kitty keyboard protocol report. `99` is the codepoint for `c`, `5` is the modifier mask for Ctrl. So that string is "Ctrl+C" being reported in the modern format.
- `^[[O` and `^[[I` — focus-out and focus-in events. The terminal is telling the foreground program every time the window loses or gains focus.
- `^[[B` — down arrow.
- `^[[?1000h` family — mouse tracking enable/disable.

These sequences exist so TUI programs (Neovim, fzf, btop, lazygit, htop, tmux, anything written with notcurses or ratatui) can ask the terminal: "send me precise key events with full modifier information, tell me when I'm focused, and report mouse movement." When the program starts, it sends an *enable* sequence. When it exits cleanly, it sends a *disable* sequence. The terminal then goes back to normal "characters in, characters out" mode.

The problem: if the program does not exit cleanly — `kill -9`, parent process dies, window force-closes, container gets reaped — those disable sequences never get sent. The terminal stays in advanced reporting mode. The next program in that tab is your shell, which has no idea what to do with `^[[99;5u`, so it just prints it.

That is the leak. It is not a Ghostty bug, it is a TTY state bug. The state is "stuck on" until something explicitly turns it off.

## What worked

I tried two things. The first was a one-shot rescue command for an already-stuck tab:

```bash
printf '\e[<u\e[?1004l\e[?1000l\e[?1002l\e[?1003l\e[?1006l' && stty sane && clear
```

That:

- `\e[<u` pops the Kitty keyboard protocol stack
- `\e[?1004l` disables focus reporting
- `\e[?1000l`, `\e[?1002l`, `\e[?1003l`, `\e[?1006l` disable the four mouse tracking modes
- `stty sane` resets line discipline in case raw mode is still on
- `clear` repaints

You can usually just type it blind even if the terminal looks completely broken — the shell is still parsing input, it just cannot render the prompt prettily. `reset` (the old SysVish command) works too, it is just heavier.

But a rescue is reactive. I wanted prevention. The actual fix was a `precmd` hook in zsh that scrubs these modes before every prompt:

```zsh
# Reset terminal modes before each prompt — heals leaks from crashed TUIs
# (Kitty keyboard protocol, focus reporting, mouse tracking)
_reset_term_modes() {
  printf '\e[<u\e[?1004l\e[?1000l\e[?1002l\e[?1003l\e[?1006l'
}
precmd_functions+=(_reset_term_modes)
```

`precmd_functions` is zsh's array of hooks that run right before each prompt is drawn. Append a function to it and zsh calls it every time you press Enter. The cost is microseconds — six escape sequences to a local PTY is nothing — and the effect is that whenever a TUI dies dirty, the *next* prompt cleans up after it. The tab keeps your history, your env, your cwd. No more close-and-reopen.

If you use bash instead, the equivalent goes in `PROMPT_COMMAND`:

```bash
_reset_term_modes() {
  printf '\e[<u\e[?1004l\e[?1000l\e[?1002l\e[?1003l\e[?1006l'
}
PROMPT_COMMAND="_reset_term_modes${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

## Where it almost went sideways

My first version of the hook was longer:

```zsh
printf '\e[>4;0m\e[<u\e[?1004l\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?2004h'
```

I added `\e[>4;0m` to reset *modifyOtherKeys* (an older xterm protocol that does what Kitty's keyboard protocol does, just clunkier), and `\e[?2004h` to make sure bracketed paste was on. Sounded thorough.

It broke Tab completion.

The moment I sourced the new `.zshrc`, hitting Tab no longer triggered zsh's `complete-word` widget. It just inserted a literal tab character, or sometimes nothing at all. Took me one panicked moment to connect "I just changed terminal modes" with "completion is dead."

The culprit was `\e[>4;0m`. Setting modifyOtherKeys back to level 0 changes how the terminal encodes Ctrl+key combinations. zsh's line editor (zle) had read terminfo at startup expecting one encoding for `\t`; resetting the mode mid-session shifted the encoding underneath it, and Tab's binding stopped matching. Bracketed paste being toggled every prompt was also adding small visual flicker.

The fix was to delete those two sequences and leave only the ones that target *broken* state, not state zsh actively manages:

```zsh
_reset_term_modes() {
  printf '\e[<u\e[?1004l\e[?1000l\e[?1002l\e[?1003l\e[?1006l'
}
```

Lesson buried in there: "be thorough" is the wrong instinct for terminal state. The right instinct is "touch the minimum necessary." Every mode you reset is a mode that some program might be legitimately using. Kitty keyboard, focus reporting, and mouse tracking are safe to nuke between commands because no shell prompt needs them. modifyOtherKeys and bracketed paste are *not* safe — zsh and your prompt may rely on them being in a specific state.

## Why iTerm2 never showed this

I was curious why I never hit this in a decade of iTerm2. Two reasons:

1. **iTerm2 does not implement the Kitty keyboard protocol.** As of writing, the relevant tracking issue ([gnachman/iTerm2#9382](https://gitlab.com/gnachman/iterm2/-/issues/9382)) is still open. So iTerm2 never advertises the capability, no TUI tries to enable it, and there is nothing to leak. Ghostty advertises it by default, which is why suddenly TUIs all started using it on me.
2. **iTerm2 self-heals on tab focus.** When you click into a tab, iTerm2 sends a small reset sequence as part of its DA1 (Device Attributes) negotiation. Ghostty does not currently do this. So in iTerm2 the leak existed in theory but got papered over the moment you switched tabs.

This is not a knock on Ghostty — supporting Kitty keyboard is correct and useful, and I want it. But it does mean Ghostty users absorb a small extra responsibility: clean up after dirty TUI exits, because the terminal will not.

## Takeaway

If your modern terminal starts printing escape codes for every keystroke, it is almost always a TUI that died without sending its disable sequences. A six-line `precmd` hook that resets the offending modes before every prompt makes it self-healing. But keep the reset list narrow — only touch state your shell does not care about, or you will break completion, paste, or both.

The general principle is broader than terminals: stateful protocols accumulate cleanup debt at every layer. The fix is rarely to turn the protocol off, it is usually to add an idempotent reset at a moment where you know the system should be in a known-good state. For terminals, that moment is "right before drawing a prompt." That is what `precmd_functions` is for.

---

*Written with [Claude Opus 4.7](https://www.anthropic.com/claude/opus) (`claude-opus-4-7`) via Claude Code.*
