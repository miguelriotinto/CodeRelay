package relay.platform

import java.awt.Toolkit
import java.awt.datatransfer.DataFlavor
import java.awt.datatransfer.StringSelection
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit
import javax.imageio.ImageIO

/**
 * The system clipboard, for a JVM app running under Wayland.
 *
 * AWT's clipboard only speaks X11, so under Hyprland it reaches the compositor
 * through XWayland's selection bridge — which works for text, is flaky for
 * images, and does not exist for the PRIMARY selection at all. `wl-clipboard`
 * (`wl-copy` / `wl-paste`) talks to the compositor directly and is the tool
 * every other Wayland-native app shells out to, so it is preferred whenever
 * `WAYLAND_DISPLAY` is set and the binaries exist. AWT is the fallback for an
 * X11 session or a box without `wl-clipboard` (an *optional* dependency in the
 * PKGBUILD, precisely because this fallback exists).
 *
 * Text is passed to `wl-copy` on **stdin**, never argv: the clipboard is the
 * user's data and `/proc/<pid>/cmdline` is world-readable.
 */
class DesktopClipboard(
    private val runner: CommandRunner = ProcessCommandRunner,
    private val wayland: Boolean = System.getenv("WAYLAND_DISPLAY")?.isNotBlank() == true,
) {

    /** Seam for tests. Production runs real processes. */
    interface CommandRunner {
        /** Runs [command] with [stdin], returns stdout bytes, or null on failure/non-zero exit. */
        fun run(command: List<String>, stdin: ByteArray? = null): ByteArray?
        fun exists(binary: String): Boolean
    }

    private val useWl: Boolean by lazy { wayland && runner.exists("wl-copy") && runner.exists("wl-paste") }

    /** Writes [text] to the clipboard (CLIPBOARD selection). */
    fun setText(text: String) {
        if (useWl) {
            runner.run(listOf("wl-copy", "--type", "text/plain;charset=utf-8"), text.toByteArray())
            return
        }
        runCatching { awt().setContents(StringSelection(text), null) }
    }

    /** Writes [text] to the PRIMARY selection (middle-click paste). Wayland only. */
    fun setPrimary(text: String) {
        if (useWl) runner.run(listOf("wl-copy", "--primary", "--type", "text/plain;charset=utf-8"), text.toByteArray())
    }

    /** Reads clipboard text, or null when it holds none. */
    fun getText(primary: Boolean = false): String? {
        if (useWl) {
            val args = buildList {
                add("wl-paste"); add("--no-newline"); add("--type"); add("text")
                if (primary) add("--primary")
            }
            return runner.run(args)?.toString(Charsets.UTF_8)?.takeIf { it.isNotEmpty() }
        }
        if (primary) return null
        return runCatching {
            awt().getData(DataFlavor.stringFlavor) as? String
        }.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    /** Reads a clipboard image as PNG bytes, or null when the clipboard holds no image. */
    fun getImagePng(): ByteArray? {
        if (useWl) {
            val types = runner.run(listOf("wl-paste", "--list-types"))?.toString(Charsets.UTF_8) ?: return null
            val mime = types.lineSequence().map { it.trim() }.firstOrNull { it.startsWith("image/") } ?: return null
            val bytes = runner.run(listOf("wl-paste", "--type", mime)) ?: return null
            return if (mime == "image/png") bytes else transcodeToPng(bytes)
        }
        return runCatching {
            val image = awt().getData(DataFlavor.imageFlavor) as? java.awt.Image ?: return null
            val buffered = BufferedImage(image.getWidth(null), image.getHeight(null), BufferedImage.TYPE_INT_ARGB)
            buffered.graphics.apply { drawImage(image, 0, 0, null); dispose() }
            encodePng(buffered)
        }.getOrNull()
    }

    private fun transcodeToPng(bytes: ByteArray): ByteArray? =
        runCatching { ImageIO.read(bytes.inputStream())?.let(::encodePng) }.getOrNull()

    private fun encodePng(image: BufferedImage): ByteArray =
        ByteArrayOutputStream().also { ImageIO.write(image, "png", it) }.toByteArray()

    private fun awt() = Toolkit.getDefaultToolkit().systemClipboard

    /** Runs real processes with a short bound; the clipboard must never hang the UI. */
    object ProcessCommandRunner : CommandRunner {
        override fun run(command: List<String>, stdin: ByteArray?): ByteArray? = runCatching {
            val process = ProcessBuilder(command)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
            process.outputStream.use { if (stdin != null) it.write(stdin) }
            val output = process.inputStream.use { it.readBytes() }
            if (!process.waitFor(5, TimeUnit.SECONDS)) {
                process.destroy()
                return null
            }
            if (process.exitValue() != 0) null else output
        }.getOrNull()

        override fun exists(binary: String): Boolean =
            System.getenv("PATH").orEmpty().split(':').any { java.io.File(it, binary).canExecute() }
    }
}
