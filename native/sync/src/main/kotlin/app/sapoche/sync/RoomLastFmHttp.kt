package app.sapoche.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Last.fm through the room server: its `/lastfm` takes the call, signs it and passes it on. The server and the key are asked
 * for at each call, because the key can be set while the app runs. Any answer is a [ScrobbleReply]; only a failure to reach the server throws.
 */
class RoomLastFmHttp(
    private val server: () -> String,
    private val headers: () -> Map<String, String>,
    private val client: OkHttpClient = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build(),
) : LastFmHttp {
    override suspend fun send(form: String): ScrobbleReply = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(server().trimEnd('/') + "/lastfm")
            .apply { headers().forEach { (name, value) -> header(name, value) } }
            .post(form.toRequestBody("application/x-www-form-urlencoded".toMediaType()))
            .build()
        client.newCall(request).execute().use { response -> ScrobbleReply(response.code, response.body.string()) }
    }
}
