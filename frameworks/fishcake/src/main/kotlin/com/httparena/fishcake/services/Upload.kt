package com.httparena.fishcake.services

import org.codegreen.modules.reflection.Method
import org.codegreen.modules.webservices.ResourceMethod
import java.io.InputStream

/**
 * `POST /upload` drains the request body stream and returns the number of bytes received.
 * The `input` parameter is bound to the request body stream by the reflection framework.
 */
class Upload {

    @ResourceMethod(Method.Post)
    fun compute(input: InputStream): Long {
        val buffer = ByteArray(8192)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            total += read
        }
        return total
    }
}
