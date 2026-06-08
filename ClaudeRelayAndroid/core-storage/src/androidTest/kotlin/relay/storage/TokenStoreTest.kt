package relay.storage

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class TokenStoreTest {

    private lateinit var store: TokenStore

    @Before
    fun setUp() {
        store = TokenStore(ApplicationProvider.getApplicationContext())
    }

    @Test
    fun roundTripsToken() {
        val id = UUID.randomUUID()
        store.saveToken("secret-token", id)
        assertEquals("secret-token", store.loadToken(id))

        store.deleteToken(id)
        assertNull(store.loadToken(id))
    }

    @Test
    fun perConnectionTokensAreIsolated() {
        val a = UUID.randomUUID()
        val b = UUID.randomUUID()
        store.saveToken("token-a", a)
        store.saveToken("token-b", b)

        assertEquals("token-a", store.loadToken(a))
        assertEquals("token-b", store.loadToken(b))

        store.deleteToken(a)
        store.deleteToken(b)
    }

    @Test
    fun bedrockEmptyDeletes() {
        store.saveBedrockToken("abc")
        assertEquals("abc", store.loadBedrockToken())

        store.saveBedrockToken("")
        assertNull(store.loadBedrockToken())
    }
}
