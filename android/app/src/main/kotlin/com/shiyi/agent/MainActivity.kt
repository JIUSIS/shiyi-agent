package com.shiyi.agent

import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.system.Os
import android.view.WindowManager
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val ioExecutor = Executors.newSingleThreadExecutor()

    companion object {
        /** zip 炸弹防护：单包解压总量与条目上限（技能包导入、Termux 引导都适用）。 */
        private const val MAX_ZIP_TOTAL_BYTES = 512L * 1024 * 1024 // 512MB
        private const val MAX_ZIP_ENTRIES = 20000
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 手动启用 edge-to-edge（内容延伸到状态栏/导航栏后面）并强制系统栏透明：
        // targetSdk 降到 34 后系统不再强制，这里显式开启保持与原版一致的沉浸效果。
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
    }

    override fun onPostResume() {
        super.onPostResume()
        // Flutter 引擎在 resume 时切到 NormalTheme 会重置窗口背景，这里再按 App 主题覆盖一次。
        applyAppThemeBackground()
    }

    /** 启动时按 App 内主题设置窗口背景，避免系统深色模式下浅色主题先黑一下。 */
    private fun applyAppThemeBackground() {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val raw = prefs.getString("flutter.shiyi_settings_v1", null)
            var themeMode = "dark"
            if (raw != null && raw.isNotEmpty()) {
                themeMode = org.json.JSONObject(raw).optString("themeMode", "dark")
            }
            val dark = when (themeMode) {
                "light" -> false
                "system" -> {
                    val mode = resources.configuration.uiMode and
                        android.content.res.Configuration.UI_MODE_NIGHT_MASK
                    mode == android.content.res.Configuration.UI_MODE_NIGHT_YES
                }
                else -> true
            }
            window.decorView.setBackgroundColor(
                if (dark) 0xFF1E1E20.toInt() else 0xFFFFFFFF.toInt()
            )
        } catch (_: Exception) {
            // 读取失败时保持默认白色背景
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyi/skillpack")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "extractZip" -> {
                            val zipPath = call.argument<String>("zipPath")
                                ?: throw IllegalArgumentException("zipPath missing")
                            val destDir = call.argument<String>("destDir")
                                ?: throw IllegalArgumentException("destDir missing")
                            runInBackground(result) {
                                extractZip(zipPath, destDir)
                            }
                        }
                        "createZip" -> {
                            val srcDir = call.argument<String>("srcDir")
                                ?: throw IllegalArgumentException("srcDir missing")
                            val zipPath = call.argument<String>("zipPath")
                                ?: throw IllegalArgumentException("zipPath missing")
                            runInBackground(result) {
                                createZip(srcDir, zipPath)
                                true
                            }
                        }
                        "extractTermux" -> {
                            val assetPath = call.argument<String>("assetPath")
                                ?: throw IllegalArgumentException("assetPath missing")
                            val destDir = call.argument<String>("destDir")
                                ?: throw IllegalArgumentException("destDir missing")
                            runInBackground(result) {
                                extractTermux(assetPath, destDir)
                            }
                        }
                        "verifyApk" -> {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("path missing")
                            // 校验要解析整个 APK，放后台线程避免主线程卡 UI/ANR。
                            runInBackground(result) { verifyApk(path) }
                        }
                        "installApk" -> {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("path missing")
                            // 校验耗时长，放后台；startActivity 由 installApk 内部回主线程。
                            runInBackground(result) {
                                installApk(path)
                                true
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("SKILL_PACK_ERROR", e.message ?: e.toString(), null)
                }
            }
    }

    override fun onDestroy() {
        ioExecutor.shutdown()
        super.onDestroy()
    }

    /** 耗时的压缩/解压放到后台线程，避免 MethodChannel 主线程卡 UI/ANR。 */
    private fun runInBackground(
        result: MethodChannel.Result,
        block: () -> Any?,
    ) {
        ioExecutor.execute {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("SKILL_PACK_ERROR", e.message ?: e.toString(), null)
                }
            }
        }
    }

    /** 通过系统安装器安装更新包（FileProvider 暴露 APK 给 PackageInstaller）。 */
    private fun installApk(path: String) {
        val apk = File(path)
        if (!apk.exists()) throw IllegalStateException("APK 不存在: $path")
        if (!verifyApk(path)) {
            throw SecurityException("APK 签名校验失败，已取消安装")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /** 校验下载 APK 与当前已安装应用签名一致，防止镜像源篡改包。 */
    private fun verifyApk(path: String): Boolean {
        return try {
            val pm = packageManager
            val current = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                ?: return false
            val candidate = pm.getPackageArchiveInfo(path, PackageManager.GET_SIGNATURES)
                ?: return false
            val cur = current.signatures ?: return false
            val cand = candidate.signatures ?: return false
            if (cur.isEmpty() || cur.size != cand.size) return false
            cur.indices.all { i ->
                cur[i].toByteArray().contentEquals(cand[i].toByteArray())
            }
        } catch (_: Exception) {
            false
        }
    }

    /** 流式解压 zip 到目标目录，返回条目清单 [{path, size}]，全程不把压缩包读进内存。 */
    private fun extractZip(zipPath: String, destDir: String): List<Map<String, Any>> {
        val dest = File(destDir)
        dest.mkdirs()
        val entries = mutableListOf<Map<String, Any>>()
        ZipInputStream(BufferedInputStream(FileInputStream(zipPath))).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val name = entry.name.replace('\\', '/')
                if (!entry.isDirectory) {
                    val outFile = File(dest, name)
                    // 防目录穿越：只允许解压到目标目录内
                    val canonical = outFile.canonicalPath
                    if (canonical.startsWith(dest.canonicalPath + File.separator)) {
                        outFile.parentFile?.mkdirs()
                        var size = 0L
                        BufferedOutputStream(FileOutputStream(outFile)).use { out ->
                            val buf = ByteArray(64 * 1024)
                            var n = zis.read(buf)
                            while (n > 0) {
                                out.write(buf, 0, n)
                                size += n
                                n = zis.read(buf)
                            }
                        }
                        entries.add(mapOf("path" to name, "size" to size))
                    }
                }
                entry = zis.nextEntry
            }
        }
        return entries
    }

    /** 递归打包目录为 zip（流式），zipPath 为输出路径。 */
    private fun createZip(srcDir: String, zipPath: String) {
        val src = File(srcDir)
        val out = File(zipPath)
        out.parentFile?.mkdirs()
        ZipOutputStream(BufferedOutputStream(FileOutputStream(out))).use { zos ->
            fun addDir(dir: File, base: String) {
                dir.listFiles()?.forEach { f ->
                    if (f.isDirectory) {
                        addDir(f, "$base${f.name}/")
                    } else {
                        zos.putNextEntry(ZipEntry(base + f.name))
                        FileInputStream(f).use { input ->
                            val buf = ByteArray(64 * 1024)
                            var n = input.read(buf)
                            while (n > 0) {
                                zos.write(buf, 0, n)
                                n = input.read(buf)
                            }
                        }
                        zos.closeEntry()
                    }
                }
            }
            addDir(src, "")
        }
    }

    /**
     * 解压内嵌的 Termux bootstrap（来自 assets）到目标目录。
     * 与 TermuxInstaller 一致：SYMLINKS.txt 建符号链接、bin/libexec 等设可执行位、
     * 并把硬编码的 shebang 前缀 /data/data/com.termux/files/usr/bin/ 替换为实际路径。
     */
    private fun extractTermux(assetPath: String, destDirPath: String): Map<String, Any> {
        val dest = File(destDirPath)
        if (dest.exists()) dest.deleteRecursively()
        dest.mkdirs()
        val destCanonical = dest.canonicalPath
        val symlinks = mutableListOf<Pair<String, String>>()
        val assets = assets
        var fileCount = 0
        var totalBytes = 0L
        var entryCount = 0
        assets.open("flutter_assets/$assetPath").use { input ->
            ZipInputStream(BufferedInputStream(input)).use { zis ->
                var entry = zis.nextEntry
                while (entry != null) {
                    val name = entry.name.replace('\\', '/')
                    if (name == "SYMLINKS.txt") {
                        val content = zis.readBytes().toString(Charsets.UTF_8)
                        for (line in content.lineSequence()) {
                            val parts = line.split("←")
                            if (parts.size == 2) {
                                val target = File("$destDirPath/${parts[1]}")
                                // 符号链接目标也必须在解压目录内（防穿越）
                                if (target.canonicalPath.startsWith(destCanonical + File.separator)) {
                                    symlinks.add(parts[0] to target.canonicalPath)
                                }
                            }
                        }
                    } else if (!entry.isDirectory) {
                        if (++entryCount > MAX_ZIP_ENTRIES) {
                            throw IllegalStateException("压缩包条目过多（超过 $MAX_ZIP_ENTRIES），已中止解压")
                        }
                        // 防目录穿越（与 extractZip 对齐）：只允许解压到目标目录内
                        val outFile = File(dest, name)
                        val canonical = outFile.canonicalPath
                        if (!canonical.startsWith(destCanonical + File.separator)) {
                            throw IllegalStateException("非法解压路径: $name")
                        }
                        outFile.parentFile?.mkdirs()
                        BufferedOutputStream(FileOutputStream(outFile)).use { out ->
                            val buf = ByteArray(64 * 1024)
                            var n = zis.read(buf)
                            while (n > 0) {
                                totalBytes += n
                                if (totalBytes > MAX_ZIP_TOTAL_BYTES) {
                                    throw IllegalStateException("压缩包解压总量超限（> $MAX_ZIP_TOTAL_BYTES 字节），已中止")
                                }
                                out.write(buf, 0, n)
                                n = zis.read(buf)
                            }
                        }
                        if (name.startsWith("bin/") || name.startsWith("libexec") ||
                            name.startsWith("lib/apt/apt-helper") || name.startsWith("lib/apt/methods")
                        ) {
                            outFile.setExecutable(true, false)
                        }
                        if (name.startsWith("bin/") || name.startsWith("libexec")) {
                            // termux-apt 的 proot 绑定路径含 /data/data/com.termux，不能全局替换。
                            fixTermuxPaths(
                                outFile,
                                destDirPath,
                                skipGlobalRewrite = name == "bin/termux-apt",
                            )
                        }
                        fileCount++
                    }
                    entry = zis.nextEntry
                }
            }
        }
        for ((old, new) in symlinks) {
            try {
                val newFile = File(new)
                newFile.parentFile?.mkdirs()
                Os.symlink(old, new)
            } catch (_: Exception) {
                // 个别符号链接失败不阻塞整体
            }
        }
        return mapOf("files" to fileCount, "symlinks" to symlinks.size)
    }

    /**
     * 修复脚本里硬编码的 Termux 路径。
     * 文本脚本（无 NUL）：全局替换 /data/data/com.termux 系路径为内嵌路径；
     * 二进制（含 NUL）或 skipGlobalRewrite：只修文件开头 256 字节内的 shebang。
     * destDirPath 即内嵌 PREFIX（usr 目录）。
     */
    private fun fixTermuxPaths(
        file: File,
        destDirPath: String,
        skipGlobalRewrite: Boolean = false,
    ) {
        try {
            if (file.length() > 4L * 1024 * 1024) return
            val bytes = file.readBytes()
            if (skipGlobalRewrite || bytes.indexOf(0.toByte()) >= 0) {
                // 二进制 / 需要保留内嵌路径的脚本：只修 shebang 区
                val oldB = "/data/data/com.termux/files/usr/bin/".toByteArray()
                val newB = "$destDirPath/bin/".toByteArray()
                val idx = indexOf(bytes, oldB)
                if (idx in 0 until 256) {
                    val out = ByteArray(bytes.size - oldB.size + newB.size)
                    System.arraycopy(bytes, 0, out, 0, idx)
                    System.arraycopy(newB, 0, out, idx, newB.size)
                    System.arraycopy(
                        bytes, idx + oldB.size,
                        out, idx + newB.size,
                        bytes.size - idx - oldB.size,
                    )
                    file.writeBytes(out)
                }
            } else {
                // 文本：全局替换 Termux 硬编码路径
                val prefix = File(destDirPath).parent
                val oldUsr = "/data/data/com.termux/files/usr"
                val oldHome = "/data/data/com.termux/files/home"
                val oldCache = "/data/data/com.termux/cache"
                val oldPrefix = "/data/data/com.termux"
                val newUsr = destDirPath
                val newPrefix = prefix ?: destDirPath
                var text = String(bytes, Charsets.UTF_8)
                if (text.contains(oldUsr)) {
                    text = text.replace(oldUsr, newUsr)
                }
                if (text.contains(oldHome)) {
                    text = text.replace(oldHome, "$newPrefix/home")
                }
                if (text.contains(oldCache)) {
                    text = text.replace(oldCache, "$newPrefix/cache")
                }
                if (text.contains(oldPrefix)) {
                    text = text.replace(oldPrefix, newPrefix)
                }
                file.writeBytes(text.toByteArray(Charsets.UTF_8))
            }
        } catch (_: Exception) {
        }
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        if (needle.isEmpty()) return 0
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) {
                if (haystack[i + j] != needle[j]) continue@outer
            }
            return i
        }
        return -1
    }
}


