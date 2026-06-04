package com.httparena.fishcake

import com.httparena.fishcake.services.AsyncDatabase
import com.httparena.fishcake.services.Baseline
import com.httparena.fishcake.services.Crud
import com.httparena.fishcake.services.JsonService
import com.httparena.fishcake.services.Upload
import org.codegreen.modules.io.Content
import org.codegreen.modules.io.Resource
import org.codegreen.modules.layouting.Layout
import org.codegreen.modules.layouting.provider.LayoutBuilder
import org.codegreen.modules.webservices.addService

/**
 * Builds the routing tree, mirroring the C# `genhttp-11` entry's `Project.Create()`.
 *
 * Compression, static files, websockets and TLS/HTTP-2 from the original entry rely on
 * modules the CodeGreen port does not provide yet and are omitted; the implemented profiles
 * are baseline, pipelined, json, upload, async-db and crud.
 */
object Project {

    fun create(): LayoutBuilder =
        Layout.create()
            .add("pipeline", Content.from(Resource.fromString("ok")))
            .addService<Baseline>("baseline11")
            .addService<Baseline>("baseline2")
            .addService<Upload>("upload")
            .addService<JsonService>("json")
            .addService<AsyncDatabase>("async-db")
            .add("crud", Layout.create().addService<Crud>("items"))
}
