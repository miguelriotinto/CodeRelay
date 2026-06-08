package relay.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

/**
 * Single-activity host for the M1 demo. Sets the Compose content to
 * [M1DemoScreen]; there is no nav graph (deferred to M2).
 *
 * THROWAWAY: M2 replaces this with the real app entry point.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            M1DemoScreen()
        }
    }
}
