package com.httparena

import io.ktor.utils.io.core.discard
import io.r2dbc.pool.ConnectionPool
import io.r2dbc.pool.ConnectionPoolConfiguration
import io.r2dbc.postgresql.PostgresqlConnectionConfiguration
import io.r2dbc.postgresql.PostgresqlConnectionFactory
import io.r2dbc.spi.ConnectionFactoryOptions
import io.r2dbc.spi.IsolationLevel
import io.r2dbc.spi.ValidationDepth
import kotlinx.io.Buffer
import kotlinx.io.RawSink
import kotlinx.serialization.json.Json
import org.jetbrains.exposed.v1.core.vendors.PostgreSQLDialect
import org.jetbrains.exposed.v1.r2dbc.R2dbcDatabase
import org.jetbrains.exposed.v1.r2dbc.R2dbcDatabaseConfig
import java.io.File
import java.net.URI
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64

object DevNull : RawSink {
    override fun close() {}
    override fun flush() {}
    override fun write(source: Buffer, byteCount: Long) {
        source.discard(byteCount)
    }
}

const val CERT_PATH = "/certs/server.crt"
const val KEY_PATH = "/certs/server.key"
const val KEY_ALIAS = "server"
val KEYSTORE_PASSWORD = CharArray(0)

class AppData {
    private val cpuCores = Runtime.getRuntime().availableProcessors()
    private val certFile = File(CERT_PATH)
    private val keyFile = File(KEY_PATH)
    private val datasetFile = File(System.getenv("DATASET_PATH") ?: "/data/dataset.json")

    val json = Json { ignoreUnknownKeys = true }

    /**
     * Dataset from file.  Used in JSON endpoints.
     */
    var dataset: List<DatasetItem> = datasetFile.takeIf { it.exists() }?.let {
        json.decodeFromString(it.readText())
    } ?: emptyList()

    /**
     * PostgreSQL connection.  Used in async database endpoints.
     */
    val postgres: R2dbcDatabase? = System.getenv("DATABASE_URL")?.let { dbUrl ->
        runCatching {
            val uri = URI(dbUrl.replace("postgres://", "postgresql://"))
            val host = uri.host
            val port = if (uri.port > 0) uri.port else 5432
            val database = uri.path.removePrefix("/")
            val userInfo = uri.userInfo.split(":")

            val factory = PostgresqlConnectionFactory(
                PostgresqlConnectionConfiguration.builder()
                    .host(host)
                    .port(port)
                    .database(database)
                    .username(userInfo[0])
                    .password(if (userInfo.size > 1) userInfo[1] else "")
                    .build()
            )
            val pool = ConnectionPool(
                ConnectionPoolConfiguration.builder(factory)
                    .initialSize(cpuCores * 2)
                    .maxSize(cpuCores * 2)
                    .validationQuery("")
                    .validationDepth(ValidationDepth.LOCAL)
                    .acquireRetry(0)
                    .build()
            )
            R2dbcDatabase.connect(
                connectionFactory = pool,
                databaseConfig = R2dbcDatabaseConfig.Builder().apply {
                    explicitDialect = PostgreSQLDialect()
                    defaultR2dbcIsolationLevel = IsolationLevel.READ_COMMITTED
                    defaultReadOnly = true
                }
            )
        }
    }?.getOrNull()

    /**
     * Keystore for TLS.  Used in JSON TLS and JSON compressed endpoints.
     */
    val keystore: KeyStore? = certFile.takeIf { it.exists() }?.let { certFile ->
        val certs = CertificateFactory.getInstance("X.509")
            .generateCertificates(certFile.inputStream())
            .map { it as X509Certificate }
            .toTypedArray()

        val keyBytes = Base64.getMimeDecoder().decode(
            keyFile.readText()
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replace("\\s".toRegex(), "")
        )
        val privateKey = KeyFactory.getInstance("RSA")
            .generatePrivate(PKCS8EncodedKeySpec(keyBytes))

        KeyStore.getInstance("PKCS12").apply {
            load(null, null)
            setKeyEntry(KEY_ALIAS, privateKey, KEYSTORE_PASSWORD, certs)
        }
    }
}
