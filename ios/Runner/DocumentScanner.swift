import UIKit
import Flutter
import CoreImage
import AVFoundation
import Vision

class DocumentScanner: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, FlutterStreamHandler {
    private var textureId: Int64 = 0
    private var isScanning: Bool = false
    private var isProcessingDocument = false
    private var pixelBuffer: CVPixelBuffer?
    private var registry: FlutterTextureRegistry
    private var captureSession: AVCaptureSession?
    private var videoCaptureDevice: AVCaptureDevice?
    private var lastFrameProcessed: TimeInterval = 0
    private var photoOutput: AVCapturePhotoOutput!
    private var lastStableObservation: VNRectangleObservation?
    private var stableObservationStartTime: TimeInterval?
    private var commandChannel: FlutterMethodChannel
    private var eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    // MARK: - Initialization
    init(registry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
        self.registry = registry
        self.commandChannel = FlutterMethodChannel(name: "document_scanner", binaryMessenger: messenger)
        self.eventChannel = FlutterEventChannel(name: "document_scanner_events", binaryMessenger: messenger)
        super.init()
        
        self.eventChannel.setStreamHandler(self)
    }

    func getTextureId() -> Int64 {
        return textureId
    }

    // MARK: - Camera Lifecycle
    @available(iOS 15.0, *)
    func startCamera() {
        textureId = registry.register(self)
        pixelBuffer = nil
        registry.textureFrameAvailable(textureId)

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .hd1280x720

        let videoCaptureDevice: AVCaptureDevice
        if let ultraWideDevice = AVCaptureDevice.DiscoverySession(
               deviceTypes: [.builtInUltraWideCamera],
               mediaType: .video,
               position: .back
           ).devices.first
        {
            videoCaptureDevice = ultraWideDevice
        }
        else if let defaultWideDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            videoCaptureDevice = defaultWideDevice
        } else {
            return
        }

        guard let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else { return }
        self.videoCaptureDevice = videoCaptureDevice
        self.captureSession = captureSession
        self.resumeCamera()

        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            return
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera_queue"))
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        self.photoOutput = AVCapturePhotoOutput()
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }
    }
    
    func stopCamera() {
        isScanning = false
        captureSession?.stopRunning()
        pixelBuffer = nil
        registry.unregisterTexture(textureId)
        textureId = 0
        captureSession = nil
        videoCaptureDevice = nil
    }

    func pauseCamera() {
        isScanning = false
        DispatchQueue.global(qos: .background).async {
            self.captureSession?.stopRunning()
        }
    }

    func resumeCamera() {
        isScanning = true
        pixelBuffer = nil
        registry.textureFrameAvailable(textureId)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            if !session.isRunning {
                session.startRunning()
            }
            
            DispatchQueue.main.async {
                self.registry.textureFrameAvailable(self.textureId)
            }
        }
    }
    
    func toggleFlash(flashLight: Bool) {
        guard let device = videoCaptureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = flashLight ? .on : .off
            device.unlockForConfiguration()
        } catch { print(error.localizedDescription) }
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let buffer = pixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    // MARK: - AVCapture Delegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if isScanning {
            if output is AVCaptureVideoDataOutput {
                DispatchQueue.main.sync {
                    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        if let videoOrientation = currentVideoOrientation() {
                            connection.videoOrientation = videoOrientation
                        }
                        self.pixelBuffer = imageBuffer
                        self.registry.textureFrameAvailable(self.textureId)
                    }
                }
            }

            DispatchQueue.main.async {
                self.checkFrameSharpness(sampleBuffer)
            }

            let currentTime = CACurrentMediaTime()
            if currentTime - lastFrameProcessed >= 0.25 {
                lastFrameProcessed = currentTime
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                    self.detectDocument(in: pixelBuffer)
                }
            }
        }
    }
    
    // MARK: - Manual Capture Method
    func manualCapture() {
        let photoSettings = AVCapturePhotoSettings()
        
        self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let imageData = photo.fileDataRepresentation() else {
            self.eventSink?(FlutterError(code: "CAPTURE_ERROR", message: "Erro ao obter dados da imagem.", details: error?.localizedDescription))
            print("Error getting image data: \(error?.localizedDescription ?? "")")
            return
        }
            
        guard let eventSink = self.eventSink else { return }

        // Send the captured image data to Flutter
        let event: [String: Any] = [
            "eventType": "manual_capture",
            "data": FlutterStandardTypedData(bytes: imageData)
        ]

        eventSink(event)
    }

    // MARK: - Document Detection
    private func detectDocument(in pixelBuffer: CVPixelBuffer) {
        guard #available(iOS 15, *) else { return }
        if isProcessingDocument { return }
        isProcessingDocument = true
        
        let currentTimestamp = CACurrentMediaTime()

        let request = VNDetectDocumentSegmentationRequest { [weak self] request, error in
            guard let self = self else { return }
            defer { self.isProcessingDocument = false }

            if let error = error {
                print("Document detection error: \(error)")
                return
            }

            guard let observations = request.results as? [VNRectangleObservation],
                  let documentObservation = observations.first else { return }
            
            let minConfidence: Float = 0.8

            if documentObservation.confidence > minConfidence {
                        
                        // 1. Sempre envia os vértices (para o overlay no Flutter)
                        self.sendRectangleVertices(documentObservation, pixelBuffer: pixelBuffer)

                        // 2. Verifica a estabilidade do documento (comparado com o quadro anterior)
                        let isCurrentlyStable = self.isObservationStable(documentObservation)

                        if isCurrentlyStable {
                            if self.stableObservationStartTime == nil {
                                // Primeiro quadro estável, inicia o cronômetro
                                self.stableObservationStartTime = currentTimestamp
                                print("Iniciando cronômetro de estabilidade.")
                            }
                            
                            let elapsedTime = currentTimestamp - (self.stableObservationStartTime ?? currentTimestamp)
                            
                            if elapsedTime >= Constants.stabilityDelay {
                                // 3. Estabilidade atingida! Captura a imagem.
                                print("Estabilidade confirmada após \(elapsedTime) segundos. Capturando documento.")
                                
                                // Resetamos o estado imediatamente para não capturar novamente no próximo frame de detecção
                                self.stableObservationStartTime = nil
                                self.lastStableObservation = nil
                                self.processAndSendDocument(documentObservation, pixelBuffer: pixelBuffer)
                            } else {
                                // Ainda estável, mas aguardando o tempo
                                print("Documento estável, aguardando... Faltam \(Constants.stabilityDelay - elapsedTime)s")
                            }
                        } else {
                            // O documento se moveu ou é a primeira detecção, reseta o cronômetro.
                            print("Documento se moveu ou é nova detecção. Reiniciando cronômetro.")
                            self.stableObservationStartTime = nil
                        }
                        
                        // 4. Armazena a observação atual para a verificação de estabilidade do próximo quadro
                        self.lastStableObservation = documentObservation

                    } else {
                        // Confiança baixa, reseta o estado de estabilidade e envia vértices nulos
                        print("Documento detectado com baixa confiança: \(documentObservation.confidence)")
                        self.lastStableObservation = nil
                        self.stableObservationStartTime = nil
                        self.sendRectangleVertices(nil, pixelBuffer: pixelBuffer)
                    }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }
    
    private func sendRectangleVertices(_ observation: VNRectangleObservation?, pixelBuffer: CVPixelBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let eventSink = self.eventSink else { return }

            // 1. Caso de Documento DETECTADO: Envia o mapa de vértices.
            if let observation = observation {
                let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
                let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

                // Função auxiliar para conversão e inversão do eixo Y
                func convertAndFlipY(point: CGPoint, width: CGFloat, height: CGFloat) -> [String: Int] {
                    let x = Int(point.x * width)
                    let y = Int((1.0 - point.y) * height)
                    return ["x": x, "y": y]
                }

                let topLeft = convertAndFlipY(point: observation.topLeft, width: imageWidth, height: imageHeight)
                let topRight = convertAndFlipY(point: observation.topRight, width: imageWidth, height: imageHeight)
                let bottomRight = convertAndFlipY(point: observation.bottomRight, width: imageWidth, height: imageHeight)
                let bottomLeft = convertAndFlipY(point: observation.bottomLeft, width: imageWidth, height: imageHeight)

                let vertices: [String: Any] = [
                    "topLeft": topLeft,
                    "topRight": topRight,
                    "bottomRight": bottomRight,
                    "bottomLeft": bottomLeft,
                    "imageNativeWidth": Int(imageWidth),
                    "imageNativeHeight": Int(imageHeight),
                ]
                
                let event: [String: Any] = [
                    "eventType": "vertices_update",
                    "data": vertices
                ]
                
                eventSink(event)
            } else {
                // 2. Caso de Documento NÃO DETECTADO: Envia o mapa vazio para limpar o overlay no Flutter.
                let event: [String: Any] = [
                    "eventType": "vertices_update",
                    "data": [:]
                ]
                
                eventSink(event)
            }
        }
    }

    @available(iOS 15.0, *)
    private func processAndSendDocument(_ observation: VNRectangleObservation, pixelBuffer: CVPixelBuffer) {
        guard let croppedBuffer = createWarpedPixelBuffer(for: observation, from: pixelBuffer),
                  let image = pixelBufferToUIImage(pixelBuffer: croppedBuffer),
                  let imageData = image.jpegData(compressionQuality: 1.0) else { return }

            guard let eventSink = self.eventSink else { return } // Verifica se alguém está escutando

            // Envia o resultado final
            let event: [String: Any] = [
                "eventType": "document_captured",
                "data": FlutterStandardTypedData(bytes: imageData)
            ]
            
            eventSink(event)
            
            // self.pauseCamera()
    }
    
    // MARK: - Stability Check
    private func isObservationStable(_ newObservation: VNRectangleObservation) -> Bool {
        guard let lastObservation = lastStableObservation else {
            // Se for a primeira detecção, não podemos compará-la, então consideramos instável por enquanto.
            return false
        }
        
        func isPointSimilar(_ p1: CGPoint, _ p2: CGPoint) -> Bool {
            // Verifica se a mudança nas coordenadas normalizadas é menor que o threshold
            return abs(p1.x - p2.x) < Constants.stabilityThreshold && abs(p1.y - p2.y) < Constants.stabilityThreshold
        }

        let topLeftStable = isPointSimilar(newObservation.topLeft, lastObservation.topLeft)
        let topRightStable = isPointSimilar(newObservation.topRight, lastObservation.topRight)
        let bottomLeftStable = isPointSimilar(newObservation.bottomLeft, lastObservation.bottomLeft)
        let bottomRightStable = isPointSimilar(newObservation.bottomRight, lastObservation.bottomRight)

        // O documento é considerado estável se todos os quatro cantos não se moveram significativamente.
        return topLeftStable && topRightStable && bottomLeftStable && bottomRightStable
    }
    

    // MARK: - Utils
    private func pixelBufferToUIImage(pixelBuffer: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func createWarpedPixelBuffer(for observation: VNRectangleObservation, from pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageSize = ciImage.extent.size
        
        let topLeft = CGPoint(x: observation.topLeft.x * imageSize.width, y: observation.topLeft.y * imageSize.height)
        let topRight = CGPoint(x: observation.topRight.x * imageSize.width, y: observation.topRight.y * imageSize.height)
        let bottomLeft = CGPoint(x: observation.bottomLeft.x * imageSize.width, y: observation.bottomLeft.y * imageSize.height)
        let bottomRight = CGPoint(x: observation.bottomRight.x * imageSize.width, y: observation.bottomRight.y * imageSize.height)

        guard let correctionFilter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        correctionFilter.setValue(ciImage, forKey: kCIInputImageKey)
        correctionFilter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        correctionFilter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        correctionFilter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        correctionFilter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let correctedImage = correctionFilter.outputImage else { return nil }
        
        var finalImage = correctedImage
            
        // 1. Aumento de Contraste e Brilho
        if let contrastFilter = CIFilter(name: "CIColorControls") {
            contrastFilter.setValue(finalImage, forKey: kCIInputImageKey)
            contrastFilter.setValue(0.7, forKey: kCIInputContrastKey)
            contrastFilter.setValue(0.2, forKey: kCIInputBrightnessKey)
            finalImage = contrastFilter.outputImage!
        }
        
        // 2. Aplicação de Nitidez (Sharpness)
        if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(finalImage, forKey: kCIInputImageKey)
            sharpenFilter.setValue(0.9, forKey: kCIInputSharpnessKey)
            finalImage = sharpenFilter.outputImage!
        }

        let context = CIContext(options: nil)
        var newPixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary

        let width = Int(correctedImage.extent.width)
        let height = Int(correctedImage.extent.height)

        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &newPixelBuffer)
        guard status == kCVReturnSuccess, let finalPixelBuffer = newPixelBuffer else { return nil }

        context.render(correctedImage, to: finalPixelBuffer)
        return finalPixelBuffer
    }

    func currentVideoOrientation() -> AVCaptureVideoOrientation? {
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .landscapeRight: return .landscapeLeft
        case .landscapeLeft: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    @available(iOS 13.0, *)
    private func findCamera() -> AVCaptureDevice? {
        return AVCaptureDevice.default(for: .video)
    }

    private func checkFrameSharpness(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return }
        let sampleSize = 20
        var edgeCount = 0

        for y in (height/2 - sampleSize)...(height/2 + sampleSize) {
            guard y >= 0 && y < height else { continue }
            let row = baseAddress + y * bytesPerRow
            for x in (width/2 - sampleSize)...(width/2 + sampleSize) {
                guard x >= 0 && x < width else { continue }
                let pixel = row.load(fromByteOffset: x * 4, as: UInt32.self)
                let r = Float((pixel >> 16) & 0xFF)
                let g = Float((pixel >> 8) & 0xFF)
                let b = Float(pixel & 0xFF)
                let luminance = (0.299 * r + 0.587 * g + 0.114 * b)
                if luminance < 30 || luminance > 220 { edgeCount += 1 }
            }
        }
    }
}

// MARK: - FlutterStreamHandler
extension DocumentScanner {
    
    // 1. Chamado quando o Flutter chama 'receiveBroadcastStream()'
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events

        print("Flutter assinou o Event Channel. EventSink configurado.")
        
        // Se você não for usar um Method Channel para iniciar, você pode iniciar o reconhecimento aqui:
        // self.isScanning = true // Exemplo de inicialização
        return nil
    }

    // 2. Chamado quando o Flutter cancela a escuta do 'Stream'
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        // ESTE É O PONTO MAIS IMPORTANTE: Limpeza de recursos!
        // Pare o processamento de frames para economizar bateria.
        // Se o reconhecimento estiver ativado, pare-o agora.
        
        // Se o reconhecimento for ativado pelo Event Channel, pare aqui:
        // self.isScanning = false // Exemplo de limpeza
        print("Flutter cancelou o Event Channel. EventSink zerado.")
        return nil
    }
}
