package org.un1box.android

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import androidx.compose.runtime.mutableStateOf
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Developer mode: a buffered, asynchronous detailed log with a single-switch
 * cost model. When it is off, [log] inlines to one volatile boolean read and
 * allocates nothing; when it is on, events go to a bounded background writer
 * that flushes a batch at most once a second, so no I/O happens on a UI or
 * engine thread. [export] collects every log the app owns into one zip in
 * Download/Un1box for a human to send off for analysis.
 */
object DevMode {
    private const val PREFS = "devmode"
    private const val KEY = "detailedLog"

    private val state = mutableStateOf(false)
    var enabled: Boolean get() = state.value
        private set(v) { state.value = v }

    /** Public for the inline [log] fast path; kept in lockstep with [enabled]. */
    @Volatile @JvmField var logging = false

    /** Public for the inline [log] fast path. */
    @JvmField val lines = LinkedBlockingQueue<String>()
    private val stopping = AtomicBoolean(false)
    @Volatile private var session: File? = null
    @Volatile private var writer: Thread? = null
    @Volatile private var started = false

    fun init(context: Context) {
        val app = context.applicationContext
        val on = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, false)
        enabled = on
        logging = on
        if (on) startWriter(app)
        if (!started) {
            started = true
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                log("crash") { "thread=${thread.name} ${error.javaClass.name}: ${error.message}\n${error.stackTraceToString()}" }
                flushNow(app)
                previous?.uncaughtException(thread, error)
            }
        }
    }

    fun setEnabled(context: Context, on: Boolean) {
        val app = context.applicationContext
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, on).apply()
        enabled = on
        logging = on
        if (on) { startWriter(app); log("dev") { "developer mode enabled" } }
        else { log("dev") { "developer mode disabled" }; flushNow(app); stopWriter() }
    }

    /** Inline so an off switch costs one volatile read and no allocation. */
    inline fun log(tag: String, crossinline message: () -> String) {
        if (!logging) return
        val at = System.currentTimeMillis()
        val text = try { message() } catch (e: Throwable) { "<log failed: ${e.javaClass.name}>" }
        lines.offer("$at [$tag] $text")
    }

    private fun startWriter(context: Context) {
        if (writer?.isAlive == true) return
        synchronized(this) {
            if (writer?.isAlive == true) return
            val dir = File(context.filesDir, "devlogs").apply { mkdirs() }
            val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.ROOT).format(Date())
            val file = File(dir, "session-$stamp.log")
            session = file
            runCatching { file.appendText(header(context)) }
            stopping.set(false)
            writer = Thread({
                val out = BufferedWriter(FileWriter(file, true), 16 * 1024)
                try {
                    while (!stopping.get() || lines.isNotEmpty()) {
                        val first = lines.poll(1, TimeUnit.SECONDS) ?: continue
                        out.write(first); out.newLine()
                        var n = 0
                        while (n < 255) {
                            val line = lines.poll() ?: break
                            out.write(line); out.newLine(); n++
                        }
                        out.flush()
                    }
                } catch (_: Exception) {
                } finally { runCatching { out.close() } }
            }, "devlog-writer").apply { isDaemon = true; start() }
        }
    }

    private fun flushNow(context: Context) {
        val file = session ?: return
        runCatching {
            BufferedWriter(FileWriter(file, true), 16 * 1024).use { out ->
                while (true) { val line = lines.poll() ?: break; out.write(line); out.newLine() }
            }
        }
    }

    private fun stopWriter() {
        stopping.set(true)
        writer?.interrupt()
        writer = null
    }

    private fun header(context: Context) = buildString {
        appendLine("Un1box developer log, started ${Date()}")
        appendLine("device=${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE}) Android ${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT}")
        appendLine("abis=${Build.SUPPORTED_ABIS.joinToString(",")} version=${BuildConfig.VERSION_NAME} debug=${BuildConfig.DEBUG}")
        appendLine("files=${context.filesDir.path} nativeLib=${context.applicationInfo.nativeLibraryDir}")
        appendLine("------------------------------------------------------------")
    }

    /** Engine environment lines in files/debug-env; EngineService setenv's them at guest start. */
    fun debugEnv(context: Context, key: String): String? = runCatching {
        File(context.filesDir, "debug-env").takeIf { it.isFile }?.readLines()
            ?.firstOrNull { it.trim().startsWith("$key=") }?.substringAfter('=')?.trim()
    }.getOrNull()

    fun setDebugEnv(context: Context, key: String, value: String?) {
        runCatching {
            val file = File(context.filesDir, "debug-env")
            val kept = if (file.isFile) file.readLines().filter { it.isNotBlank() && !it.trim().startsWith("$key=") } else emptyList()
            val next = kept + if (value == null) emptyList() else listOf("$key=$value")
            if (next.isEmpty()) file.delete() else file.writeText(next.joinToString("\n") + "\n")
            log("perf") { "debug-env $key=${value ?: "(default)"} (applies at next guest start)" }
        }
    }

    /**
     * Everything the app owns, in one zip: developer sessions, firmwarekit and
     * jailbreak logs, boot diagnostics, the last logcat buffer, the engine
     * environment and a settings snapshot. Returns the Download path.
     */
    fun export(context: Context): String {
        val app = context.applicationContext
        flushNow(app)
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.ROOT).format(Date())
        val name = "un1box-dev-$stamp.zip"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "application/zip")
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/Un1box")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val resolver = app.contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("Cannot create the export in Downloads")
        try {
            resolver.openOutputStream(uri)?.use { raw -> ZipOutputStream(raw).use { zip ->
                fun entry(path: String, bytes: ByteArray) {
                    zip.putNextEntry(ZipEntry(path)); zip.write(bytes); zip.closeEntry()
                }
                fun fileEntry(path: String, file: File?) {
                    if (file?.isFile != true) return
                    entry(path, runCatching { file.readBytes() }.getOrDefault(ByteArray(0)))
                }
                entry("README.txt", buildString {
                    appendLine("Un1box developer log export ${Date()}")
                    appendLine("Send this zip as-is. It contains no account credentials or personal files.")
                    appendLine("Contents: devlogs/ (app events), logs/ (firmwarekit, jailbreak, boot, logcat),")
                    appendLine("state/ (device record), prefs.txt, debug-env.txt, device.txt.")
                }.toByteArray())
                entry("device.txt", header(app).toByteArray())
                File(app.filesDir, "devlogs").listFiles()?.sortedBy { it.name }?.forEach {
                    fileEntry("devlogs/${it.name}", it)
                }
                fileEntry("logs/firmwarekit.log", File(app.cacheDir, "firmwarekit.log"))
                fileEntry("logs/jailbreak.log", File(app.cacheDir, "jailbreak.log"))
                fileEntry("logs/boot-diag.log", File(app.getExternalFilesDir(null) ?: app.filesDir, "boot-diag.log"))
                fileEntry("debug-env.txt", File(app.filesDir, "debug-env"))
                File(app.filesDir, "library/records").listFiles()?.forEach { record ->
                    fileEntry("state/${record.name}/record.json", File(record, "record.json"))
                }
                entry("logcat.txt", runCatching {
                    val process = Runtime.getRuntime().exec(arrayOf("logcat", "-d", "-v", "threadtime", "-t", "4000"))
                    val text = process.inputStream.bufferedReader().use { it.readText() }
                    runCatching { process.waitFor() }
                    text.ifEmpty { "(logcat returned no lines; the app may not have READ_LOGS on this Android version)" }.toByteArray()
                }.getOrElse { "(logcat unavailable: ${it.message})".toByteArray() })
                entry("prefs.txt", buildString {
                    for (name in listOf("ui", PREFS, "preparation-imports")) {
                        val p = app.getSharedPreferences(name, Context.MODE_PRIVATE)
                        appendLine("[$name]"); p.all.toSortedMap().forEach { (k, v) -> appendLine("$k=$v") }
                    }
                }.toByteArray())
            } } ?: error("Cannot open the export stream")
        } finally {
            val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
        }
        return "Download/Un1box/$name"
    }
}
