package com.httparena.fishcake

import kotlinx.coroutines.runBlocking
import org.codegreen.engine.internal.Host
import kotlin.system.exitProcess

/**
 * HttpArena entry "fishcake": the CodeGreen Kotlin port of GenHTTP, configured like the C#
 * `genhttp-11` entry. Serves on `0.0.0.0:8080` (HTTP/1.1).
 */
fun main() {
    // Touch the singletons up front so the dataset is parsed and the DB pool is opened
    // before the first request arrives.
    val datasetSize = Dataset.items.size
    println("fishcake (CodeGreen) starting on :8080 — dataset items: $datasetSize, database: ${if (Database.available) "connected" else "disabled"}")

    val exitCode = runBlocking {
        Host.create()
            .handler(Project.create())
            .port(8080)
            .run()
    }

    exitProcess(exitCode)
}
