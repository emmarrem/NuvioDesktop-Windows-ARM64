package com.nuvio.app.features.plugins.runtime

import com.dokar.quickjs.QuickJs
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import java.util.concurrent.Executors

internal val pluginDispatcher: CoroutineDispatcher =
    if (System.getProperty("os.name", "").startsWith("Windows", ignoreCase = true) &&
        System.getProperty("os.arch", "").lowercase() in setOf("aarch64", "arm64")) {
        // QuickJS JNI 1.0.15 shares VM/class caches between runtimes without
        // synchronizing their lifetime. Serialize native calls on one thread;
        // suspending provider requests can still overlap on this dispatcher.
        Executors.newSingleThreadExecutor { task ->
            Thread(task, "Nuvio-QuickJS").apply { isDaemon = true }
        }.asCoroutineDispatcher()
    } else {
        Dispatchers.Default
    }

internal fun QuickJs.configurePluginRuntime() = Unit
