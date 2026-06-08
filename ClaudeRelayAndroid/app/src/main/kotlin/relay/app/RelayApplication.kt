package relay.app

import android.app.Application

/**
 * M1 demo Application. No DI (Hilt is deferred to M2), no global state — exists
 * only so the manifest has an `android:name` to register and the process has a
 * stable entry point.
 *
 * THROWAWAY: M2 replaces this whole module with the real app shell.
 */
class RelayApplication : Application()
