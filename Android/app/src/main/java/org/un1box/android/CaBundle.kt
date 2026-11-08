package org.un1box.android

import android.content.Context
import java.io.File

/**
 * The bundled curl/OpenSSL came from a Termux-based Swift SDK, which hardcodes
 * /data/data/com.termux/files/usr/etc/tls/cert.pem as its CA file. Those two
 * libraries are patched to read this app-private file instead. Build it from
 * the phone's own system trust store: offline, and following system CA updates.
 */
object CaBundle {
    @Synchronized
    fun ensure(context: Context): File {
        val out = File(context.filesDir, "ca.pem")
        if (out.isFile && out.length() > 100_000) return out
        val tmp = File(context.filesDir, "ca.pem.tmp")
        try {
            tmp.outputStream().buffered().use { sink ->
                File("/system/etc/security/cacerts").listFiles()
                    ?.sortedBy { it.name }
                    ?.forEach { cert ->
                        if (cert.isFile && (cert.name.endsWith(".0") || cert.name.endsWith(".1")))
                            runCatching { cert.inputStream().use { it.copyTo(sink) } }
                    }
            }
            if (tmp.length() > 100_000) {
                if (!out.exists() || out.delete()) {
                    if (tmp.renameTo(out)) return out
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("Un1box", "CA bundle: ${e.message}")
        }
        tmp.delete()
        return out
    }
}
