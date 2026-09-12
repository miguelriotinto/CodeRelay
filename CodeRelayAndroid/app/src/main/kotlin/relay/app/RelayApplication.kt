package relay.app

import android.app.Application

/**
 * App `Application` entry point. No DI (Hilt is deferred), no global state — the
 * long-lived [relay.feature.settings.AppSettings] / connectivity / per-connection
 * coordinator are owned by [MainActivity]. Exists so the manifest has an
 * `android:name` to register and the process has a stable entry point.
 */
class RelayApplication : Application()
