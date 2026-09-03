# Patch: bracketed paste for termlib

**Applied to** `connectbot/termlib` at the pinned commit, by
`linux-terminal/build.gradle.kts` (`patchTermlibPaste`), after the mouse patch.

**Upstream this** alongside `0001-mouse-dispatch.md`; it is two one-line
wrappers over functions libvterm already exports.

## Why

A paste is not typing. Programs that enable DECSET 2004 (`CSI ?2004h` — vim,
zsh with `bracketed-paste-magic`, fish, Claude Code's input box) expect pasted
text wrapped in `ESC [ 200 ~` … `ESC [ 201 ~`, so that a newline in the middle
of the paste is inserted rather than executed and auto-indent is not applied to
every line. Without the brackets a multi-line paste into a shell runs each line.

libvterm tracks the mode and owns the encoding:

```c
void vterm_keyboard_start_paste(VTerm *vt);
void vterm_keyboard_end_paste(VTerm *vt);
```

Both emit nothing when the program has not enabled the mode, so the caller
never has to know which state the terminal is in — the same division of labour
the mouse patch relies on. termlib's JNI surface simply never exposed them.

## The patch

`Terminal.h` / `Terminal.cpp` gain `dispatchPasteStart()` and
`dispatchPasteEnd()` mirroring `dispatchKey` (same lock, same null guard), plus
the two JNI entry points; `TerminalNative.kt` gains the matching wrappers and
`external` declarations. The paste body itself goes through the existing
`dispatchCharacter` per code point between the two calls.

## Verification

`BracketedPasteTest` asserts that with `CSI ?2004h` set, `pasteText("ab")`
yields `ESC[200~ab ESC[201~` on the input sink, and that with the mode off it
yields exactly `ab`.
