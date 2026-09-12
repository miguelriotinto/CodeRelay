package relay.session

/**
 * Decides what push-registration action to take from the current inputs, so the
 * register/update/unregister logic is unit-testable independent of Firebase.
 * Parity with the Swift `PushRegistrationController`.
 */
object PushRegistrationController {
    sealed interface Action {
        /** Send register_push_token with these preferences (idempotent by deviceId). */
        data class Register(val enabled: Boolean, val notifyOnFinished: Boolean) : Action
        /** Send unregister_push_token. */
        data object Unregister : Action
        /** Do nothing. */
        data object Noop : Action
    }

    fun decide(
        permissionGranted: Boolean,
        deviceToken: String?,
        connected: Boolean,
        pushEnabledSetting: Boolean,
        notifyOnFinished: Boolean,
    ): Action {
        if (!connected) return Action.Noop
        if (!pushEnabledSetting || !permissionGranted) return Action.Unregister
        if (deviceToken == null) return Action.Noop
        return Action.Register(enabled = true, notifyOnFinished = notifyOnFinished)
    }
}
