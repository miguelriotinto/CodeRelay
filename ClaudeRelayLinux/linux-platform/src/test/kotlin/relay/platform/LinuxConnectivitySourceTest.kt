package relay.platform

import kotlinx.coroutines.test.TestScope
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class LinuxConnectivitySourceTest {

    private fun netDir(tmp: File, vararg interfaces: Pair<String, String>): File {
        interfaces.forEach { (name, state) ->
            File(tmp, name).mkdirs()
            File(tmp, "$name/operstate").writeText("$state\n")
        }
        return tmp
    }

    private fun source(dir: File) = LinuxConnectivitySource(TestScope(), netDir = dir)

    @Test
    fun `reports online when an ethernet link is up`(@TempDir tmp: File) {
        val dir = netDir(tmp, "lo" to "unknown", "enp3s0" to "up")
        assertTrue(source(dir).readLinkState())
    }

    @Test
    fun `reports offline when every real interface is down`(@TempDir tmp: File) {
        val dir = netDir(tmp, "lo" to "unknown", "enp3s0" to "down", "wlan0" to "down")
        assertFalse(source(dir).readLinkState())
    }

    /**
     * Loopback is always up. Counting it would mean the source could never
     * report offline, and `NetworkObserver` would never see the edge it exists
     * to detect.
     */
    @Test
    fun `loopback alone is not online`(@TempDir tmp: File) {
        val dir = netDir(tmp, "lo" to "up")
        assertFalse(source(dir).readLinkState())
    }

    /**
     * Tailscale, WireGuard and most TUN devices report `unknown` rather than
     * `up` — they have no physical carrier. Treating those as offline would mark
     * a Tailscale-only machine permanently disconnected, which is exactly the
     * deployment this client targets.
     */
    @Test
    fun `a tailscale interface reporting unknown counts as online`(@TempDir tmp: File) {
        val dir = netDir(tmp, "lo" to "unknown", "enp3s0" to "down", "tailscale0" to "unknown")
        assertTrue(source(dir).readLinkState())
    }

    @Test
    fun `wireguard reporting unknown counts as online`(@TempDir tmp: File) {
        val dir = netDir(tmp, "lo" to "unknown", "wg0" to "unknown")
        assertTrue(source(dir).readLinkState())
    }

    /**
     * If we cannot read the interface table at all we must assume online.
     * Assuming offline would park the client in a permanent recovery loop on any
     * system whose sysfs layout differs.
     */
    @Test
    fun `assumes online when the interface directory is unreadable`(@TempDir tmp: File) {
        assertTrue(source(File(tmp, "nonexistent")).readLinkState())
    }

    @Test
    fun `an interface without operstate is skipped not fatal`(@TempDir tmp: File) {
        File(tmp, "weird").mkdirs()
        val dir = netDir(tmp, "enp3s0" to "up")
        assertTrue(source(dir).readLinkState())
    }

    @Test
    fun `handles mixed case and whitespace in operstate`(@TempDir tmp: File) {
        File(tmp, "enp3s0").mkdirs()
        File(tmp, "enp3s0/operstate").writeText("  UP  \n")
        assertTrue(source(tmp).readLinkState())
    }

    @Test
    fun `dormant is not online`(@TempDir tmp: File) {
        val dir = netDir(tmp, "wlan0" to "dormant")
        assertFalse(dir.let(::source).readLinkState(), "dormant means associating, not carrying traffic")
    }

    @Test
    fun `initial value reflects current link state`(@TempDir tmp: File) {
        val dir = netDir(tmp, "enp3s0" to "up")
        assertTrue(source(dir).isOnline.value, "must not start at a default that fabricates an edge")
    }
}
