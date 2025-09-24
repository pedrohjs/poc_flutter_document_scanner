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
import android.graphics.BitmapFactory
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
import java.util.concurrent.Executor

class DocumentScanner(
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
    private val mainHandler = Handler(context.mainLooper)

    companion object {
        init {
            if (!OpenCVLoader.initLocal()) {
                // Handle error, maybe log a message or throw an exception
                Log.e("OpenCV", "OpenCV initialization failed.")
            } else {
                Log.d("OpenCV", "OpenCV initialization successful.")
            }
        }
    }

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

    private val backgroundExecutor: Executor = Executor { command ->
        backgroundHandler.post(command)
    }

    @RequiresApi(Build.VERSION_CODES.P)
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
                    if (currentTime - lastProcessTime > 250) {
                        lastProcessTime = currentTime
                        isProcessingImage = true

                        // ✅ Etapa 1: COLETE TODAS AS INFORMAÇÕES NECESSÁRIAS AQUI.
                        //    Você já fez isso para imageWidth e imageHeight, mas precisa
                        //    também para as dimensões de preview que você usa dentro do post().
                        val imageWidth = image.width
                        val imageHeight = image.height

                        val originalMat = convertImageToMat(image)
                        val rotatedMat = Mat()
                        Core.rotate(originalMat, rotatedMat, Core.ROTATE_90_CLOCKWISE)
                        val documentCorners = findDocumentContour(rotatedMat)

                        // ✅ Etapa 2: FECHE A IMAGEM IMEDIATAMENTE APÓS COLETAR OS DADOS.
                        image.close()

                        // ✅ Etapa 3: Libere os objetos Mat.
                        originalMat.release()

                        // É crucial não liberar rotatedMat aqui se você precisar de suas dimensões
                        // no mainHandler.post. Passe-as como variáveis também.
                        val rotatedImageWidth = rotatedMat.cols()
                        val rotatedImageHeight = rotatedMat.rows()
                        rotatedMat.release()

                        // ✅ Etapa 4: Envie a tarefa para a thread principal,
                        //    passando APENAS as variáveis que você já coletou.
                        mainHandler.post {
                            if (documentCorners != null) {
                                val points = documentCorners.toArray().toList()
                                val sortedPoints = sortPoints(points)

                                // A função de mapeamento agora usa as variáveis coletadas
                                // e não precisa mais acessar o objeto 'image' ou 'rotatedMat'.
                                fun mapToPreviewCoordinates(point: org.opencv.core.Point): Map<String, Int> {
                                    val xInPreview = (point.x / rotatedImageWidth) * imageWidth // Use a variável 'imageWidth'
                                    val yInPreview = (point.y / rotatedImageHeight) * imageHeight // Use a variável 'imageHeight'
                                    return mapOf("x" to xInPreview.toInt(), "y" to yInPreview.toInt())
                                }

                                val topLeft = mapToPreviewCoordinates(sortedPoints[0])
                                val topRight = mapToPreviewCoordinates(sortedPoints[1])
                                val bottomRight = mapToPreviewCoordinates(sortedPoints[2])
                                val bottomLeft = mapToPreviewCoordinates(sortedPoints[3])

                                val vertices = mapOf(
                                    "topLeft" to topLeft,
                                    "topRight" to topRight,
                                    "bottomRight" to bottomRight,
                                    "bottomLeft" to bottomLeft,
                                    "imageNativeWidth" to imageWidth,
                                    "imageNativeHeight" to imageHeight
                                )

                                channel.invokeMethod("onDocumentRecognized", vertices)
                            } else {
                                val vertices = mapOf("vertices" to emptyList<Map<String, Int>>())
                                channel.invokeMethod("onDocumentRecognized", vertices)
                            }

                            documentCorners?.release()
                            isProcessingImage = false
                        }
                    } else {
                        image.close()
                    }
                } else {
                    image?.close()
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
                // ... sua lógica de onConfigured
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
//                toggleFlash(isFlashLightOn)
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
        }

        val sessionConfig = SessionConfiguration(
            SessionConfiguration.SESSION_REGULAR,
            outputs,
            backgroundExecutor, // Use your custom executor
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
        // The COLOR_YUV2GRAY_NV21 conversion is correct for the YUV_420_888 format from Camera2
        Imgproc.cvtColor(yuvMat, grayMat, Imgproc.COLOR_YUV2GRAY_NV21, 4)

        // IMPORTANT: Release the temporary yuvMat to prevent a memory leak
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

            // Find the largest contour
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
                    // If a 4-sided polygon is found, we return it.
                    largestApprox = approx
                } else {
                    // If not, we release the object immediately.
                    approx.release()
                }
            }
        } finally {
            // Release all temporary Mat objects
            blurredMat.release()
            cannyEdges.release()
            hierarchy.release()
            // largestContour is handled by the loop and will be garbage collected
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

    private fun errorWhenProcessingDocument(e: Exception, methodError: String) { /* ... */ }
}