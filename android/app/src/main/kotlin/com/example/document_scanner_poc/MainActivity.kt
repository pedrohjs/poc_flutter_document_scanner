package com.example.document_scanner_poc

import android.graphics.SurfaceTexture
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private lateinit var channel: MethodChannel
    private lateinit var surfaceTexture: SurfaceTexture
    private var documentScannerTexture: DocumentScannerTexture? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "document_scanner")

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> {
                    val isFlashLightOn = call.argument<Boolean>("isFlashLightOn") ?: false

                    val textureEntry = flutterEngine.renderer.createSurfaceTexture()
                    surfaceTexture = textureEntry.surfaceTexture()

                    val textureId = textureEntry.id()

                    documentScannerTexture = DocumentScannerTexture(
                        context = applicationContext,
                        channel = channel,
                        surfaceTexture = surfaceTexture
                    )

                    documentScannerTexture?.startCamera(isFlashLightOn)

                    result.success(textureId)
                }
//                "stopCamera" -> {
//                    documentScannerTexture?.stopCamera()
//                    documentScannerTexture = null
//                    result.success(null)
//                }
                else -> result.notImplemented()
            }
        }
    }
}
