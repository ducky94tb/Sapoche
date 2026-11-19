package app.sapoche.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** [ListenBrainz](https://listenbrainz.org) over the real network. Any answer is a [ScrobbleReply]; only a failure to reach it throws. */
class ListenBrainzHttp(
    private val client: OkHttpClient = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build(),
    private val base: String = "https://api.listenbrainz.org",
) : ScrobbleHttp {
    override suspend fun send(path: String, token: String, body: String?): ScrobbleReply = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(base + path).header("Authorization", "Token $token")
            .apply { if (body != null) post(body.toRequestBody("application/json".toMediaType())) }
            .build()
        client.newCall(request).execute().use { response ->
            ScrobbleReply(response.code, response.body.string(), response.header("X-RateLimit-Reset-In")?.toIntOrNull())
        }
    }
}
