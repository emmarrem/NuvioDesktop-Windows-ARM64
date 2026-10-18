package com.nuvio.app.features.plugins

import com.nuvio.app.features.plugins.runtime.PluginRuntime
import com.nuvio.app.features.plugins.runtime.pluginDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import org.junit.Assume.assumeTrue
import kotlin.test.Test
import kotlin.test.assertEquals

class WindowsPluginRuntimeTest {
    private fun requireWindowsArm64() {
        assumeTrue(System.getProperty("os.name").startsWith("Windows", ignoreCase = true) &&
            System.getProperty("os.arch").lowercase() in setOf("aarch64", "arm64"))
    }

    @Test fun nativeCallsKeepThreadAffinityAcrossSuspension() = runBlocking {
        requireWindowsArm64()
        val threads = coroutineScope {
            (0 until 32).map {
                async(Dispatchers.Default) {
                    withContext(pluginDispatcher) {
                        val before = Thread.currentThread().id
                        yield()
                        assertEquals(before, Thread.currentThread().id)
                        before
                    }
                }
            }.awaitAll()
        }
        assertEquals(1, threads.distinct().size)
    }

    @Test fun overlappingRuntimeLifetimesKeepSharedNativeCachesValid() = runBlocking {
        requireWindowsArm64()
        repeat(8) { round ->
            val results = coroutineScope {
                (0 until 32).map { index ->
                    async(Dispatchers.Default) {
                        PluginRuntime.executePlugin(
                            code = """
                                module.exports.getStreams = async function(id) {
                                    await Promise.resolve();
                                    return [{ title: "Native lifetime " + id, url: "https://example.test/" + id + ".mp4" }];
                                };
                            """.trimIndent(),
                            tmdbId = "$round-$index",
                            mediaType = "movie",
                            season = null,
                            episode = null,
                            scraperId = "native-lifetime-$round-$index",
                        )
                    }
                }.awaitAll()
            }
            results.forEachIndexed { index, streams ->
                assertEquals("https://example.test/$round-$index.mp4", streams.single().url)
            }
        }
    }
}
