package app.sapoche.sync

import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ListenBrainzHttpTest {

    @Test
    fun `it asks with the token and gives back what the service answered, a refusal too`() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(200).body("""{"valid":true}""").build())
            server.enqueue(MockResponse.Builder().code(429).addHeader("X-RateLimit-Reset-In", "12").build())
            server.start()
            val http = ListenBrainzHttp(base = server.url("/").toString().trimEnd('/'))
            val first = http.send("/1/validate-token", "tok", null)
            assertEquals(200, first.status)
            assertEquals("""{"valid":true}""", first.body)
            assertNull(first.resetInSec)
            val second = http.send("/1/submit-listens", "tok", """{"listen_type":"single"}""")
            assertEquals(429, second.status)
            assertEquals(12, second.resetInSec)
            val get = server.takeRequest()
            assertEquals("GET", get.method)
            assertEquals("Token tok", get.headers["Authorization"])
            val post = server.takeRequest()
            assertEquals("POST", post.method)
            assertEquals("/1/submit-listens", post.url.encodedPath)
            assertEquals("""{"listen_type":"single"}""", post.body?.utf8())
        }
    }
}
