package com.example.document_scanner_poc

import android.util.Size
import android.os.Handler
import android.view.Surface
import android.content.Context
import android.os.HandlerThread
import android.media.ImageReader
import android.hardware.camera2.*
import android.graphics.ImageFormat
import android.annotation.SuppressLint
import android.graphics.SurfaceTexture
import io.flutter.plugin.common.MethodChannel

class DocumentScannerTexture(
    context: Context,
    private val channel: MethodChannel,
    private val surfaceTexture: SurfaceTexture,
) {

    private var isCameraStopped = false
    private var isProcessingImage = false
    private var imageReader: ImageReader? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var captureRequestBuilder: CaptureRequest.Builder? = null

    private val backgroundThread = HandlerThread("DocumentScannerThread").apply { start() }
    private val backgroundHandler = Handler(backgroundThread.looper)
    private var lastProcessTime: Long = 0
    private val cameraManager: CameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    @SuppressLint("MissingPermission")
    fun startCamera(isFlashLightOn: Boolean) {
        isCameraStopped = false
        val cameraId = cameraManager.cameraIdList.firstOrNull { id ->
            val characteristics = cameraManager.getCameraCharacteristics(id)
            characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: run {
            errorWhenProcessingDocument(Exception("Câmera traseira não encontrada."), "startCamera 1")
            return
        }

        try {
            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (isCameraStopped) {
                        camera.close()
                        return
                    }
                    cameraDevice = camera
                    createCaptureSession(isFlashLightOn)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    try {
                        camera.close()
                    } catch (e: Exception) {
                    }
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    try {
                        camera.close()
                    } catch (e: Exception) {
                    }
                    errorWhenProcessingDocument(Exception("Erro na câmera: $error"), "startCamera 3")
                }
            }, backgroundHandler)
        } catch (e: CameraAccessException) {
            errorWhenProcessingDocument(e, "startCamera 4")
        }
    }

    @SuppressLint("MissingPermission")
    private fun createCaptureSession(isFlashLightOn: Boolean) {
        val previewSize = Size(1280, 720)
        surfaceTexture.setDefaultBufferSize(previewSize.width, previewSize.height)
        val previewSurface = Surface(surfaceTexture)

        imageReader = ImageReader.newInstance(
            previewSize.width,
            previewSize.height,
            ImageFormat.YUV_420_888,
            2
        ).apply {
            setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage()
                if (image != null && !isProcessingImage) {
                    val currentTime = System.currentTimeMillis()
                    if (currentTime - lastProcessTime > 1000) {
                        lastProcessTime = currentTime
                        isProcessingImage = true
//                        processImage(image)
                    }
                    image.close()
                } else image?.close()
            }, backgroundHandler)
        }

        if (!previewSurface.isValid()) return

        val surfaces = listOf(previewSurface, imageReader!!.surface)
        try {
            cameraDevice?.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    if (isCameraStopped || cameraDevice == null) {
                        errorWhenProcessingDocument(Exception("CameraDevice nulo."), "createCaptureSession 1")
                        return
                    }

                    captureSession = session
                    try {
                        captureRequestBuilder = cameraDevice!!.createCaptureRequest(
                            CameraDevice.TEMPLATE_PREVIEW
                        ).apply {
                            addTarget(previewSurface)
                            addTarget(imageReader!!.surface)
                        }
                    } catch (e: IllegalStateException) {
                        errorWhenProcessingDocument(e, "createCaptureSession 2")
                        return
                    }

                    try {
                        session.setRepeatingRequest(captureRequestBuilder!!.build(), null, backgroundHandler)
                        if (!isCameraStopped){
//                            toggleFlash(isFlashLightOn)
                        }
                    } catch (e: CameraAccessException) {
                        errorWhenProcessingDocument(e, "createCaptureSession 3")
                    } catch (e: IllegalStateException) {
                        if (e.message?.contains("Session has been closed") == false) {
                            errorWhenProcessingDocument(e, "createCaptureSession 4")
                        }
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    errorWhenProcessingDocument(Exception("Falha na configuração da sessão da câmera."), "createCaptureSession 5")
                }
            }, backgroundHandler)
        } catch (e: CameraAccessException) {
            errorWhenProcessingDocument(e, "createCaptureSession 6")
        }
    }

    private fun errorWhenProcessingDocument(e: Exception, methodError: String) { /* ... */ }
}