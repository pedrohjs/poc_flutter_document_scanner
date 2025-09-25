package com.example.document_scanner_poc

import android.os.Build
import android.util.Size
import android.os.Handler
import android.media.Image
import android.view.Surface
import android.content.Context
import android.os.HandlerThread
import android.media.ImageReader
import android.hardware.camera2.*
import android.graphics.ImageFormat
import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodChannel
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import java.util.*
import org.opencv.core.*
import org.opencv.core.Mat
import org.opencv.core.CvType
import org.opencv.imgproc.Imgproc
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executor
import kotlin.math.pow
import kotlin.math.sqrt
import androidx.core.graphics.createBitmap

class DocumentScanner(
    private val context: Context,
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
    private val mainHandler = Handler(context.mainLooper)
    private var lastImageCaptureTime: Long = 0
    private var isManualCapture = false

    companion object {
        init {
            if (!OpenCVLoader.initLocal()) {
                Log.e("OpenCV", "OpenCV initialization failed.")
            } else {
                Log.d("OpenCV", "OpenCV initialization successful.")
            }
        }
    }

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
                    createCaptureSession()
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

    private val backgroundExecutor: Executor = Executor { command ->
        backgroundHandler.post(command)
    }

    @RequiresApi(Build.VERSION_CODES.P)
    @SuppressLint("MissingPermission")
    private fun createCaptureSession() {
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
                if (image == null) return@setOnImageAvailableListener

                if (isManualCapture) {
                    isProcessingImage = true
                    isManualCapture = false

                    // Converte a imagem bruta para bytes (JPEG)
                    val planes = image.planes
                    val yBuffer = planes[0].buffer
                    val uBuffer = planes[1].buffer
                    val vBuffer = planes[2].buffer

                    val ySize = yBuffer.remaining()
                    val uSize = uBuffer.remaining()
                    val vSize = vBuffer.remaining()

                    val nv21 = ByteArray(ySize + uSize + vSize)
                    yBuffer.get(nv21, 0, ySize)
                    vBuffer.get(nv21, ySize, vSize)
                    uBuffer.get(nv21, ySize + vSize, uSize)

                    val yuvMat = Mat(image.height + image.height / 2, image.width, CvType.CV_8UC1)
                    yuvMat.put(0, 0, nv21)

                    val bgrMat = Mat()
                    Imgproc.cvtColor(yuvMat, bgrMat, Imgproc.COLOR_YUV2BGR_NV21)
                    yuvMat.release()

                    // Rotaciona a imagem para a orientação correta
                    val rotatedColorMat = Mat()
                    Core.rotate(bgrMat, rotatedColorMat, Core.ROTATE_90_CLOCKWISE)
                    bgrMat.release()

                    // Converte a Mat rotacionada para um array de bytes (JPEG)
                    val bmp = createBitmap(rotatedColorMat.cols(), rotatedColorMat.rows())
                    Utils.matToBitmap(rotatedColorMat, bmp)
                    val stream = ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                    val imageBytes = stream.toByteArray()

                    // Libera os recursos
                    rotatedColorMat.release()
                    bmp.recycle()
                    image.close()

                    // Envia a imagem para o Flutter
                    mainHandler.post {
                        channel.invokeMethod("onManualImageCaptured", imageBytes)
                        isProcessingImage = false

                        // Reinicia a pré-visualização após a captura manual
                        try {
                            captureSession!!.setRepeatingRequest(captureRequestBuilder!!.build(), null, backgroundHandler)
                        } catch (e: Exception) {
                            errorWhenProcessingDocument(e, "reiniciar_preview")
                        }
                    }
                } else {
                    if (!isProcessingImage) {
                        val currentTime = System.currentTimeMillis()

                        // Check for the 250ms interval for vertex detection
                        if (currentTime - lastProcessTime > 250) {
                            lastProcessTime = currentTime
                            isProcessingImage = true

                            // ETAPA 1: Processamento em tons de cinza (para a detecção)
                            val imageWidth = image.width
                            val imageHeight = image.height

                            // Converte a imagem YUV para uma Mat em tons de cinza
                            val originalGrayMat = convertImageToMat(image)

                            // Rotaciona a Mat para a orientação do retrato
                            val rotatedGrayMat = Mat()
                            Core.rotate(originalGrayMat, rotatedGrayMat, Core.ROTATE_90_CLOCKWISE)
                            originalGrayMat.release()

                            // Encontra os vértices do documento na Mat rotacionada em tons de cinza
                            val documentCorners = findDocumentContour(rotatedGrayMat)

                            // ETAPA 2: Prepara os dados (vértices e imagem final)
                            val verticesMap: Map<String, Any>
                            var imageBytes: ByteArray? = null

                            if (documentCorners != null) {
                                val points = documentCorners.toArray().toList()
                                val sortedPoints = sortPoints(points)
                                val rotatedImageWidth = rotatedGrayMat.cols()
                                val rotatedImageHeight = rotatedGrayMat.rows()

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

                                // ETAPA 3: Check for the 1000ms interval for image processing
                                if (currentTime - lastImageCaptureTime > 1000) {
                                    lastImageCaptureTime = currentTime

                                    // Processamento da imagem COLORIDA para o warping
                                    val planes = image.planes
                                    val yBuffer = planes[0].buffer
                                    val uBuffer = planes[1].buffer
                                    val vBuffer = planes[2].buffer

                                    val ySize = yBuffer.remaining()
                                    val uSize = uBuffer.remaining()
                                    val vSize = vBuffer.remaining()

                                    val nv21 = ByteArray(ySize + uSize + vSize)
                                    yBuffer.get(nv21, 0, ySize)
                                    vBuffer.get(nv21, ySize, vSize)
                                    uBuffer.get(nv21, ySize + vSize, uSize)

                                    val yuvMat = Mat(image.height + image.height / 2, image.width, CvType.CV_8UC1)
                                    yuvMat.put(0, 0, nv21)

                                    val bgrMat = Mat()
                                    Imgproc.cvtColor(yuvMat, bgrMat, Imgproc.COLOR_YUV2BGR_NV21)
                                    yuvMat.release()

                                    val rotatedColorMat = Mat()
                                    Core.rotate(bgrMat, rotatedColorMat, Core.ROTATE_90_CLOCKWISE)
                                    bgrMat.release()

                                    // Faça o `warp` na Mat colorida rotacionada
                                    val warpedMat = warpPerspective(rotatedColorMat, documentCorners)

                                    // Converte a Mat final para um array de bytes (JPEG)
                                    val bmp = createBitmap(warpedMat.cols(), warpedMat.rows())
                                    Utils.matToBitmap(warpedMat, bmp)
                                    val stream = ByteArrayOutputStream()
                                    bmp.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                                    imageBytes = stream.toByteArray()

                                    // Libere os recursos temporários
                                    rotatedColorMat.release()
                                    warpedMat.release()
                                    bmp.recycle()
                                }

                            } else {
                                verticesMap = mapOf("vertices" to emptyList<Map<String, Int>>())
                            }

                            // Libera as Matrizes de tons de cinza e de contorno
                            rotatedGrayMat.release()
                            documentCorners?.release()
                            image.close()

                            // ETAPA 4: Enviar os dados para o Flutter
                            mainHandler.post {
                                channel.invokeMethod("onDocumentRecognized", verticesMap)
                                imageBytes?.let {
                                    channel.invokeMethod("onDocumentImageCaptured", it)
                                }
                                isProcessingImage = false
                            }
                        } else {
                            image.close()
                        }
                    } else {
                        image.close()
                    }
                }
            }, backgroundHandler)
        }

        if (!previewSurface.isValid) return

        val outputs = listOf(
            OutputConfiguration(previewSurface),
            OutputConfiguration(imageReader!!.surface)
        )

        val stateCallback = object : CameraCaptureSession.StateCallback() {
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
        }

        val sessionConfig = SessionConfiguration(
            SessionConfiguration.SESSION_REGULAR,
            outputs,
            backgroundExecutor,
            stateCallback
        )

        try {
            cameraDevice?.createCaptureSession(sessionConfig)
        } catch (e: CameraAccessException) {
            errorWhenProcessingDocument(e, "createCaptureSession 6")
        }
    }

    private fun convertImageToMat(image: Image): Mat {
        val planes = image.planes
        val yBuffer = planes[0].buffer
        val uBuffer = planes[1].buffer
        val vBuffer = planes[2].buffer

        val ySize = yBuffer.remaining()
        val uSize = uBuffer.remaining()
        val vSize = vBuffer.remaining()

        val nv21 = ByteArray(ySize + uSize + vSize)
        yBuffer.get(nv21, 0, ySize)
        vBuffer.get(nv21, ySize, vSize)
        uBuffer.get(nv21, ySize + vSize, uSize)

        val yuvMat = Mat(image.height + image.height / 2, image.width, CvType.CV_8UC1)
        yuvMat.put(0, 0, nv21)

        val grayMat = Mat()
        Imgproc.cvtColor(yuvMat, grayMat, Imgproc.COLOR_YUV2GRAY_NV21, 4)

        yuvMat.release()
        return grayMat
    }

    private fun findDocumentContour(imageMat: Mat): MatOfPoint2f? {
        val blurredMat = Mat()
        val cannyEdges = Mat()
        val hierarchy = Mat()
        val contours: MutableList<MatOfPoint> = ArrayList()
        var largestContour: MatOfPoint? = null
        var largestApprox: MatOfPoint2f? = null

        try {
            Imgproc.GaussianBlur(imageMat, blurredMat, Size(5.0, 5.0), 0.0)
            Imgproc.Canny(blurredMat, cannyEdges, 75.0, 200.0)
            Imgproc.findContours(cannyEdges, contours, hierarchy, Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)

            var maxArea = -1.0
            for (contour in contours) {
                val area = Imgproc.contourArea(contour)
                if (area > maxArea) {
                    maxArea = area
                    largestContour = contour
                }
            }

            if (largestContour != null && maxArea > 1000) {
                val contour2f = MatOfPoint2f()
                largestContour.convertTo(contour2f, CvType.CV_32F)
                val arcLength = Imgproc.arcLength(contour2f, true)

                val approx = MatOfPoint2f()
                Imgproc.approxPolyDP(contour2f, approx, 0.02 * arcLength, true)
                contour2f.release()

                if (approx.toArray().size == 4) {
                    largestApprox = approx
                } else {
                    approx.release()
                }
            }
        } finally {
            blurredMat.release()
            cannyEdges.release()
            hierarchy.release()
        }

        return largestApprox
    }

    private fun sortPoints(points: List<Point>): List<Point> {
        val sortedPoints = points.sortedBy { it.y }

        val topPoints = sortedPoints.take(2).sortedBy { it.x }
        val bottomPoints = sortedPoints.drop(2).sortedBy { it.x }

        val topLeft = topPoints[0]
        val topRight = topPoints[1]
        val bottomLeft = bottomPoints[0]
        val bottomRight = bottomPoints[1]

        return listOf(topLeft, topRight, bottomRight, bottomLeft)
    }

    private fun warpPerspective(
        originalMat: Mat,
        corners: MatOfPoint2f
    ): Mat {
        val points = corners.toArray().toList()
        val sortedPoints = sortPoints(points)

        val tl = sortedPoints[0]
        val tr = sortedPoints[1]
        val br = sortedPoints[2]
        val bl = sortedPoints[3]

        val widthA = sqrt((br.x - bl.x).pow(2.0) + (br.y - bl.y).pow(2.0))
        val widthB = sqrt((tr.x - tl.x).pow(2.0) + (tr.y - tl.y).pow(2.0))
        val maxWidth = widthA.coerceAtLeast(widthB).toInt()

        val heightA = sqrt((tr.x - br.x).pow(2.0) + (tr.y - br.y).pow(2.0))
        val heightB = sqrt((tl.x - bl.x).pow(2.0) + (tl.y - bl.y).pow(2.0))
        val maxHeight = heightA.coerceAtLeast(heightB).toInt()

        val dstMat = Mat.zeros(maxHeight, maxWidth, CvType.CV_8UC3)

        val dstPoints = MatOfPoint2f(
            Point(0.0, 0.0),
            Point(maxWidth - 1.0, 0.0),
            Point(maxWidth - 1.0, maxHeight - 1.0),
            Point(0.0, maxHeight - 1.0)
        )

        val transformMat = Imgproc.getPerspectiveTransform(corners, dstPoints)

        Imgproc.warpPerspective(originalMat, dstMat, transformMat, Size(maxWidth.toDouble(), maxHeight.toDouble()))

        transformMat.release()
        dstPoints.release()

        return dstMat
    }

    fun takePicture() {
        if (captureSession == null || cameraDevice == null) {
            errorWhenProcessingDocument(Exception("Sessão ou câmera nula para captura."), "takePicture")
            return
        }

        try {
            // Crie um CaptureRequest para capturar uma única imagem de alta qualidade
            val captureRequest = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(imageReader!!.surface)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.JPEG_ORIENTATION, 90)
            }

            // Pare a pré-visualização para capturar apenas uma imagem
            captureSession!!.stopRepeating()

            // Capture a imagem única
            isManualCapture = true
            captureSession!!.capture(captureRequest.build(), object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult
                ) {
                    super.onCaptureCompleted(session, request, result)
                    // A imagem será processada no onImageAvailableListener
                }
            }, backgroundHandler)

        } catch (e: CameraAccessException) {
            errorWhenProcessingDocument(e, "takePicture")
        }
    }

    private fun errorWhenProcessingDocument(e: Exception, methodError: String) { /* ... */ }
}