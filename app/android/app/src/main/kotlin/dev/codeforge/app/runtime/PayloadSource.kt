package dev.codeforge.app.runtime

import android.content.Context
import android.content.res.AssetManager
import dev.codeforge.runtime.core.exec.SealedPayloadInstaller
import java.io.IOException
import java.io.InputStream

/**
 * Where a sealed payload's files come from (Phase 4 W3): the APK's assets on a
 * device, a folder in the JVM tests. The file names are t1's, from
 * runtime/build-sealed-payload.py, through [SealedPayloadInstaller]'s helpers
 * (userland-<abi>.zip, sealed-manifest-<abi>.txt, sealed-exec-<abi>.txt,
 * sealed-symlinks-<abi>.txt, sealed-payload-id-<abi>.txt), and
 * runtime-info-<abi>.json from runtime/pins.py.
 */
interface PayloadSource {
    /** The payload's ABI on this device, or null when this APK carries none for it. */
    fun abi(): String?

    /** The payload's identity (16 hex digits), or null when it has none. */
    fun identity(abi: String): String?

    /** Opens one of the payload's files; an IOException when it is absent. */
    @Throws(IOException::class)
    fun open(name: String): InputStream
}

/** The payload this APK carries in its assets. */
class AssetPayloadSource(context: Context) : PayloadSource {
    private val context = context.applicationContext

    override fun abi(): String? = SealedPayloadInstaller.pickAbi(context)

    override fun identity(abi: String): String? = SealedPayloadInstaller.payloadIdentity(context, abi)

    override fun open(name: String): InputStream =
        context.assets.open(name, AssetManager.ACCESS_STREAMING)
}
