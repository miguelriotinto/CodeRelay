package relay.feature.workspace.ui

import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.mutableStateListOf
import relay.terminal.TerminalEngine

/**
 * A NON-VT text-fallback [TerminalEngine] for M2.
 *
 * // M2 text-fallback; real Termux TerminalEngine binding is M-future per
 * // terminal/TERMUX_INTEGRATION.md
 *
 * The real Termux `TerminalView`/`TerminalEmulator` binding is DEFERRED (see
 * `terminal/TERMUX_INTEGRATION.md`); there is no VT100/xterm parser here. This
 * engine satisfies the real [TerminalEngine] contract so it can be driven by the
 * real [relay.terminal.RelayTerminalController] over the real byte path — output
 * bytes flow verbatim from the relay through the controller into [feedOutput],
 * exactly as the production Termux engine will. It simply accumulates the bytes
 * and exposes a UTF-8-lossy [text] for a scrollable monospace `Text`, the same
 * fallback the M1 demo used (M1DemoScreen.kt) but now packaged as a reusable
 * engine in this module.
 *
 * No ANSI/escape interpretation: control sequences appear as their raw glyphs.
 * That is acceptable for a placeholder whose only job is to prove the seam.
 *
 * Not thread-safe: like the production engine, all calls are expected on the
 * single UI thread. [text] is Compose snapshot state so the host recomposes as
 * bytes arrive.
 */
class TextFallbackTerminalEngine : TerminalEngine {

    /**
     * Accumulated decoded chunks. A list of strings (not one giant `String`) so
     * appends are O(1) and don't recopy the whole buffer per frame; the host
     * joins them for display. Capped to [MAX_CHUNKS] (drop-oldest) so a long
     * session can't grow the buffer without bound.
     */
    private val chunks: SnapshotStateList<String> = mutableStateListOf()

    private val _text = mutableStateOf("")

    /** Snapshot-state UTF-8-lossy view of everything fed so far. */
    val text: String get() = _text.value

    override fun feedOutput(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        chunks.add(String(bytes, Charsets.UTF_8))
        while (chunks.size > MAX_CHUNKS) {
            chunks.removeAt(0)
        }
        _text.value = chunks.joinToString(separator = "")
    }

    override fun resize(cols: Int, rows: Int) {
        // No grid in the text fallback — geometry is irrelevant until the real
        // Termux engine lands. The controller still calls this; it is a no-op.
        _cols = cols
        _rows = rows
    }

    private var _cols: Int = 0
    private var _rows: Int = 0
    override val cols: Int get() = _cols
    override val rows: Int get() = _rows

    override var onInput: ((ByteArray) -> Unit)? = null

    companion object {
        /** Drop-oldest cap on retained output chunks (placeholder, not load-bearing). */
        private const val MAX_CHUNKS = 4_000
    }
}
