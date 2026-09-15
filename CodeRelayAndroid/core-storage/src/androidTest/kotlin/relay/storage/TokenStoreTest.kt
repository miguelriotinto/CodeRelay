package relay.storage

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
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
    fun deleteBedrockTokenIsIdempotent() {
        // Nothing stored → two deletes must both be no-ops and must not disturb
        // anything else in the file. ("stored → removed" is
        // deleteBedrockTokenRemovesAStoredValue.)
        store.deleteBedrockToken()
        store.deleteBedrockToken()
        assertNull(store.loadToken(UUID.randomUUID())) // unrelated entries untouched
    }

    @Test
    fun deleteBedrockTokenRemovesAStoredValue() {
        // The one security-relevant behaviour this module ships (spec §10). Seeded
        // through the raw EncryptedSharedPreferences because `saveBedrockToken` was
        // deleted with the speech stack, so a wrong key constant or an edit on the
        // wrong file would otherwise stay green.
        val context = ApplicationProvider.getApplicationContext<Context>()
        val raw = EncryptedSharedPreferences.create(
            context,
            TokenStore.SERVICE_NAME,
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
        raw.edit().putString(TokenStore.BEDROCK_KEY, "legacy-secret").commit()
        assertNotNull(raw.getString(TokenStore.BEDROCK_KEY, null))

        TokenStore(context).deleteBedrockToken()

        assertNull(raw.getString(TokenStore.BEDROCK_KEY, null))
        store.deleteBedrockToken() // idempotent on an already-clean entry
    }
}
