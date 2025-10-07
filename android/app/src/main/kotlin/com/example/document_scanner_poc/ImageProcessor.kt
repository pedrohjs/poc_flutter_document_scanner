package com.example.document_scanner_poc

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.media.Image
import android.util.Log
import androidx.core.graphics.createBitmap
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.*
import org.opencv.imgproc.Imgproc
import java.io.ByteArrayOutputStream
import kotlin.math.pow
import kotlin.math.sqrt

class ImageProcessor {

    companion object {
        init {
            if (!OpenCVLoader.initLocal()) {
                Log.e("OpenCV", "OpenCV initialization failed.")
            } else {
                Log.d("OpenCV", "OpenCV initialization successful.")
            }
        }
    }

    /**
     * Converte uma imagem YUV (do ImageReader) para uma Mat em tons de cinza (CV_8UC1).
     */
    fun convertImageToGrayMat(image: Image): Mat {
        if (image.format != ImageFormat.YUV_420_888) {
            throw IllegalArgumentException("Formato de imagem esperado: YUV_420_888")
        }

        // Extração dos buffers
        val planes = image.planes
        val yBuffer = planes[0].buffer
        val uBuffer = planes[1].buffer
        val vBuffer = planes[2].buffer

        val ySize = yBuffer.remaining()
        val uSize = uBuffer.remaining()
        val vSize = vBuffer.remaining()

        // Monta o array NV21 (YUV 4:2:0 semi-planar)
        val nv21 = ByteArray(ySize + uSize + vSize)
        yBuffer.get(nv21, 0, ySize)
        vBuffer.get(nv21, ySize, vSize)
        uBuffer.get(nv21, ySize + vSize, uSize)

        // Matriz com o formato YUV
        val yuvMat = Mat(image.height + image.height / 2, image.width, CvType.CV_8UC1)
        yuvMat.put(0, 0, nv21)

        // Converte NV21 para tons de cinza
        val grayMat = Mat()
        Imgproc.cvtColor(yuvMat, grayMat, Imgproc.COLOR_YUV2GRAY_NV21, 4)

        yuvMat.release()
        return grayMat
    }

    /**
     * Converte uma imagem YUV (do ImageReader) para uma Mat BGR colorida (CV_8UC3).
     */
    fun convertImageToColorMat(image: Image): Mat {
        if (image.format != ImageFormat.YUV_420_888) {
            throw IllegalArgumentException("Formato de imagem esperado: YUV_420_888")
        }

        // Extração dos buffers
        val planes = image.planes
        val yBuffer = planes[0].buffer
        val uBuffer = planes[1].buffer
        val vBuffer = planes[2].buffer

        val ySize = yBuffer.remaining()
        val uSize = uBuffer.remaining()
        val vSize = vBuffer.remaining()

        // Monta o array NV21 (YUV 4:2:0 semi-planar)
        val nv21 = ByteArray(ySize + uSize + vSize)
        yBuffer.get(nv21, 0, ySize)
        vBuffer.get(nv21, ySize, vSize)
        uBuffer.get(nv21, ySize + vSize, uSize)

        val yuvMat = Mat(image.height + image.height / 2, image.width, CvType.CV_8UC1)
        yuvMat.put(0, 0, nv21)

        // Converte NV21 para BGR (colorido)
        val bgrMat = Mat()
        Imgproc.cvtColor(yuvMat, bgrMat, Imgproc.COLOR_YUV2BGR_NV21)
        yuvMat.release()
        return bgrMat
    }

    /**
     * Encontra e aproxima o maior contorno de 4 lados (documento) na imagem.
     */
    fun findDocumentContour(imageMat: Mat): MatOfPoint2f? {
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

            if (largestContour != null && maxArea > 1000) { // Verifica uma área mínima razoável
                val contour2f = MatOfPoint2f()
                largestContour.convertTo(contour2f, CvType.CV_32F)
                val arcLength = Imgproc.arcLength(contour2f, true)

                // Aproxima o contorno com base em um percentual do perímetro
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

    /**
     * Reorganiza os pontos do contorno para a ordem padrão: [TL, TR, BR, BL].
     */
    fun sortPoints(points: List<Point>): List<Point> {
        val sorted = Array<Point>(4) { Point(0.0, 0.0) }

        // TL (menor soma x+y) e BR (maior soma x+y)
        val sumSorted = points.sortedBy { it.x + it.y }
        sorted[0] = sumSorted[0] // Top-Left
        sorted[2] = sumSorted[3] // Bottom-Right

        // TR (maior diferença x-y) e BL (menor diferença x-y)
        val diffSorted = points.sortedBy { it.x - it.y }
        sorted[1] = diffSorted[3] // Top-Right
        sorted[3] = diffSorted[0] // Bottom-Left

        return sorted.toList()
    }

    /**
     * Aplica a transformação de perspectiva (warp) para "achatar" o documento.
     */
    fun warpPerspective(
        originalMat: Mat,
        corners: MatOfPoint2f
    ): Mat {
        val points = corners.toArray().toList()
        val sortedPoints = sortPoints(points) // [TL, TR, BR, BL]

        val tl = sortedPoints[0]
        val tr = sortedPoints[1]
        val br = sortedPoints[2]
        val bl = sortedPoints[3]

        // Calcula a largura e altura máximas do documento detectado
        val widthA = sqrt((br.x - bl.x).pow(2.0) + (br.y - bl.y).pow(2.0))
        val widthB = sqrt((tr.x - tl.x).pow(2.0) + (tr.y - tl.y).pow(2.0))
        val maxWidth = widthA.coerceAtLeast(widthB).toInt()

        val heightA = sqrt((tr.x - br.x).pow(2.0) + (tr.y - br.y).pow(2.0))
        val heightB = sqrt((tl.x - bl.x).pow(2.0) + (tl.y - bl.y).pow(2.0))
        val maxHeight = heightA.coerceAtLeast(heightB).toInt()

        // Define os pontos de destino no novo plano (retângulo)
        val dstPoints = MatOfPoint2f(
            Point(0.0, 0.0), // TL
            Point(maxWidth - 1.0, 0.0), // TR
            Point(maxWidth - 1.0, maxHeight - 1.0), // BR
            Point(0.0, maxHeight - 1.0) // BL
        )

        val dstMat = Mat.zeros(maxHeight, maxWidth, CvType.CV_8UC3)
        val transformMat = Imgproc.getPerspectiveTransform(corners, dstPoints)

        Imgproc.warpPerspective(originalMat, dstMat, transformMat, Size(maxWidth.toDouble(), maxHeight.toDouble()))

        transformMat.release()
        dstPoints.release()

        return dstMat
    }

    /**
     * Converte uma Mat BGR (CV_8UC3) para um ByteArray PNG para envio ao Flutter.
     */
    fun convertMatToPngByteArray(mat: Mat): ByteArray {
        val bmp = createBitmap(mat.cols(), mat.rows(), Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(mat, bmp)
        val stream = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, stream)
        val imageBytes = stream.toByteArray()
        bmp.recycle()
        return imageBytes
    }
}