package relay.storage

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.util.UUID

/**
 * Encrypted at-rest storage for per-connection authentication tokens.
 *
 * Ports `AuthManager.swift` (CodeRelayClient). On iOS/macOS those secrets live
 * in the Keychain under service `com.coderemote.relay`, keyed by the connection
 * `UUID` string. On Android there is no system Keychain, so we use
 * [EncryptedSharedPreferences] (AES-256 GCM, master key in the Android
 * Keystore / hardware-backed when available) with the **same** logical names:
 *
 * - file/service name: `com.coderemote.relay`
 * - per-connection key: the connection [UUID] string (`UUID.toString()`)
 *
 * Keeping the string identities identical to Swift means this store is the
 * single source of truth for those names across the whole product.
 *
 * The removed on-device speech stack also kept an AWS Bedrock bearer token here
 * under [BEDROCK_KEY]; [deleteBedrockToken] scrubs it (spec §10) and is the only
 * thing that still touches that entry.
 */
class TokenStore(context: Context) {

    private val prefs = EncryptedSharedPreferences.create(
        context,
        SERVICE_NAME,
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    /** Saves [token] for [connectionId], replacing any existing entry. */
    fun saveToken(token: String, connectionId: UUID) {
        // commit() (synchronous): a token saved in Add/Edit-Server must survive a
        // force-kill right after. With apply()'s async flush, a kill before the
        // write lands leaves no token next launch → "No saved token" on connect.
        prefs.edit().putString(connectionId.toString(), token).commit()
    }

    /** Returns the token for [connectionId], or `null` if none is stored. */
    fun loadToken(connectionId: UUID): String? =
        prefs.getString(connectionId.toString(), null)

    /** Removes the token for [connectionId]. No-op when absent. */
    fun deleteToken(connectionId: UUID) {
        prefs.edit().remove(connectionId.toString()).commit()
    }

    /**
     * Removes the AWS Bedrock bearer token the speech stack used to store.
     * Idempotent; called on every launch by `AppSettings`' speech-removal scrub.
     */
    fun deleteBedrockToken() {
        // commit() not apply() — see saveToken(); a force-kill must not resurrect it.
        prefs.edit().remove(BEDROCK_KEY).commit()
    }

    companion object {
        /**
         * EncryptedSharedPreferences file name. Matches the iOS/macOS Keychain
         * service string `com.coderemote.relay` (AuthManager.swift line 70:
         * `private let service = "com.coderemote.relay"`).
         */
        const val SERVICE_NAME = "com.coderemote.relay"

        /**
         * Legacy Bedrock bearer token key, kept only so [deleteBedrockToken] can
         * scrub it. Matches the old iOS/macOS Keychain account
         * `com.clauderelay.bedrock.bearerToken`.
         */
        const val BEDROCK_KEY = "com.clauderelay.bedrock.bearerToken"
    }
}
