package relay.storage

import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission

class XdgPathsTest {

    @AfterEach
    fun restore() {
        XdgPaths.envLookup = System::getenv
        XdgPaths.homeLookup = { System.getProperty("user.home") }
    }

    @Test
    fun `honours an absolute XDG variable`() {
        XdgPaths.envLookup = { if (it == "XDG_CONFIG_HOME") "/custom/cfg" else null }
        assertEquals(File("/custom/cfg/coderelay"), XdgPaths.configDir)
    }

    @Test
    fun `falls back to the spec default when unset`() {
        XdgPaths.envLookup = { null }
        XdgPaths.homeLookup = { "/home/tester" }
        assertEquals(File("/home/tester/.config/coderelay"), XdgPaths.configDir)
        assertEquals(File("/home/tester/.local/state/coderelay"), XdgPaths.stateDir)
        assertEquals(File("/home/tester/.local/share/coderelay"), XdgPaths.dataDir)
    }

    /**
     * The XDG spec says a relative value is invalid and must be ignored. Honouring
     * one would resolve the store against the process's working directory, so the
     * app would silently keep different bookmarks depending on where it was
     * launched from.
     */
    @Test
    fun `ignores a relative XDG variable`() {
        XdgPaths.envLookup = { "relative/path" }
        XdgPaths.homeLookup = { "/home/tester" }
        assertEquals(File("/home/tester/.config/coderelay"), XdgPaths.configDir)
    }

    @Test
    fun `ignores a blank XDG variable`() {
        XdgPaths.envLookup = { "   " }
        XdgPaths.homeLookup = { "/home/tester" }
        assertEquals(File("/home/tester/.config/coderelay"), XdgPaths.configDir)
    }

    @Test
    fun `ensureDir creates the directory owner-only`(@TempDir tmp: File) {
        val dir = File(tmp, "nested/deep")
        XdgPaths.ensureDir(dir)
        assertTrue(dir.isDirectory)

        val perms = Files.getPosixFilePermissions(dir.toPath())
        assertEquals(
            setOf(
                PosixFilePermission.OWNER_READ,
                PosixFilePermission.OWNER_WRITE,
                PosixFilePermission.OWNER_EXECUTE,
            ),
            perms,
            "the config dir names reachable hosts; other local users have no business reading it",
        )
    }

    @Test
    fun `writeAtomically writes content and creates parents`(@TempDir tmp: File) {
        val target = File(tmp, "a/b/servers.json")
        XdgPaths.writeAtomically(target, """{"hello":"world"}""")
        assertEquals("""{"hello":"world"}""", target.readText())
    }

    @Test
    fun `writeAtomically replaces existing content wholesale`(@TempDir tmp: File) {
        val target = File(tmp, "f.json")
        XdgPaths.writeAtomically(target, "aaaaaaaaaaaaaaaaaaaa")
        XdgPaths.writeAtomically(target, "bb")
        assertEquals("bb", target.readText(), "a shorter write must not leave a tail of the old content")
    }

    @Test
    fun `writeAtomically leaves no temp files behind`(@TempDir tmp: File) {
        val target = File(tmp, "f.json")
        XdgPaths.writeAtomically(target, "x")
        val strays = tmp.listFiles()!!.filter { it.name != "f.json" }
        assertTrue(strays.isEmpty(), "expected only the target, found $strays")
    }

    @Test
    fun `written file is owner-only`(@TempDir tmp: File) {
        val target = File(tmp, "f.json")
        XdgPaths.writeAtomically(target, "x")
        val perms = Files.getPosixFilePermissions(target.toPath())
        assertFalse(perms.contains(PosixFilePermission.OTHERS_READ))
        assertFalse(perms.contains(PosixFilePermission.GROUP_READ))
    }
}
