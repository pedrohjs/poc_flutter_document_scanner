package com.example.document_scanner_poc

import android.graphics.SurfaceTexture
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity: FlutterActivity() {
    private lateinit var commandChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var surfaceTexture: SurfaceTexture
    private var documentScanner: DocumentScanner? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        commandChannel = MethodChannel(messenger, "document_scanner")
        eventChannel = EventChannel(messenger, "document_scanner_events")

        commandChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> {
                    val textureEntry = flutterEngine.renderer.createSurfaceTexture()
                    surfaceTexture = textureEntry.surfaceTexture()

                    val textureId = textureEntry.id()

                    documentScanner = DocumentScanner(
                        context = applicationContext,
                        channel = commandChannel,
                        surfaceTexture = surfaceTexture,
                        eventChannel = eventChannel
                    )

                    documentScanner?.startCamera()

                    result.success(textureId)
                }
                "manualCapture" -> {
                    documentScanner?.takePicture()
                    result.success(null)
                }
                "toggleFlash" -> {
                    documentScanner?.toggleFlash()
                    result.success(null)
                }
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
