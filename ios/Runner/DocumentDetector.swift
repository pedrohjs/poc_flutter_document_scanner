//
//  DocumentDetector.swift
//  Runner
//
//  Created by Pedro Santos on 07/10/25.
//

import Foundation
import Vision
import CoreMedia

protocol DocumentDetectorDelegate: AnyObject {
    @available(iOS 15.0, *)
    func documentDetector(_ detector: DocumentDetector, didDetectStableDocument observation: VNRectangleObservation, in pixelBuffer: CVPixelBuffer)
    func documentDetector(_ detector: DocumentDetector, didUpdateVertices observation: VNRectangleObservation?, in pixelBuffer: CVPixelBuffer)
}

class DocumentDetector {
    
    weak var delegate: DocumentDetectorDelegate?
    
    private var isProcessingDocument = false
    private var lastStableObservation: VNRectangleObservation?
    private var stableObservationStartTime: TimeInterval?

    /// Inicia a detecção de documento em um CVPixelBuffer.
    func detectDocument(in pixelBuffer: CVPixelBuffer) {
        guard #available(iOS 15, *) else { return }
        if isProcessingDocument { return }
        isProcessingDocument = true
        
        let currentTimestamp = CACurrentMediaTime()

        let request = VNDetectDocumentSegmentationRequest { [weak self] request, error in
            guard let self = self else { return }
            defer { self.isProcessingDocument = false }

            if let error = error {
                print("Document detection error: \(error.localizedDescription)")
                self.handleNoObservation(in: pixelBuffer)
                return
            }

            guard let observations = request.results as? [VNRectangleObservation],
                  let documentObservation = observations.first else {
                self.handleNoObservation(in: pixelBuffer)
                return
            }
            
            let minConfidence: Float = 0.8

            if documentObservation.confidence > minConfidence {
                self.delegate?.documentDetector(self, didUpdateVertices: documentObservation, in: pixelBuffer)
                
                let isCurrentlyStable = self.isObservationStable(documentObservation)

                if isCurrentlyStable {
                    self.handleStableObservation(documentObservation, currentTimestamp: currentTimestamp, pixelBuffer: pixelBuffer)
                } else {
                    // Documento se moveu, reseta o cronômetro
                    self.stableObservationStartTime = nil
                    print("Documento se moveu ou é nova detecção. Reiniciando cronômetro.")
                }
                
                // Armazena a observação atual para a verificação de estabilidade do próximo quadro
                self.lastStableObservation = documentObservation

            } else {
                // Confiança baixa, reseta o estado de estabilidade e envia vértices nulos
                print("Documento detectado com baixa confiança: \(documentObservation.confidence)")
                self.handleNoObservation(in: pixelBuffer)
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }
    
    private func handleNoObservation(in pixelBuffer: CVPixelBuffer) {
        self.lastStableObservation = nil
        self.stableObservationStartTime = nil
        self.delegate?.documentDetector(self, didUpdateVertices: nil, in: pixelBuffer)
    }

    @available(iOS 15.0, *)
    private func handleStableObservation(_ documentObservation: VNRectangleObservation, currentTimestamp: TimeInterval, pixelBuffer: CVPixelBuffer) {
        if self.stableObservationStartTime == nil {
            // Primeiro quadro estável, inicia o cronômetro
            self.stableObservationStartTime = currentTimestamp
            print("Iniciando cronômetro de estabilidade.")
        }
        
        let elapsedTime = currentTimestamp - (self.stableObservationStartTime ?? currentTimestamp)
        
        if elapsedTime >= Constants.stabilityDelay {
            // Estabilidade atingida!
            print("Estabilidade confirmada após \(elapsedTime) segundos. Capturando documento.")
            self.stableObservationStartTime = nil
            self.lastStableObservation = nil
            self.delegate?.documentDetector(self, didDetectStableDocument: documentObservation, in: pixelBuffer)
        } else {
            // Ainda estável, mas aguardando o tempo
            print("Documento estável, aguardando... Faltam \(Constants.stabilityDelay - elapsedTime)s")
        }
    }
    
    /// Verifica se a observação atual está significativamente próxima da última.
    private func isObservationStable(_ newObservation: VNRectangleObservation) -> Bool {
        guard let lastObservation = lastStableObservation else {
            // Primeira detecção, não pode ser estável
            return false
        }
        
        func isPointSimilar(_ p1: CGPoint, _ p2: CGPoint) -> Bool {
            return abs(p1.x - p2.x) < Constants.stabilityThreshold && abs(p1.y - p2.y) < Constants.stabilityThreshold
        }

        let topLeftStable = isPointSimilar(newObservation.topLeft, lastObservation.topLeft)
        let topRightStable = isPointSimilar(newObservation.topRight, lastObservation.topRight)
        let bottomLeftStable = isPointSimilar(newObservation.bottomLeft, lastObservation.bottomLeft)
        let bottomRightStable = isPointSimilar(newObservation.bottomRight, lastObservation.bottomRight)

        // O documento é considerado estável se todos os quatro cantos não se moveram significativamente.
        return topLeftStable && topRightStable && bottomLeftStable && bottomRightStable
    }
}
