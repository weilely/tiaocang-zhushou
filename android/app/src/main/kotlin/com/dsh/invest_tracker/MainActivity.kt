package com.dsh.invest_tracker

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新用的桥：把下载好的 APK 交给系统安装器。
 *
 * 用 MethodChannel 而不是引第三方插件包 —— 只有两个动作，自己写更可控，
 * 也免得为一个功能多带一个依赖。
 *
 * 说明：**静默安装做不到**（非系统应用），系统一定会弹一次「安装」确认，
 * 这是 Android 的设计，不是实现偷懒。另外 Android 8+ 需要用户先给本应用
 * 开「安装未知应用」，[canRequestInstall] 用来提前判断并给出引导。
 */
class MainActivity : FlutterFragmentActivity() {

    private val channelName = "com.dsh.invest_tracker/install"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canRequestInstall())

                    // 设备主 ABI：用来在发行版附件里挑对应架构的 APK
                    // （拆分后的包按 ABI 命名，选错会装不上）
                    "abi" -> result.success(
                        Build.SUPPORTED_ABIS.firstOrNull() ?: ""
                    )

                    "openInstallSettings" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                val i = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                                i.data = Uri.parse("package:$packageName")
                                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(i)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_FAILED", e.message, null)
                        }
                    }

                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "缺少 path", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(path)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** Android 8+ 要检查「安装未知应用」是否已对本应用放开 */
    private fun canRequestInstall(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("安装包不存在：$path")
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
