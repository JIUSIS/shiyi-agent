package com.shiyi.agent

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

class MainActivity : FlutterActivity() {
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
                            result.success(extractZip(zipPath, destDir))
                        }
                        "createZip" -> {
                            val srcDir = call.argument<String>("srcDir")
                                ?: throw IllegalArgumentException("srcDir missing")
                            val zipPath = call.argument<String>("zipPath")
                                ?: throw IllegalArgumentException("zipPath missing")
                            createZip(srcDir, zipPath)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("SKILL_PACK_ERROR", e.message ?: e.toString(), null)
                }
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
}


