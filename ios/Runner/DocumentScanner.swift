import UIKit
import Flutter
import CoreImage
import AVFoundation
import Vision

class DocumentScanner: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    private var textureId: Int64 = 0
    private var isScanning: Bool = false
    private var isProcessingDocument = false
    private var pixelBuffer: CVPixelBuffer?
    private var registry: FlutterTextureRegistry
    private var captureSession: AVCaptureSession?
    private var commandChannel: FlutterMethodChannel
    private var videoCaptureDevice: AVCaptureDevice?
    private var consecutiveLowEdges: Int = 0
    private let maxEdges: Int = 50
    private var isInAnotherCamera: Bool = false
    private var lastFrameProcessed: TimeInterval = 0
    private var photoOutput: AVCapturePhotoOutput!

    // MARK: - Initialization
    init(registry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
        self.registry = registry
        self.commandChannel = FlutterMethodChannel(name: "document_scanner", binaryMessenger: messenger)
        super.init()
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
        if let device = findCamera() {
            videoCaptureDevice = device
        } else {
            guard let defaultDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            videoCaptureDevice = defaultDevice
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
        isInAnotherCamera = false
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            if !session.isRunning {
                session.startRunning()
            }
            self.registry.textureFrameAvailable(self.textureId)
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
            if currentTime - lastFrameProcessed >= 1.0 {
                lastFrameProcessed = currentTime
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                    self.detectDocument(in: pixelBuffer)
                }
            }

            if consecutiveLowEdges >= maxEdges, !isInAnotherCamera {
                if #available(iOS 13.0, *) {
                    switchToAngleWideCamera()
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
            print("Error getting image data: \(error?.localizedDescription ?? "")")
            return
        }
        
        // Send the captured image data to Flutter
        commandChannel.invokeMethod("onManualImageCaptured", arguments: FlutterStandardTypedData(bytes: imageData))
    }

    // MARK: - Document Detection
    private func detectDocument(in pixelBuffer: CVPixelBuffer) {
        guard #available(iOS 15, *) else { return }
        if isProcessingDocument { return }
        isProcessingDocument = true

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
                self.sendRectangleVertices(documentObservation, pixelBuffer: pixelBuffer)
                self.processAndSendDocument(documentObservation, pixelBuffer: pixelBuffer)
            } else {
                print("Documento detectado com baixa confiança: \(documentObservation.confidence)")
                self.sendRectangleVertices(nil, pixelBuffer: pixelBuffer)
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }
    
    private func sendRectangleVertices(_ observation: VNRectangleObservation?, pixelBuffer: CVPixelBuffer) {
        guard let observation = observation else {
            let vertices: [String: Any] = ["vertices": []]
            commandChannel.invokeMethod("onDocumentRecognized", arguments: vertices)
            return
        }

        let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

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

        commandChannel.invokeMethod("onDocumentRecognized", arguments: vertices)
    }

    @available(iOS 15.0, *)
    private func processAndSendDocument(_ observation: VNRectangleObservation, pixelBuffer: CVPixelBuffer) {
        guard let croppedBuffer = createWarpedPixelBuffer(for: observation, from: pixelBuffer),
              let image = pixelBufferToUIImage(pixelBuffer: croppedBuffer),
              let imageData = image.jpegData(compressionQuality: 0.9) else { return }

        // Envia apenas a imagem recortada
        commandChannel.invokeMethod("onDocumentImageCaptured", arguments: FlutterStandardTypedData(bytes: imageData))
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

    @available(iOS 13.0, *)
    private func switchToAngleWideCamera() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }

            guard let camera = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: .back).devices.first else { return }
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(input) {
                    session.addInput(input)
                    self.videoCaptureDevice = camera
                }
            } catch { print("Error configuring camera: \(error.localizedDescription)") }
            session.startRunning()
            self.isInAnotherCamera = true
        }
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

        if edgeCount == 0 {
            consecutiveLowEdges += 1
        } else {
            consecutiveLowEdges = 0
        }
    }
}
