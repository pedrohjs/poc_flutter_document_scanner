package com.example.document_scanner_poc

import android.graphics.SurfaceTexture
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private lateinit var channel: MethodChannel
    private lateinit var surfaceTexture: SurfaceTexture
    private var documentScanner: DocumentScanner? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "document_scanner")

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> {
                    val textureEntry = flutterEngine.renderer.createSurfaceTexture()
                    surfaceTexture = textureEntry.surfaceTexture()

                    val textureId = textureEntry.id()

                    documentScanner = DocumentScanner(
                        context = applicationContext,
                        channel = channel,
                        surfaceTexture = surfaceTexture
                    )

                    documentScanner?.startCamera()

                    result.success(textureId)
                }
                "manualCapture" -> {
                    documentScanner?.takePicture()
                }
                "toggleFlash" -> {}
//                "stopCamera" -> {
//                    documentScanner?.stopCamera()
//                    documentScanner = null
//                    result.success(null)
//                }
                else -> result.notImplemented()
            }
        }
    }
}
