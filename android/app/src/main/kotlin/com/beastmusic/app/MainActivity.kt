package com.beastmusic.app

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOWNLOAD_KEEP_ALIVE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sync" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    if (active) {
                        DownloadKeepAliveService.startOrUpdate(
                            applicationContext,
                            title = call.argument<String>("title") ?: "Downloading songs",
                            subtitle = call.argument<String>("subtitle") ?: "Download queue active",
                            progress = call.argument<Int>("progress") ?: 0,
                            indeterminate = call.argument<Boolean>("indeterminate") ?: true
                        )
                    } else {
                        DownloadKeepAliveService.stop(applicationContext)
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    private companion object {
        const val DOWNLOAD_KEEP_ALIVE_CHANNEL = "beastcode/download_keep_alive"
    }
}
