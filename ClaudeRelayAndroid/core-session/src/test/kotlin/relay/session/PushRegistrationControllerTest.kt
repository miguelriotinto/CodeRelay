package relay.session

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class PushRegistrationControllerTest {
    @Test fun `registers when enabled permitted token and connected`() {
        val action = PushRegistrationController.decide(
            permissionGranted = true, deviceToken = "tok", connected = true,
            pushEnabledSetting = true, notifyOnFinished = true)
        assertEquals(PushRegistrationController.Action.Register(enabled = true, notifyOnFinished = true), action)
    }

    @Test fun `noop when not connected`() {
        val action = PushRegistrationController.decide(
            permissionGranted = true, deviceToken = "tok", connected = false,
            pushEnabledSetting = true, notifyOnFinished = false)
        assertEquals(PushRegistrationController.Action.Noop, action)
    }

    @Test fun `unregister when toggled off`() {
        val action = PushRegistrationController.decide(
            permissionGranted = true, deviceToken = "tok", connected = true,
            pushEnabledSetting = false, notifyOnFinished = false)
        assertEquals(PushRegistrationController.Action.Unregister, action)
    }

    @Test fun `unregister when permission revoked`() {
        val action = PushRegistrationController.decide(
            permissionGranted = false, deviceToken = "tok", connected = true,
            pushEnabledSetting = true, notifyOnFinished = false)
        assertEquals(PushRegistrationController.Action.Unregister, action)
    }

    @Test fun `noop when enabled but no token yet`() {
        val action = PushRegistrationController.decide(
            permissionGranted = true, deviceToken = null, connected = true,
            pushEnabledSetting = true, notifyOnFinished = false)
        assertEquals(PushRegistrationController.Action.Noop, action)
    }
}
