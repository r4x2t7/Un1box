package org.un1box.android

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

/**
 * firmwarekit edit --action jailbreak on a device already in the library: Cydia, afc2 and Substrate onto its system
 * volume, and on the K48 family the jailbroken boot-args into its boot files (K48Board.jailbreakBootFiles). The
 * device keeps its apps and data; its lock says `jailbroken` afterwards, and firmwarekit refuses a second run.
 *
 * A short job next to the app rather than a worker of its own: it needs no QEMU and no foreground service, and the
 * stopped-volume edit recovers on its own (edit --action recover) if the process is killed midway.
 */
internal object Jailbreak {
    /** Where the library keeps one record (base, state, assets and its lock). */
    fun record(context: Context, id: String) = File(context.filesDir, "library/records/$id")

    /** The lock firmwarekit wrote for the record, or null where the record has none. */
    private fun lock(context: Context, id: String): JSONObject? = try {
        JSONObject(File(record(context, id), "device.lock.json").readText())
    } catch (_: Exception) { null }

    /** Whether firmwarekit's lock for this record says it was prepared, or later made, jailbroken. */
    fun isJailbroken(context: Context, id: String): Boolean = lock(context, id)?.optBoolean("jailbroken") == true

    /** Why the jailbreak would be refused, or null where it can run: a stopped device of iPhone OS 2.0 or later. */
    fun unavailable(context: Context, id: String, running: Boolean): String? {
        val l = lock(context, id) ?: return "This device's lock is unreadable"
        if (running) return "Stop the device before jailbreaking it"
        if (l.optBoolean("jailbroken")) return "Already jailbroken"
        val major = l.optString("product_version").substringBefore('.').toIntOrNull() ?: 0
        if (major < 2) return "Needs iPhone OS 2.0 or later"
        if (l.optString("board") == "n72ap") return "Not on iPod touch 2G yet: Substrate's launchd hook hangs it after the first restart"
        return null
    }

    /**
     * Run the edit, reporting firmwarekit's own lines ("Cydia: freeze.tar.gz, ...") to `onStage`. Returns the last
     * line, which names what changed. Throws with firmwarekit's message where it fails.
     */
    suspend fun run(context: Context, id: String, onStage: (String) -> Unit): String = withContext(Dispatchers.IO) {
        val libs = File(context.applicationInfo.nativeLibraryDir)
        val cache = File(context.cacheDir, "jailbreak").apply { mkdirs() }
        val log = File(context.cacheDir, "jailbreak.log").apply { parentFile?.mkdirs() }
        val command = listOf(
            File(libs, "libfirmwarekit.so").path, "edit",
            "--device", record(context, id).absolutePath, "--action", "jailbreak",
            // Cydia's bootstrap (freeze.tar.gz and the Substrate debs) is downloaded beside this cache.
            "--cache", File(cache, "firmwarekit").path,
        )
        CaBundle.ensure(context)
        JailbreakAssets.seed(context, File(cache, "firmwarekit"))
        val child = ProcessBuilder(command).redirectError(log).apply {
            environment().apply {
                put("LTM_QEMU_DYLIB", File(libs, "libqemu-arm.so").path)
                put("LD_LIBRARY_PATH", libs.path)
                put("HOME", context.filesDir.path); put("TMPDIR", context.cacheDir.path)
            }
        }.start()
        var message = ""
        var last = ""
        child.inputStream.bufferedReader().forEachLine { line ->
            val event = try { JSONObject(line) } catch (_: Exception) { return@forEachLine }
            if (event.optString("event") == "error") message = event.optString("message")
            else if (event.optBoolean("jailbroken")) last = "jailbroken"
        }
        val exit = child.waitFor()
        DevMode.log("jailbreak") { "firmwarekit edit exit=$exit message=$message last=$last" }
        // What firmwarekit logged, its last line: "kboot.bin: boot-args += amfi_get_out_of_my_way=1" and the like.
        val said = runCatching { log.readLines().lastOrNull { it.isNotBlank() }?.removePrefix("firmwarekit edit: ") }.getOrNull()
        if (exit != 0) throw IllegalStateException(message.ifEmpty { said ?: "firmwarekit edit failed (exit $exit)" })
        said ?: last
    }
}
