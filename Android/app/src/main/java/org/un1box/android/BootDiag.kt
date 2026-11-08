package org.un1box.android

import android.content.Context
import android.os.Process
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Boot diagnostics for devices where adb is unavailable: an append-only log in
 * the app's external files dir plus a crash hook, so the first-run loading
 * screen can show what went wrong instead of spinning forever.
 */
object BootDiag {
    @Volatile private var installed = false

    fun file(context: Context): File =
        File(context.getExternalFilesDir(null) ?: context.filesDir, "boot-diag.log")

    @Synchronized
    fun log(context: Context, message: String) {
        try {
            val f = file(context)
            if (f.length() > 512 * 1024) f.writeText("")
            val stamp = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
            f.appendText("$stamp pid=${Process.myPid()} [${Thread.currentThread().name}] $message\n")
        } catch (_: Throwable) { /* Diagnostics must never break the app. */ }
    }

    /** Last tail of the log, small enough to draw on screen for a screenshot. */
    @Synchronized
    fun tail(context: Context, chars: Int = 3500): String = try {
        val f = file(context)
        if (f.isFile) {
            val text = f.readText()
            if (text.length <= chars) text else "…\n" + text.substring(text.length - chars)
        } else "(no diagnostics recorded)"
    } catch (_: Throwable) { "(diagnostics unreadable)" }

    fun install(context: Context, tag: String) {
        val abi = android.os.Build.SUPPORTED_ABIS.joinToString(",")
        val device = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL} Android ${android.os.Build.VERSION.RELEASE} (sdk ${android.os.Build.VERSION.SDK_INT})"
        log(context, "$tag hello; device=$device; abi=$abi")
        if (installed) return
        installed = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            log(context, "$tag CRASH thread=${thread.name}: ${throwable.javaClass.name}: ${throwable.message}\n" +
                throwable.stackTraceToString() +
                (throwable.cause?.let { "cause: ${it.javaClass.name}: ${it.message}\n${it.stackTraceToString()}" } ?: ""))
            previous?.uncaughtException(thread, throwable)
        }
    }
}
