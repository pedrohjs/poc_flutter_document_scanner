package com.example.document_scanner_poc

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.Image
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import org.opencv.core.Core
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint2f

class DocumentScanner(
    context: Context,
    private val surfaceTexture: SurfaceTexture,
    eventChannel: EventChannel
) : EventChannel.StreamHandler, ImageCallback {

    private var isCameraStopped = false
    private var isProcessingImage = false
    private var cameraDevice: CameraDevice? = null
    private val backgroundThread = HandlerThread("DocumentScannerThread").apply { start() }
    private val backgroundHandler = Handler(backgroundThread.looper)
    private val cameraManager: CameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val mainHandler = Handler(context.mainLooper)
    private var isFlashOn = false
    private var eventSink: EventSink? = null
    private var cameraSessionManager: CameraSessionManager? = null
    private val imageProcessor = ImageProcessor()

    // Lógica de Confirmação de Contorno
    private var lastProcessTime: Long = 0
    private var confirmationStartTime: Long = 0
    private var confirmedCorners: MatOfPoint2f? = null
    private val confirmationDelayMS = 2000L

    init {
        eventChannel.setStreamHandler(this)
    }

    // --- Métodos de Ciclo de Vida e Setup ---
    @SuppressLint("MissingPermission")
    fun startCamera() {
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
                    // Cria e inicia o gerenciador de sessão
                    cameraSessionManager = CameraSessionManager(
                        camera,
                        surfaceTexture,
                        backgroundHandler,
                        this@DocumentScanner
                    )
                    cameraSessionManager!!.createCaptureSession()
                }

                override fun onDisconnected(camera: CameraDevice) {
                    try {
                        camera.close()
                    } catch (e: Exception) {}
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    try {
                        camera.close()
                    } catch (e: Exception) {}
                    errorWhenProcessingDocument(Exception("Erro na câmera: $error"), "startCamera 3")
                }
            }, backgroundHandler)
        } catch (e: CameraAccessException) {
            errorWhenProcessingDocument(e, "startCamera 4")
        }
    }

    fun stopCamera() {
        isCameraStopped = true
        cameraSessionManager?.close()
        cameraDevice = null
        backgroundThread.quitSafely()
        confirmedCorners?.release()
        confirmedCorners = null
    }

    // --- ImageCallback (Recebe frames do CameraSessionManager) ---
    override fun onNewImage(image: Image, isManualCapture: Boolean) {
        if (isManualCapture) {
            handleManualCapture(image)
        } else {
            handlePreviewFrame(image)
        }
    }

    override fun onError(e: Exception, context: String) {
        errorWhenProcessingDocument(e, context)
    }

    // --- Lógica de Processamento de Frames ---
    private fun handleManualCapture(image: Image) {
        isProcessingImage = true
        cameraSessionManager?.isManualCapture = false // Reseta o estado

        // ETAPA 1: Converte e Rotaciona
        val bgrMat = imageProcessor.convertImageToColorMat(image)
        image.close()

        val rotatedColorMat = Mat()
        Core.rotate(bgrMat, rotatedColorMat, Core.ROTATE_90_CLOCKWISE)
        bgrMat.release()

        // ETAPA 2: Converte Mat para PNG e envia para o Flutter
        val imageBytes = imageProcessor.convertMatToPngByteArray(rotatedColorMat)
        rotatedColorMat.release()

        mainHandler.post {
            val manualCaptureEvent = mapOf(
                "eventType" to "manual_capture",
                "data" to imageBytes
            )
            eventSink?.success(manualCaptureEvent)

            isProcessingImage = false

            cameraSessionManager?.restartPreview()
        }
    }

    private fun handlePreviewFrame(image: Image) {
        if (isProcessingImage) {
            image.close()
            return
        }

        val currentTime = System.currentTimeMillis()

        // Intervalo para detecção de contorno
        if (currentTime - lastProcessTime < 250) {
            image.close()
            return
        }

        lastProcessTime = currentTime
        isProcessingImage = true

        backgroundHandler.post {

            var originalGrayMat = Mat()
            var rotatedGrayMat = Mat()
            var documentCorners: MatOfPoint2f? = null

            var verticesMap: Map<String, Any> = emptyMap()
            var imageBytes: ByteArray? = null

            try {
                // ETAPA 1: Processamento em tons de cinza para detecção
                val imageWidth = image.width
                val imageHeight = image.height

                originalGrayMat = imageProcessor.convertImageToGrayMat(image)
                Core.rotate(originalGrayMat, rotatedGrayMat, Core.ROTATE_90_CLOCKWISE)
                originalGrayMat.release()

                documentCorners = imageProcessor.findDocumentContour(rotatedGrayMat)

                // --- ETAPA 2: LÓGICA DE CONFIRMAÇÃO DO CONTORNO ---
                var shouldProcessWarp = false

                if (documentCorners != null) {
                    val points = documentCorners.toArray().toList()
                    val sortedPoints = imageProcessor.sortPoints(points)
                    val rotatedImageWidth = rotatedGrayMat.cols()
                    val rotatedImageHeight = rotatedGrayMat.rows()

                    if (confirmedCorners == null) {
                        confirmationStartTime = currentTime
                        confirmedCorners = MatOfPoint2f(documentCorners.clone())
                    }

                    val timeElapsed = currentTime - confirmationStartTime
                    val isConfirmed = (timeElapsed >= confirmationDelayMS)

                    fun mapToPreviewCoordinates(point: org.opencv.core.Point): Map<String, Int> {
                        val xInPreview = (point.x / rotatedImageWidth) * imageWidth
                        val yInPreview = (point.y / rotatedImageHeight) * imageHeight
                        return mapOf("x" to xInPreview.toInt(), "y" to yInPreview.toInt())
                    }

                    val topLeft = mapToPreviewCoordinates(sortedPoints[0])
                    val topRight = mapToPreviewCoordinates(sortedPoints[1])
                    val bottomRight = mapToPreviewCoordinates(sortedPoints[2])
                    val bottomLeft = mapToPreviewCoordinates(sortedPoints[3])

                    verticesMap = mapOf(
                        "topLeft" to topLeft,
                        "topRight" to topRight,
                        "bottomRight" to bottomRight,
                        "bottomLeft" to bottomLeft,
                        "imageNativeWidth" to imageWidth,
                        "imageNativeHeight" to imageHeight
                    )

                    if (isConfirmed) {
                        shouldProcessWarp = true
                    }
                } else {
                    confirmationStartTime = 0
                    confirmedCorners?.release()
                    confirmedCorners = null
                }

                if (shouldProcessWarp && documentCorners != null) {
                    // Processamento da imagem COLORIDA para o warping
                    val colorMat = imageProcessor.convertImageToColorMat(image)

                    val rotatedColorMatForWarp = Mat()
                    Core.rotate(colorMat, rotatedColorMatForWarp, Core.ROTATE_90_CLOCKWISE)
                    colorMat.release()

                    // Faz o `warp`
                    val warpedMat = imageProcessor.warpPerspective(rotatedColorMatForWarp, documentCorners)

                    // Faz o flip horizontal
                    val finalMat = Mat()
                    Core.flip(warpedMat, finalMat, 1)

                    // Converte para ByteArray PNG
                    imageBytes = imageProcessor.convertMatToPngByteArray(finalMat)

                    // Libera os recursos temporários do WARP
                    rotatedColorMatForWarp.release()
                    warpedMat.release()
                    finalMat.release()
                }

                // ETAPA 4: Enviar os dados para o Flutter no Main Thread
                mainHandler.post {
                    val verticesEvent = mapOf(
                        "eventType" to "vertices_update",
                        "data" to verticesMap
                    )
                    eventSink?.success(verticesEvent)

                    imageBytes?.let {
                        val imageEvent = mapOf(
                            "eventType" to "document_captured",
                            "data" to it
                        )
                        eventSink?.success(imageEvent)

                        // *** REINICIA A LÓGICA DE CONFIRMAÇÃO APÓS A CAPTURA COMPLETA ***
                        confirmationStartTime = 0
                        confirmedCorners?.release()
                        confirmedCorners = null
                    }
                    isProcessingImage = false
                }
            } catch (e: Exception) {
                errorWhenProcessingDocument(e, "handlePreviewFrame")

                mainHandler.post {
                    isProcessingImage = false
                }
            } finally {
                image.close()
                rotatedGrayMat.release()
                documentCorners?.release()
            }
        }
    }

    // --- Métodos de Controle ---
    fun takePicture() {
        // Delega a captura ao CameraSessionManager
        cameraSessionManager?.takePicture {
            // Callback chamado após a captura ser enviada ao ImageReader
            Log.d("DocumentScanner", "Captura manual solicitada e enviada ao ImageReader.")
        } ?: errorWhenProcessingDocument(Exception("Sessão nula para captura."), "takePicture")
    }

    fun toggleFlash() {
        isFlashOn = !isFlashOn
        cameraSessionManager?.toggleFlash(isFlashOn) ?: errorWhenProcessingDocument(Exception("Sessão nula para flash."), "toggleFlash")
    }

    // --- EventChannel ---
    override fun onListen(arguments: Any?, events: EventSink?) {
        this.eventSink = events
        Log.d("DocumentScanner", "Flutter assinou o Event Channel. EventSink configurado.")
    }

    override fun onCancel(arguments: Any?) {
        this.eventSink = null
        Log.d("DocumentScanner", "Flutter cancelou o Event Channel. EventSink zerado.")
    }

    // --- Helper ---
    private fun errorWhenProcessingDocument(e: Exception, methodError: String) {
        Log.e("DocumentScanner", "Erro em $methodError: ${e.message}", e)
    }
}