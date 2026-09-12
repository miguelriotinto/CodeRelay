package relay.platform

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class DesktopNotifierTest {

    private val session: UUID = UUID.fromString("11111111-2222-3333-4444-555555555555")

    @Test
    fun `the command carries the app name, urgency, replace hint and an Open action`() {
        val n = DesktopNotifier(appName = "CodeRelay", exec = { null }, supportsActions = true)
        val cmd = n.command("api", "Finished", session, urgent = false)
        assertEquals("notify-send", cmd.first())
        assertTrue("--app-name=CodeRelay" in cmd)
        assertTrue("--urgency=normal" in cmd)
        assertTrue("--hint=string:x-canonical-private-synchronous:coderelay-$session" in cmd)
        assertTrue("--action=default=Open" in cmd)
        assertEquals(listOf("--", "api", "Finished"), cmd.takeLast(3))
    }

    @Test
    fun `without action support the flag is omitted so the notification still shows`() {
        val n = DesktopNotifier(exec = { null }, supportsActions = false)
        assertFalse(n.command("t", "b", session, urgent = false).any { it.startsWith("--action") })
    }

    @Test
    fun `action support is read from the libnotify version`() {
        assertTrue(DesktopNotifier.supportsActions("notify-send 0.8.3"))
        assertTrue(DesktopNotifier.supportsActions("notify-send 0.7.10"))
        assertFalse(DesktopNotifier.supportsActions("notify-send 0.7.9"))
        assertFalse(DesktopNotifier.supportsActions(null))
    }

    @Test
    fun `a blocked agent is critical`() {
        val n = DesktopNotifier(exec = { null })
        assertTrue("--urgency=critical" in n.command("t", "b", session, urgent = true))
    }

    @Test
    fun `a title starting with a dash cannot become an option`() {
        val n = DesktopNotifier(exec = { null })
        val cmd = n.command("--help", "b", session, urgent = false)
        assertTrue(cmd.indexOf("--") < cmd.indexOf("--help"), "the -- separator precedes the title")
    }

    @Test
    fun `notify runs off the calling thread and routes a click to onActivated`() {
        val caller = Thread.currentThread()
        val ran = CountDownLatch(1)
        val activated = CountDownLatch(1)
        var execThread: Thread? = null
        var tapped: UUID? = null
        val n = DesktopNotifier(
            onActivated = { id -> tapped = id; activated.countDown() },
            exec = { execThread = Thread.currentThread(); ran.countDown(); DesktopNotifier.ACTION_OPEN },
        )
        n.notify("t", "b", session, urgent = false)
        assertTrue(ran.await(5, TimeUnit.SECONDS))
        assertTrue(execThread !== caller, "notify-send must not run on the caller (the AWT thread)")
        assertTrue(activated.await(5, TimeUnit.SECONDS))
        assertEquals(session, tapped)
    }

    @Test
    fun `a dismissed notification does not activate`() {
        val activated = CountDownLatch(1)
        val ran = CountDownLatch(1)
        val n = DesktopNotifier(onActivated = { activated.countDown() }, exec = { ran.countDown(); null })
        n.notify("t", "b", session, urgent = false)
        assertTrue(ran.await(5, TimeUnit.SECONDS))
        assertFalse(activated.await(200, TimeUnit.MILLISECONDS))
    }

    @Test
    fun `a failing notify-send is swallowed`() {
        val ran = CountDownLatch(1)
        val n = DesktopNotifier(exec = { ran.countDown(); throw IllegalStateException("no daemon") })
        n.notify("t", "b", session, urgent = false) // must not throw
        assertTrue(ran.await(5, TimeUnit.SECONDS))
    }
}
