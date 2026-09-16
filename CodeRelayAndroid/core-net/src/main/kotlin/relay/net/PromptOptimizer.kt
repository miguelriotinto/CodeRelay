package relay.net

/**
 * Result of an `optimize_prompt` RPC, ported from `PromptOptimizer.swift`.
 * Unknown statuses from a newer relay collapse into [Failed] so they can never
 * crash an older client.
 */
sealed interface OptimizeOutcome {
    /**
     * The server rewrote the draft in place. [original] is what was on the
     * input line before; null only against a relay that omits it, in which
     * case Undo cannot be offered.
     */
    data class Ok(val original: String?) : OptimizeOutcome
    data object NoDraft : OptimizeOutcome
    data object Passthrough : OptimizeOutcome
    data object Unconfigured : OptimizeOutcome
    /** [message] is the server's text, or [OptimizerStrings.COULD_NOT_REWRITE] when it sent none. */
    data class Failed(val message: String) : OptimizeOutcome
}

/** Result of a `replace_prompt` (Undo) RPC. */
sealed interface ReplaceOutcome {
    data object Ok : ReplaceOutcome
    data class Failed(val message: String) : ReplaceOutcome
}

/**
 * Every user-facing optimizer string, byte-exact with `OptimizerStrings` in
 * `Sources/CodeRelayClient/PromptOptimizer.swift` (spec §7.1, §9, §10). Defined
 * once; call sites must reference these, never retype them.
 */
object OptimizerStrings {
    const val CONFIG_HINT = "Enable on the relay: claude-relay config set promptOptimizerEnabled true"
    const val UPDATE_RELAY_HINT = "Update the relay to use the prompt optimizer"
    const val NO_DRAFT = "Type or dictate a prompt first"
    const val PASSTHROUGH = "Nothing to optimize"
    const val COULD_NOT_REWRITE = "Optimizer could not rewrite this prompt"
    const val OPTIMIZED = "Optimized"
    const val UNDO = "Undo"
    const val WAND_LABEL = "Optimize Prompt"
    const val SHARE_SCREEN_TOGGLE = "Share terminal screen with the optimizer"
    const val SHARE_SCREEN_FOOTER =
        "With this on, the relay also sends the last 40 lines of the terminal screen to the optimizer model. " +
            "The draft and its working directory are always sent."
}

/** Wire-level facts the wand's availability gate is derived from (spec §6, §7.1). */
object PromptOptimizerProtocol {
    /**
     * The first protocol version whose `auth_success` carries `capabilities`.
     * Deliberately a literal and NOT [ProtocolVersions.CURRENT]: the gate must
     * not move when the client's own version does.
     */
    const val MIN_PROTOCOL_VERSION = 2

    /** The capability string the relay advertises when the optimizer is usable. */
    const val CAPABILITY = "prompt_optimizer"
}
