#!/usr/bin/env python3
"""Adds bracketed-paste dispatch to the pinned termlib checkout.

See 0002-bracketed-paste.md for the rationale. Idempotent, like the mouse
patch: re-running against an already-patched tree is a no-op.
"""
import sys, pathlib

root = pathlib.Path(sys.argv[1])
cpp = root / "lib/src/main/cpp"
kt = root / "lib/src/main/java/org/connectbot/terminal"

def patch(path, anchor, addition, marker):
    p = pathlib.Path(path)
    s = p.read_text()
    if marker in s:
        return False
    if anchor not in s:
        raise SystemExit(f"anchor not found in {p.name}: {anchor[:60]!r}")
    p.write_text(s.replace(anchor, anchor + addition, 1))
    return True

changed = []

# --- Terminal.h ------------------------------------------------------------
if patch(
    cpp / "Terminal.h",
    "    bool dispatchMouseButton(int button, bool pressed, int modifiers);",
    """
    // CodeRelay addition — see linux-terminal/patches/0002-bracketed-paste.md.
    bool dispatchPasteStart();
    bool dispatchPasteEnd();""",
    "dispatchPasteStart",
):
    changed.append("Terminal.h")

# --- Terminal.cpp ----------------------------------------------------------
s = (cpp / "Terminal.cpp").read_text()
if "Terminal::dispatchPasteStart" not in s:
    impl = """// CodeRelay addition — see linux-terminal/patches/0002-bracketed-paste.md.
// libvterm tracks DECSET 2004 itself: these emit the `ESC [ 200 ~` / `ESC [ 201 ~`
// brackets only when the program has asked for them, and nothing otherwise.
bool Terminal::dispatchPasteStart() {
    std::scoped_lock lock(mLock);
    if (!mVt) {
        return false;
    }
    vterm_keyboard_start_paste(mVt);
    return true;
}

bool Terminal::dispatchPasteEnd() {
    std::scoped_lock lock(mLock);
    if (!mVt) {
        return false;
    }
    vterm_keyboard_end_paste(mVt);
    return true;
}"""
    jni_anchor = 'Java_org_connectbot_terminal_TerminalNative_nativeDispatchKey'
    idx = s.index(jni_anchor)
    start = s.rindex("JNIEXPORT", 0, idx)
    s = s[:start] + impl + "\n\n" + s[start:]

    jni = '''
JNIEXPORT jboolean JNICALL
Java_org_connectbot_terminal_TerminalNative_nativeDispatchPasteStart(JNIEnv* /* env */, jobject /* thiz */,
                                                                     jlong ptr) {
    auto* term = reinterpret_cast<Terminal*>(ptr);
    return term->dispatchPasteStart();
}

JNIEXPORT jboolean JNICALL
Java_org_connectbot_terminal_TerminalNative_nativeDispatchPasteEnd(JNIEnv* /* env */, jobject /* thiz */,
                                                                   jlong ptr) {
    auto* term = reinterpret_cast<Terminal*>(ptr);
    return term->dispatchPasteEnd();
}
'''
    ch = 'Java_org_connectbot_terminal_TerminalNative_nativeDispatchMouseButton'
    ci = s.index(ch)
    close = s.index("\n}\n", ci) + len("\n}\n")
    s = s[:close] + jni + s[close:]
    (cpp / "Terminal.cpp").write_text(s)
    changed.append("Terminal.cpp")

# --- TerminalNative.kt -----------------------------------------------------
k = kt / "TerminalNative.kt"
s = k.read_text()
if "dispatchPasteStart" not in s:
    anchor = """    fun dispatchMouseButton(button: Int, pressed: Boolean, modifiers: Int): Boolean {
        checkNotClosed()
        return nativeDispatchMouseButton(nativePtr, button, pressed, modifiers)
    }"""
    if anchor not in s:
        raise SystemExit("TerminalNative.kt anchor not found (is the mouse patch applied?)")
    s = s.replace(anchor, anchor + '''

    /**
     * Bracketed paste. libvterm emits the DECSET 2004 brackets only when the
     * program enabled them. CodeRelay addition — see
     * linux-terminal/patches/0002-bracketed-paste.md.
     */
    fun dispatchPasteStart(): Boolean {
        checkNotClosed()
        return nativeDispatchPasteStart(nativePtr)
    }

    fun dispatchPasteEnd(): Boolean {
        checkNotClosed()
        return nativeDispatchPasteEnd(nativePtr)
    }''', 1)

    decl_anchor = "    private external fun nativeDispatchMouseButton(ptr: Long, button: Int, pressed: Boolean, modifiers: Int): Boolean"
    if decl_anchor not in s:
        raise SystemExit("TerminalNative.kt declaration anchor not found")
    s = s.replace(decl_anchor, decl_anchor + """
    private external fun nativeDispatchPasteStart(ptr: Long): Boolean
    private external fun nativeDispatchPasteEnd(ptr: Long): Boolean""", 1)
    k.write_text(s)
    changed.append("TerminalNative.kt")

print("paste patch:", ", ".join(changed) if changed else "already applied (no-op)")
