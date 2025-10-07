package com.example.document_scanner_poc

import android.annotation.SuppressLint
import android.os.Build
import android.os.Handler
import android.media.Image
import android.media.ImageReader
import android.view.Surface
import android.hardware.camera2.*
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.util.Size
import java.util.concurrent.Executor

interface ImageCallback {
    fun onNewImage(image: Image, isManualCapture: Boolean)
    fun onError(e: Exception, context: String)
}

class CameraSessionManager(
    private val cameraDevice: CameraDevice,
    private val surfaceTexture: SurfaceTexture,
    private val backgroundHandler: Handler,
    private val imageCallback: ImageCallback
) {
    private var captureSession: CameraCaptureSession? = null
    private var captureRequestBuilder: CaptureRequest.Builder? = null
    private var imageReader: ImageReader? = null
    private val previewSize = Size(1280, 720)

    private val backgroundExecutor: Executor = Executor { command ->
        backgroundHandler.post(command)
    }

    /**
     * Cria e configura o CameraCaptureSession para pré-visualização e captura de imagens.
     */
    @SuppressLint("MissingPermission")
    fun createCaptureSession() {
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
                if (image != null) {
                    imageCallback.onNewImage(image, isManualCapture)
                }
            }, backgroundHandler)
        }

        if (!previewSurface.isValid) return

        val surfaces = listOf(previewSurface, imageReader!!.surface)

        val stateCallback = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                captureSession = session
                try {
                    captureRequestBuilder = cameraDevice.createCaptureRequest(
                        CameraDevice.TEMPLATE_PREVIEW
                    ).apply {
                        addTarget(previewSurface)
                        addTarget(imageReader!!.surface)
                        set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
                    }
                    session.setRepeatingRequest(captureRequestBuilder!!.build(), null, backgroundHandler)
                } catch (e: Exception) {
                    imageCallback.onError(e, "createCaptureSession_onConfigured")
                }
            }

            override fun onConfigureFailed(session: CameraCaptureSession) {
                imageCallback.onError(Exception("Falha na configuração da sessão da câmera."), "createCaptureSession_onConfigureFailed")
            }
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val outputConfigs = surfaces.map { OutputConfiguration(it) }
                val sessionConfig = SessionConfiguration(
                    SessionConfiguration.SESSION_REGULAR,
                    outputConfigs,
                    backgroundExecutor,
                    stateCallback
                )
                cameraDevice.createCaptureSession(sessionConfig)
            } else {
                @Suppress("DEPRECATION")
                cameraDevice.createCaptureSession(surfaces, stateCallback, backgroundHandler)
            }
        } catch (e: CameraAccessException) {
            imageCallback.onError(e, "createCaptureSession_start")
        }
    }

    var isManualCapture: Boolean = false

    /**
     * Interrompe o loop de pré-visualização e captura uma única imagem.
     */
    fun takePicture(onComplete: () -> Unit) {
        val currentSession = captureSession ?: return imageCallback.onError(Exception("Sessão nula para captura."), "takePicture")
        val currentImageReader = imageReader ?: return imageCallback.onError(Exception("ImageReader nulo para captura."), "takePicture")

        try {
            // Cria um CaptureRequest para a imagem estática
            val captureRequest = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(currentImageReader.surface)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.JPEG_ORIENTATION, 90)

                captureRequestBuilder?.get(CaptureRequest.FLASH_MODE)?.let {
                    set(CaptureRequest.FLASH_MODE, it)
                }
            }

            currentSession.stopRepeating()
            isManualCapture = true
            currentSession.capture(captureRequest.build(), object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult
                ) {
                    super.onCaptureCompleted(session, request, result)
                    onComplete()
                }
            }, backgroundHandler)

        } catch (e: Exception) {
            isManualCapture = false
            imageCallback.onError(e, "takePicture")
        }
    }

    /**
     * Reinicia o loop de pré-visualização após uma captura manual ou alteração de flash.
     */
    fun restartPreview() {
        val session = captureSession
        val builder = captureRequestBuilder
        if (session == null || builder == null) {
            return imageCallback.onError(Exception("Sessão ou builder nulos."), "restartPreview")
        }
        try {
            session.setRepeatingRequest(builder.build(), null, backgroundHandler)
        } catch (e: Exception) {
            imageCallback.onError(e, "restartPreview")
        }
    }

    /**
     * Alterna o estado do flash (Tocha).
     */
    fun toggleFlash(isFlashOn: Boolean) {
        val session = captureSession
        val builder = captureRequestBuilder
        if (session == null || builder == null) {
            return imageCallback.onError(Exception("Sessão ou builder nulos."), "toggleFlash")
        }
        try {
            val flashMode = if (isFlashOn) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF
            builder.set(CaptureRequest.FLASH_MODE, flashMode)
            session.setRepeatingRequest(builder.build(), null, backgroundHandler)
        } catch (e: Exception) {
            imageCallback.onError(e, "toggleFlash")
        }
    }

    /**
     * Limpa e fecha recursos.
     */
    fun close() {
        captureSession?.close()
        captureSession = null
        imageReader?.close()
        imageReader = null
    }
}