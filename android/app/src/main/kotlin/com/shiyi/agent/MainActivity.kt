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
        // 手动启用 edge-to-edge（内容延伸到状态栏/导航栏后面）并强制系统栏透明。
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // 输入法弹出时关闭系统导航栏对比度 scrim，避免键盘上方出现灰色长条。
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
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
        // Android 系统代理读取（DSH 安装/更新走代理）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyi/system_proxy")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getProxy" -> {
                        val proxy = systemProxy()
                        if (proxy == null) {
                            result.success(null)
                        } else {
                            result.success(mapOf("host" to proxy.host, "port" to proxy.port))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyi/background_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sync" -> {
                        val activeSessions = call.argument<Int>("activeSessions") ?: 0
                        val relayEnabled = call.argument<Boolean>("relayEnabled") ?: false
                        ShiyiBackgroundService.sync(
                            applicationContext,
                            activeSessions,
                            relayEnabled,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
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
                        "extractTarGz" -> {
                            val assetPath = call.argument<String>("assetPath")
                                ?: throw IllegalArgumentException("assetPath missing")
                            val destDir = call.argument<String>("destDir")
                                ?: throw IllegalArgumentException("destDir missing")
                            runInBackground(result) {
                                extractTarGz(assetPath, destDir)
                            }
                        }
                        "verifyApk" -> {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("path missing")
                            // 校验要解析整个 APK，放后台线程避免主线程卡 UI/ANR。
                            runInBackground(result) { verifyApk(path) }
                        }
                        "nativeLibraryDir" -> {
                            result.success(applicationInfo.nativeLibraryDir)
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

    /** 读取 Android 系统代理（WiFi/APN 设置里的 HTTP 代理），无则返回 null。 */
    private fun systemProxy(): android.net.ProxyInfo? {
        return try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
            cm.defaultProxy
        } catch (_: Exception) {
            null
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

    /** 通过系统安装器安装更新包（FileProvider 暴露 APK 给 PackageInstaller）。
     *  签名校验耗时，调用方应在后台线程执行；startActivity 回主线程。 */
    private fun installApk(path: String) {
        val apk = File(path)
        if (!apk.exists()) throw IllegalStateException("APK 不存在: $path")
        if (!verifyApk(path)) {
            throw SecurityException("APK 签名校验失败，已取消安装")
        }
        runOnUiThread {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        }
    }

    /** 读取安装包签名：API 28+ 用 GET_SIGNING_CERTIFICATES，旧系统回退 GET_SIGNATURES。 */
    @Suppress("DEPRECATION")
    private fun loadSignatures(pm: PackageManager, path: String?): Array<Signature>? {
        return if (path == null) {
            if (Build.VERSION.SDK_INT >= 28) {
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                    ?.signingInfo?.apkContentsSigners
            } else {
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)?.signatures
            }
        } else {
            if (Build.VERSION.SDK_INT >= 28) {
                pm.getPackageArchiveInfo(path, PackageManager.GET_SIGNING_CERTIFICATES)
                    ?.signingInfo?.apkContentsSigners
            } else {
                pm.getPackageArchiveInfo(path, PackageManager.GET_SIGNATURES)?.signatures
            }
        }
    }

    /** 校验下载 APK 与当前已安装应用签名一致，防止镜像源篡改包。 */
    private fun verifyApk(path: String): Boolean {
        return try {
            val pm = packageManager
            val cur = loadSignatures(pm, null) ?: return false
            val cand = loadSignatures(pm, path) ?: return false
            if (cur.isEmpty() || cur.size != cand.size) return false
            // 无序匹配：每个已安装签名都能在候选包里找到相等者
            //（多签名 APK 的顺序可能不同，按位置比较会误拒）。
            cur.all { a -> cand.any { b -> a.toByteArray().contentEquals(b.toByteArray()) } }
        } catch (_: Exception) {
            false
        }
    }

    /** 流式解压 zip 到目标目录，返回条目清单 [{path, size}]，全程不把压缩包读进内存。 */
    private fun extractZip(zipPath: String, destDir: String): List<Map<String, Any>> {
        val dest = File(destDir)
        dest.mkdirs()
        val entries = mutableListOf<Map<String, Any>>()
        var totalBytes = 0L
        var entryCount = 0
        ZipInputStream(BufferedInputStream(FileInputStream(zipPath))).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val name = entry.name.replace('\\', '/')
                if (!entry.isDirectory) {
                    if (++entryCount > MAX_ZIP_ENTRIES) {
                        throw IllegalStateException("压缩包条目过多（超过 $MAX_ZIP_ENTRIES），已中止解压")
                    }
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
                                totalBytes += n
                                if (totalBytes > MAX_ZIP_TOTAL_BYTES) {
                                    throw IllegalStateException("压缩包解压总量超限（> $MAX_ZIP_TOTAL_BYTES 字节），已中止")
                                }
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
     * 解压内嵌的 Alpine minirootfs（assets 的 .tar.gz）到目标目录。
     * 自实现 tar 解析：支持普通文件 / 目录 / 符号链接 / 硬链接（复制兜底，
     * Android 应用数据分区禁 hard link）/ GNU longname / longlink；
     * 防目录穿越 + 条目/总量上限（与 extractZip 同规格）。
     */
    private fun extractTarGz(assetPath: String, destDirPath: String): Map<String, Any> {
        val dest = File(destDirPath)
        dest.mkdirs()
        // 注意：不能 deleteRecursively 重建——rootfs 里可能已有用户安装的包
        //（node/npm/dsh 等），误判版本重建时删除会清掉它们。改为覆盖式解压：
        // 同名文件覆盖、目录合并、符号链接重建，已有内容全部保留。
        val destCanonical = dest.canonicalPath
        val symlinks = mutableListOf<Pair<String, String>>()
        var fileCount = 0
        var totalBytes = 0L
        var entryCount = 0
        val buf = ByteArray(512)
        assets.open("flutter_assets/$assetPath").use { input ->
            java.util.zip.GZIPInputStream(BufferedInputStream(input)).use { gz ->
                var pendingName: String? = null
                var pendingLink: String? = null
                while (true) {
                    val read = readFully(gz, buf)
                    if (read == -1) break
                    if (read < 512) throw IllegalStateException("tar 头不完整（$read 字节）")
                    val name = tarString(buf, 0, 100)
                    if (name.isEmpty()) break
                    val size = tarOctal(buf, 124, 12)
                    val type = buf[156].toInt().toChar()
                    var linkName = tarString(buf, 157, 100)
                    // GNU 扩展头：真正的名字/链接名在下一块。
                    var realName = name
                    if (type == 'L') {
                        pendingName = tarPayloadString(gz, size)
                        continue
                    }
                    if (type == 'K') {
                        pendingLink = tarPayloadString(gz, size)
                        continue
                    }
                    if (pendingName != null) {
                        realName = pendingName
                        pendingName = null
                    }
                    if (pendingLink != null) {
                        linkName = pendingLink
                        pendingLink = null
                    }
                    realName = realName.replace('\\', '/')
                    // 规范化 tar 根条目（GNU tar 常见 "./" 前缀）：去掉前缀，
                    // 空名或 "." 等价于目标目录本身，直接建目录后跳过。
                    while (realName.startsWith("./")) {
                        realName = realName.substring(2)
                    }
                    if (realName.isEmpty()) {
                        dest.mkdirs()
                        skipTarPayload(gz, size)
                        val pad0 = ((size + 511) / 512) * 512 - size
                        skipBytes(gz, pad0)
                        continue
                    }
                    val target = File(dest, realName)
                    val targetCanonical = target.canonicalPath
                    val insideDest = targetCanonical == destCanonical ||
                        targetCanonical.startsWith(destCanonical + File.separator)
                    if (!insideDest) {
                        throw IllegalStateException("非法解压路径: $realName")
                    }
                    when (type) {
                        '5' -> target.mkdirs()
                        '2' -> {
                            // 符号链接：目标允许在 rootfs 内任意位置（相对/绝对）。
                            if (++entryCount > MAX_ZIP_ENTRIES) {
                                throw IllegalStateException("压缩包条目过多（超过 $MAX_ZIP_ENTRIES），已中止解压")
                            }
                            symlinks.add(linkName to target.absolutePath)
                            fileCount++
                        }
                        '1' -> {
                            // 硬链接：目标指向 rootfs 内已有文件，复制兜底。
                            if (++entryCount > MAX_ZIP_ENTRIES) {
                                throw IllegalStateException("压缩包条目过多（超过 $MAX_ZIP_ENTRIES），已中止解压")
                            }
                            val srcFile = File(dest, linkName)
                            target.parentFile?.mkdirs()
                            srcFile.copyTo(target, overwrite = true)
                            fileCount++
                        }
                        '0', '\u0000' -> {
                            // 普通文件。
                            if (++entryCount > MAX_ZIP_ENTRIES) {
                                throw IllegalStateException("压缩包条目过多（超过 $MAX_ZIP_ENTRIES），已中止解压")
                            }
                            target.parentFile?.mkdirs()
                            val mode = tarOctal(buf, 100, 8)
                            BufferedOutputStream(FileOutputStream(target)).use { out ->
                                var remaining = size
                                while (remaining > 0) {
                                    val n = gz.read(buf, 0, minOf(remaining, buf.size.toLong()).toInt())
                                    if (n <= 0) throw IllegalStateException("tar 数据不完整")
                                    totalBytes += n
                                    if (totalBytes > MAX_ZIP_TOTAL_BYTES) {
                                        throw IllegalStateException("压缩包解压总量超限（> $MAX_ZIP_TOTAL_BYTES 字节），已中止")
                                    }
                                    out.write(buf, 0, n)
                                    remaining -= n
                                }
                            }
                            if (mode and 0x49L != 0L) {
                                target.setExecutable(true, false)
                            }
                            if (mode and 0x24L != 0L) {
                                target.setWritable(true, false)
                            }
                            if (mode and 0x92L != 0L) {
                                target.setReadable(true, false)
                            }
                            fileCount++
                        }
                        else -> {
                            // 设备/管道等特殊条目：跳过数据。
                            skipTarPayload(gz, size)
                        }
                    }
                    // tar 块按 512 对齐，跳过填充。
                    val pad = ((size + 511) / 512) * 512 - size
                    skipBytes(gz, pad)
                }
            }
        }
        for ((old, new) in symlinks) {
            try {
                val newFile = File(new)
                newFile.parentFile?.mkdirs()
                if (newFile.exists()) newFile.delete()
                Os.symlink(old, new)
            } catch (_: Exception) {
                // 个别符号链接失败不阻塞整体
            }
        }
        return mapOf("files" to fileCount, "symlinks" to symlinks.size)
    }

    private fun readFully(input: java.io.InputStream, buf: ByteArray): Int {
        var total = 0
        while (total < buf.size) {
            val n = input.read(buf, total, buf.size - total)
            if (n < 0) return if (total == 0) -1 else total
            if (n == 0) throw IllegalStateException("tar 流读取停滞")
            total += n
        }
        return total
    }

    private fun skipBytes(input: java.io.InputStream, count: Long) {
        var remaining = count
        val buf = ByteArray(512)
        while (remaining > 0) {
            val n = input.read(buf, 0, minOf(remaining, buf.size.toLong()).toInt())
            if (n <= 0) throw IllegalStateException("tar 填充数据不完整")
            remaining -= n
        }
    }

    private fun skipTarPayload(input: java.io.InputStream, size: Long) {
        var remaining = size
        val buf = ByteArray(4096)
        while (remaining > 0) {
            val n = input.read(buf, 0, minOf(remaining, buf.size.toLong()).toInt())
            if (n <= 0) throw IllegalStateException("tar 数据不完整")
            remaining -= n
        }
    }

    private fun tarPayloadString(input: java.io.InputStream, size: Long): String {
        val bytes = ByteArray(size.toInt())
        var off = 0
        while (off < bytes.size) {
            val n = input.read(bytes, off, bytes.size - off)
            if (n <= 0) throw IllegalStateException("tar 扩展头数据不完整")
            off += n
        }
        val pad = ((size + 511) / 512) * 512 - size
        skipBytes(input, pad)
        return String(bytes, Charsets.UTF_8).trimEnd('\u0000')
    }

    private fun tarString(buf: ByteArray, offset: Int, length: Int): String {
        var end = offset
        val limit = offset + length
        while (end < limit && buf[end] != 0.toByte()) end++
        return String(buf, offset, end - offset, Charsets.UTF_8)
    }

    private fun tarOctal(buf: ByteArray, offset: Int, length: Int): Long {
        var end = offset
        val limit = offset + length
        while (end < limit && buf[end] != 0.toByte()) end++
        val s = String(buf, offset, end - offset, Charsets.US_ASCII).trim()
        if (s.isEmpty()) return 0L
        // 支持 GNU base-256 编码：首字节 0x80 标志，数值在字段最后 8 字节
        //（前面是 0xff 填充，从 offset+4 起读 8 字节）。
        if (buf[offset].toInt() and 0x80 != 0) {
            var v = 0L
            for (i in offset + 4 until offset + 12) {
                v = (v shl 8) or (buf[i].toLong() and 0xFF)
            }
            return v and 0x7FFFFFFFFFFFFFFFL
        }
        return s.toLongOrNull(8) ?: 0L
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
