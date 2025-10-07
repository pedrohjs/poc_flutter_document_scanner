//
//  ImageProcessor.swift
//  Runner
//
//  Created by Pedro Santos on 07/10/25.
//

import UIKit
import CoreImage
import Vision
import AVFoundation

class ImageProcessor {
    
    private let ciContext = CIContext(options: nil)

    /// Converte um CVPixelBuffer para UIImage.
    func pixelBufferToUIImage(pixelBuffer: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Aplica correção de perspectiva e filtros a um documento detectado.
    @available(iOS 15.0, *)
    func createWarpedPixelBuffer(for observation: VNRectangleObservation, from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageSize = ciImage.extent.size
        
        // Converte as coordenadas normalizadas da Vision para coordenadas de imagem
        let topLeft = CGPoint(x: observation.topLeft.x * imageSize.width, y: observation.topLeft.y * imageSize.height)
        let topRight = CGPoint(x: observation.topRight.x * imageSize.width, y: observation.topRight.y * imageSize.height)
        let bottomLeft = CGPoint(x: observation.bottomLeft.x * imageSize.width, y: observation.bottomLeft.y * imageSize.height)
        let bottomRight = CGPoint(x: observation.bottomRight.x * imageSize.width, y: observation.bottomRight.y * imageSize.height)

        // 1. Correção de Perspectiva (Warp)
        guard let correctionFilter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        correctionFilter.setValue(ciImage, forKey: kCIInputImageKey)
        correctionFilter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        correctionFilter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        correctionFilter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        correctionFilter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard var finalImage = correctionFilter.outputImage else { return nil }
        
        // 2. Aumento de Contraste e Brilho (Filtros de aprimoramento)
        if let contrastFilter = CIFilter(name: "CIColorControls") {
            contrastFilter.setValue(finalImage, forKey: kCIInputImageKey)
            contrastFilter.setValue(0.7, forKey: kCIInputContrastKey)
            contrastFilter.setValue(0.2, forKey: kCIInputBrightnessKey)
            finalImage = contrastFilter.outputImage!
        }
        
        // 3. Aplicação de Nitidez (Sharpness)
        if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(finalImage, forKey: kCIInputImageKey)
            sharpenFilter.setValue(0.9, forKey: kCIInputSharpnessKey)
            finalImage = sharpenFilter.outputImage!
        }
        
        // 4. Renderiza o resultado em um novo CVPixelBuffer
        var newPixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary

        let width = Int(finalImage.extent.width)
        let height = Int(finalImage.extent.height)

        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &newPixelBuffer)
        guard status == kCVReturnSuccess, let finalPixelBuffer = newPixelBuffer else { return nil }

        self.ciContext.render(finalImage, to: finalPixelBuffer)
        return finalPixelBuffer
    }
}
