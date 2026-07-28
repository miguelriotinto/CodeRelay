package relay.storage

import android.content.Context
import android.provider.Settings
import java.util.UUID

/**
 * Returns a stable-per-install identifier, the same role `DeviceIdentifier.swift`
 * plays on iOS/macOS. Used to identify this device to the server for push
 * registration (`register_push_token`).
 *
 * NOTE: session ownership is NOT keyed by this id — the server's token-scoped
 * session list is authoritative and the pane renders it directly. (This id once
 * namespaced a local owned-session set whose instability caused sessions to
 * vanish from the pane; that set has been removed.)
 *
 * ## Why this is derived from the OS, not a random persisted UUID
 *
 * A stable-per-launch id still matters for push identity: [Settings.Secure.ANDROID_ID]
 * needs no storage write to stay stable, avoiding the OEM-storage-loss failure
 * mode a persisted random UUID had.
 *
 * The previous implementation generated a random [UUID] and persisted it in plain
 * SharedPreferences. That is fragile: if the (non-encrypted) write is ever lost —
 * which aggressive OEM storage/process management (notably HarmonyOS/EMUI on
 * Huawei) can cause — a NEW UUID is generated on the next launch, silently
 * re-namespacing all device-scoped storage. There is no recovery: every relaunch
 * looks like a brand-new device.
 *
 * So the PRIMARY source is now [Settings.Secure.ANDROID_ID] — a 64-bit value the
 * OS guarantees stable for the app's signing key + user across reboots and app
 * restarts (it resets only on factory reset / signing-key change), requires no
 * permission, and crucially needs NO storage write to stay stable. It is derived
 * fresh each launch and is identical each launch by construction.
 *
 * ## Fallback chain
 * 1. `ANDROID_ID` when present and not the known-bad emulator constant.
 * 2. A persisted random UUID (the old behaviour), for the rare device returning a
 *    null/bogus `ANDROID_ID`. Persisted with `commit()` so a crash can't lose it.
 * 3. An in-memory UUID for THIS process if even the persist read/write degrades —
 *    cached so it is at least stable within the process lifetime.
 *
 * The resolved value is memoised in [cached] so all callers in a process agree
 * even if step 2/3 is reached.
 */
object DeviceIdentifier {

    private const val PREFS = "relay.device"
    private const val KEY = "deviceId"

    /**
     * `9774d56d682e549c` is the well-known buggy `ANDROID_ID` that a population of
     * (mostly older/cloned) devices return identically — treat it as absent so we
     * fall back to a per-install UUID rather than collapsing every such device
     * onto one shared namespace.
     */
    private const val BAD_ANDROID_ID = "9774d56d682e549c"

    @Volatile
    private var cached: String? = null

    /**
     * Returns the stable device id, deriving it from [Settings.Secure.ANDROID_ID]
     * when available and falling back to a persisted/in-memory UUID otherwise.
     * Memoised for the process lifetime.
     */
    fun get(context: Context): String {
        cached?.let { return it }
        return synchronized(this) {
            cached?.let { return it }
            resolve(context.applicationContext).also { cached = it }
        }
    }

    private fun resolve(appContext: Context): String {
        // 1. OS-stable ANDROID_ID — no storage write needed to stay stable.
        val androidId = runCatching {
            Settings.Secure.getString(appContext.contentResolver, Settings.Secure.ANDROID_ID)
        }.getOrNull()
        if (!androidId.isNullOrBlank() && androidId != BAD_ANDROID_ID) {
            // Prefix so the namespace can't collide with a legacy persisted UUID
            // value (different shape) and so the source is self-describing.
            return "aid-$androidId"
        }

        // 2. Persisted random UUID (legacy behaviour) for devices with no usable
        //    ANDROID_ID. Reuse any value an earlier launch already stored.
        val prefs = runCatching {
            appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        }.getOrNull()
        prefs?.getString(KEY, null)?.let { return it }

        val generated = UUID.randomUUID().toString()
        // commit() (not apply()) so a crash right after generation can't lose it.
        // Best-effort: if the write fails, `cached` still keeps this stable for the
        // process so at least a single session lifetime is coherent.
        runCatching { prefs?.edit()?.putString(KEY, generated)?.commit() }
        return generated
    }
}
