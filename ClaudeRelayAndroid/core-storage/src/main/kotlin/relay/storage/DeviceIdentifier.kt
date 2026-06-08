package relay.storage

import android.content.Context
import java.util.UUID

/**
 * Returns a stable-per-install identifier used to namespace per-device storage
 * (e.g. session-ownership keys), the same role `DeviceIdentifier.swift` plays on
 * iOS/macOS.
 *
 * ## Accepted iOS divergence
 *
 * iOS uses `UIDevice.identifierForVendor` and macOS uses the IOKit platform
 * UUID — both supplied by the OS. Android has no equivalent stable, privacy-safe
 * hardware ID we may read without restricted permissions, so we generate a random
 * [UUID] on first access and persist it in plain (non-encrypted) SharedPreferences.
 * The value is therefore stable for the lifetime of the install (it resets on
 * uninstall / data-clear), which is sufficient for storage namespacing.
 */
object DeviceIdentifier {

    private const val PREFS = "relay.device"
    private const val KEY = "deviceId"

    /**
     * Returns the persisted device id, generating and storing one on first call.
     * Subsequent calls return the same value for the lifetime of the install.
     */
    fun get(context: Context): String = synchronized(this) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY, null)
            ?: UUID.randomUUID().toString().also {
                // commit() (not apply()) so a crash right after generation can't lose it.
                prefs.edit().putString(KEY, it).commit()
            }
    }
}
