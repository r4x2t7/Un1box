package org.un1box.android

import android.content.Context
import java.io.File

/**
 * Cydia's bootstrap tarballs are pinned in firmwarekit (SHA-1 checked) and
 * normally downloaded from raw.githubusercontent.com, which is unreachable on
 * many mobile networks. Ship them in the APK instead: firmwarekit's
 * Cydia.bootstrap() skips any file already present with the right bytes, so
 * seeding this directory makes preparation fully offline-capable.
 *
 * The bootstrap lives beside the decrypt cache: cacheRoot's parent + "Jailbreak".
 * Preparation uses cacheDir/firmwarekit; a later jailbreak edit uses
 * cacheDir/jailbreak/firmwarekit, hence the caller passes its own cacheRoot.
 */
object JailbreakAssets {
    private val names = listOf("freeze.tar.gz", "cydiasubstrate.tar", "cydiahttpatch.tar")
    // aapt2 gunzips *.gz assets and renames them to *.tar, so the compressed
    // bootstrap ships under a .bin name and is written back as freeze.tar.gz.
    private fun assetName(name: String) = if (name.endsWith(".gz")) "$name.bin" else name

    fun seed(context: Context, cacheRoot: File) {
        val dir = File(cacheRoot.parentFile, "Jailbreak")
        if (!dir.exists() && !dir.mkdirs()) return
        for (name in names) {
            val out = File(dir, name)
            try {
                context.assets.open("jailbreak/${assetName(name)}").use { input ->
                    out.outputStream().buffered().use { sink -> input.copyTo(sink) }
                }
            } catch (e: Exception) {
                android.util.Log.w("Un1box", "jailbreak asset $name: ${e.message}")
            }
        }
    }
}
