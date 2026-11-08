package org.un1box.android

import android.content.Context
import android.os.SystemClock
import android.util.Log
import java.io.File

/**
 * What `assets/substrate` carries, written into the guest's
 * /Library/MobileSubstrate/DynamicLibraries once the guest is up.
 *
 * The engine's agent `put` (LT_GUEST_PUT_FILE) does the writing: it runs as root inside the
 * guest, creates the file beside its target and renames it into place, so no shell, no dpkg and
 * no AFC connection are involved. A file lands as root:wheel with the mode given here, which is
 * what Substrate expects of an extension.
 *
 * Substrate loads extensions when a process starts, so what this installs takes effect on the
 * guest's next launch of the hooked process (SpringBoard included, which is why the caller
 * restarts the guest rather than expecting the running one to pick the new files up).
 */
internal object SubstratePlugins {
    private const val TAG = "SubstratePlugins"
    private const val ROOT = "substrate"
    const val DIRECTORY = "/Library/MobileSubstrate/DynamicLibraries"
    private const val MODE_0644 = 0x1A4
    private const val WAIT_MS = 6_000
    private const val BUSY_RETRIES = 3
    /** Written by the UI, consumed by the engine worker: both processes see filesDir. */
    private const val REQUEST = "substrate-probe-request"

    /** Asks the worker for one probe on its next tick, without waiting for a new guest boot. */
    fun requestProbe(context: Context) {
        runCatching { File(context.filesDir, REQUEST).writeText("1") }
    }

    /** True once per request: consumes the marker so a probe does not run every tick. */
    fun takeProbeRequest(context: Context): Boolean {
        val marker = File(context.filesDir, REQUEST)
        if (!marker.exists()) return false
        marker.delete()
        return true
    }

    /** True while a guest is at a state where the agent answers. */
    fun guestReady(engine: IEngine): Boolean = try {
        engine.status().getString("state") in listOf("running", "paused")
    } catch (_: Exception) {
        false
    }

    /**
     * Writes every bundled file. Returns "" on success, otherwise the first failure; never throws.
     * Idempotent: the agent replaces the file each time, so running it twice is harmless.
     */
    fun install(context: Context, engine: IEngine): String {
        return try {
            val names = context.assets.list(ROOT)?.sorted().orEmpty()
            if (names.isEmpty()) return ""
            for (name in names) {
                val bytes = context.assets.open("$ROOT/$name").use { it.readBytes() }
                if (bytes.isEmpty()) return "$name is empty"
                val failure = write(engine, "$DIRECTORY/$name", bytes)
                DevMode.log("substrate") { "write $name (${bytes.size} bytes): ${if (failure.isEmpty()) "ok" else failure}" }
                if (failure.isNotEmpty()) return "$name: $failure"
                Log.i(TAG, "wrote $DIRECTORY/$name (${bytes.size} bytes)")
            }
            ""
        } catch (e: Exception) {
            e.message ?: "substrate install failed"
        }
    }

    private fun write(engine: IEngine, path: String, bytes: ByteArray): String {
        var attempt = 0
        while (true) {
            val accepted = engine.guestPut(path, MODE_0644, bytes, WAIT_MS)
            val reported = accepted.getString("error").orEmpty()
            // One guest request may be pending at a time; the profiler's own frontmost query
            // holds it briefly, so a busy engine is worth another try rather than a failure.
            if (reported.isEmpty()) return settle(engine, accepted.getLong("requestId"))
            if (!reported.contains("pending", ignoreCase = true) || ++attempt > BUSY_RETRIES) return reported
            Thread.sleep(250)
        }
    }

    private fun settle(engine: IEngine, requestId: Long): String {
        val deadline = SystemClock.elapsedRealtime() + WAIT_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            val reply = engine.guestPoll(requestId)
            val reported = reply.getString("error").orEmpty()
            if (reported.isNotEmpty()) return reported
            when (reply.getInt("state")) {
                2 -> return if (reply.getInt("guestStatus") == 0) "" else "guest status ${reply.getInt("guestStatus")}"
                3 -> return "rejected"
                4 -> return "cancelled"
                5 -> return "timed out"
            }
            Thread.sleep(20)
        }
        engine.guestCancel(requestId)
        return "timed out"
    }

    /** Reads a small window from each file the Substrate chain needs, so the devlog can tell
     * presence (state complete, status 0) from absence (status -2) — the ground truth a
     * successful `put` cannot give on its own. Then runs a few root shell commands inside
     * the guest: the process list proves whether Substrate actually loaded (each process
     * that loaded it has MobileSubstrate.dylib mapped), and a directory listing proves what
     * the loader sees. Returns a multi-line human-readable report. */
    fun probe(engine: IEngine): String {
        val paths = listOf(
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            "/usr/lib/libsubstrate.dylib",
            "$DIRECTORY/it_typein.dylib",
            "$DIRECTORY/iapunlock.dylib",
            "$DIRECTORY/iapunlock.plist",
            // Written by iapunlock.dylib's constructor the instant Substrate runs it in any
            // process: present here proves the extension is actually loading, not just on disk.
            "/var/mobile/Documents/.iapunlock-loaded",
            "$DIRECTORY/patcyh.dylib",
            "/var/lib/dpkg/status",
        )
        val files = paths.joinToString("\n") { path ->
            val note = readHead(engine, path, if (path.endsWith("/status")) 1998 else 32)
            "$path -> $note"
        }
        // The firmware has only sh/ls/cat/grep/launchctl — no head, no -o. Keep each
        // command's output under ~1.4 KB so the 4 KiB poll buffer always fits.
        // These answer the one question that matters: is Substrate's injection chain whole
        // (package registered, loader present, daemon running), or does only the file exist?
        // The one-shot Substrate repair (inject SubstrateLauncher into launchd, then respring)
        // runs ONLY when Substrate itself is installed — cynject exists. On any other model or
        // a clean image those commands would either fail outright or needlessly bounce
        // SpringBoard, so the repair degrades to a read-only check of the load marker.
        val repairable = readHead(engine, "/Library/Frameworks/CydiaSubstrate.framework/Commands/cynject", 16).startsWith("present")
        val commands = if (repairable) listOf(
            "/Library/Frameworks/CydiaSubstrate.framework/Commands/cynject 1 /Library/Frameworks/CydiaSubstrate.framework/Libraries/SubstrateLauncher.dylib 2>&1 | dd bs=1000 count=1; echo ENDINJECT",
            "killall SpringBoard 2>&1; echo KILLEXIT",
            "sleep 8; ls -la /var/mobile/Documents/.iapunlock-loaded 2>&1",
            "ls -la /Library/MobileSubstrate/DynamicLibraries 2>&1",
        ) else listOf(
            "ls -la /var/mobile/Documents/.iapunlock-loaded 2>&1",
            "ls -la /Library/MobileSubstrate/DynamicLibraries 2>&1",
        )
        val shell = commands.joinToString("\n") { command ->
            "_exec_ $command\n" + runCommand(engine, command)
        }
        return "$files\n$shell"
    }

    /** One root /bin/sh -c round trip; output is the merged stdout/stderr (truncated), the
     * guest status is the command's exit code. */
    private fun runCommand(engine: IEngine, command: String): String {
        return try {
            val accepted = engine.guestExec(command, null, WAIT_MS)
            val reported = accepted.getString("error").orEmpty()
            if (reported.isNotEmpty()) return reported
            val deadline = SystemClock.elapsedRealtime() + WAIT_MS
            while (SystemClock.elapsedRealtime() < deadline) {
                val reply = engine.guestPoll(accepted.getLong("requestId"))
                val error = reply.getString("error").orEmpty()
                if (error.isNotEmpty()) { engine.guestCancel(accepted.getLong("requestId")); return error }
                when (reply.getInt("state")) {
                    2, 3 -> {
                        val output = reply.getString("output").orEmpty().trim()
                        val code = reply.getInt("guestStatus")
                        return if (output.isEmpty()) "exit $code, no output" else "exit $code: ${output.take(1400)}"
                    }
                    4 -> return "cancelled"
                    5 -> return "timed out"
                }
                Thread.sleep(20)
            }
            engine.guestCancel(accepted.getLong("requestId"))
            "timed out"
        } catch (e: Exception) {
            e.message ?: "exec failed"
        }
    }

    private fun readHead(engine: IEngine, path: String, limit: Int): String {
        return try {
            val accepted = engine.guestRead(path, 0, limit, WAIT_MS)
            val reported = accepted.getString("error").orEmpty()
            if (reported.isNotEmpty()) return reported
            val deadline = SystemClock.elapsedRealtime() + WAIT_MS
            while (SystemClock.elapsedRealtime() < deadline) {
                val reply = engine.guestPoll(accepted.getLong("requestId"))
                val error = reply.getString("error").orEmpty()
                if (error.isNotEmpty()) { engine.guestCancel(accepted.getLong("requestId")); return error }
                when (reply.getInt("state")) {
                    2, 3 -> {
                        val status = reply.getInt("guestStatus")
                        return when {
                            status == 0 -> "present (${(reply.getString("output")?.length ?: 0) / 2}+ bytes)"
                            status == -21 -> "not a file (directory)"
                            else -> "errno $status (${errnoName(status)})"
                        }
                    }
                    4 -> return "cancelled"
                    5 -> return "timed out"
                }
                Thread.sleep(20)
            }
            engine.guestCancel(accepted.getLong("requestId"))
            "timed out"
        } catch (e: Exception) {
            e.message ?: "read failed"
        }
    }

    private fun errnoName(status: Int): String = when (status) {
        -1 -> "EPERM"; -2 -> "ENOENT"; -13 -> "EACCES"; -20 -> "ENOTDIR"
        -21 -> "EISDIR"; -36 -> "ENAMETOOLONG"; -12 -> "ENOMEM"; -5 -> "EIO"
        else -> "errno $status"
    }
}
