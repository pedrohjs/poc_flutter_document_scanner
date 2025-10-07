import UIKit
import Flutter
import CoreMedia
import AVFoundation
import Vision

class DocumentScanner: NSObject, FlutterTexture, FlutterStreamHandler, CameraManagerDelegate, DocumentDetectorDelegate {
    
    // MARK: - Properties
    // Estado
    private var textureId: Int64 = 0
    private var isScanning: Bool = false
    private var pixelBuffer: CVPixelBuffer?
    private var lastFrameProcessed: TimeInterval = 0
    
    // Flutter
    private var registry: FlutterTextureRegistry
    private var commandChannel: FlutterMethodChannel
    private var eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?
    
    // Gerenciamento de Dependências
    private var cameraManager: CameraManager!
    private var documentDetector: DocumentDetector!
    private var imageProcessor: ImageProcessor!
    
    // MARK: - Initialization
    init(registry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
        self.registry = registry
        self.commandChannel = FlutterMethodChannel(name: Constants.commandChannelName, binaryMessenger: messenger)
        self.eventChannel = FlutterEventChannel(name: Constants.eventChannelName, binaryMessenger: messenger)
        
        super.init()
        
        // Inicializa as dependências
        self.cameraManager = CameraManager()
        self.documentDetector = DocumentDetector()
        self.imageProcessor = ImageProcessor()
        
        self.cameraManager.delegate = self
        self.documentDetector.delegate = self
        self.eventChannel.setStreamHandler(self)
        
        self.commandChannel.setMethodCallHandler(self.handleMethodCall)
    }
    
    // MARK: - FlutterTexture
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let buffer = pixelBuffer else { return nil }
        // Retorna o buffer de imagem da câmera para o Flutter
        return Unmanaged.passRetained(buffer)
    }
    
    func getTextureId() -> Int64? {
        return textureId
    }
    
    // MARK: - Command Channel Handler
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startScan":
            if #available(iOS 15.0, *) {
                self.startCamera()
                if let textureId = self.getTextureId() {
                    result(textureId)
                } else {
                    result(FlutterError(code: "CAMERA_START_FAILED", message: "Falha ao obter Texture ID.", details: nil))
                }
            } else {
                result(FlutterError(code: "UNSUPPORTED_VERSION", message: "iOS 15.0 ou superior é necessário.", details: nil))
            }
        case "manualCapture":
            self.manualCapture()
            result(nil)
        case "toggleFlash":
            if let flashLight = call.arguments as? Bool {
                self.toggleFlash(flashLight: flashLight)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Argumento 'flashLight' (Bool) é necessário.", details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
        
    // MARK: - Câmera (Orquestração do Ciclo de Vida)
    @available(iOS 15.0, *)
    func startCamera() {
        if textureId == 0 {
            textureId = registry.register(self)
        }
        
        cameraManager.setupAndStart { [weak self] success in
            guard let self = self else { return }
            if success {
                self.isScanning = true
                self.registry.textureFrameAvailable(self.textureId)
            } else {
                // Lidar com falha ao iniciar a câmera
            }
        }
    }
    
    func stopCamera() {
        isScanning = false
        cameraManager.stop()
        pixelBuffer = nil
        registry.unregisterTexture(textureId)
        textureId = 0
    }
    
    func pauseCamera() {
        isScanning = false
        cameraManager.pause()
    }
    
    func resumeCamera() {
        isScanning = true
        pixelBuffer = nil
        registry.textureFrameAvailable(textureId) // Força o Flutter a atualizar
        cameraManager.resume()
    }
    
    func toggleFlash(flashLight: Bool) {
        cameraManager.toggleFlash(on: flashLight)
    }
    
    func manualCapture() {
        cameraManager.manualCapture()
    }
    
    // MARK: - CameraManagerDelegate (Recebendo Frames)
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        guard isScanning else { return }
        
        // 1. Atualizar a Texture
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            DispatchQueue.main.sync {
                self.pixelBuffer = imageBuffer
                self.registry.textureFrameAvailable(self.textureId)
            }
        }
        
        // 2. Detecção de Documento (Limite a frequência para economizar CPU)
        let currentTime = CACurrentMediaTime()
        if currentTime - lastFrameProcessed >= 0.25 { // Limita a ~4 FPS para Vision
            lastFrameProcessed = currentTime
            
            // Roda a detecção em uma thread de background para não travar a UI/Camera
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                self.documentDetector.detectDocument(in: pixelBuffer)
            }
        }
    }
    
    func cameraManager(_ manager: CameraManager, didFinishProcessingPhoto photoData: Data?, error: Error?) {
        guard let eventSink = self.eventSink else { return }
        
        if let data = photoData {
            let event: [String: Any] = [
                "eventType": "manual_capture",
                "data": FlutterStandardTypedData(bytes: data)
            ]
            eventSink(event)
        } else {
            eventSink(FlutterError(code: "CAPTURE_ERROR", message: "Erro ao obter dados da imagem.", details: error?.localizedDescription))
            print("Error getting image data: \(error?.localizedDescription ?? "")")
        }
    }
    
    // MARK: - DocumentDetectorDelegate (Recebendo Resultados da Detecção)
    @available(iOS 15.0, *)
    func documentDetector(_ detector: DocumentDetector, didDetectStableDocument observation: VNRectangleObservation, in pixelBuffer: CVPixelBuffer) {
        processAndSendDocument(observation, pixelBuffer: pixelBuffer)
    }
    
    func documentDetector(_ detector: DocumentDetector, didUpdateVertices observation: VNRectangleObservation?, in pixelBuffer: CVPixelBuffer) {
        sendRectangleVertices(observation, pixelBuffer: pixelBuffer)
    }
    
    // MARK: - Processamento de Documento e Comunicação Flutter
    @available(iOS 15.0, *)
    private func processAndSendDocument(_ observation: VNRectangleObservation, pixelBuffer: CVPixelBuffer) {
        // 1. Processar Imagem (Correção de Perspectiva e Filtros)
        guard let croppedBuffer = imageProcessor.createWarpedPixelBuffer(for: observation, from: pixelBuffer),
              let image = imageProcessor.pixelBufferToUIImage(pixelBuffer: croppedBuffer),
              let imageData = image.jpegData(compressionQuality: 1.0) else { return }
        
        guard let eventSink = self.eventSink else { return }
        
        // 2. Enviar o resultado final para o Flutter
        let event: [String: Any] = [
            "eventType": "document_captured",
            "data": FlutterStandardTypedData(bytes: imageData)
        ]
        eventSink(event)
    }
    
    private func sendRectangleVertices(_ observation: VNRectangleObservation?, pixelBuffer: CVPixelBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let eventSink = self.eventSink else { return }
            
            var data: [String: Any] = [:]
            
            if let observation = observation {
                let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
                let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
                
                // Função auxiliar para conversão e inversão do eixo Y
                func convertAndFlipY(point: CGPoint, width: CGFloat, height: CGFloat) -> [String: Int] {
                    let x = Int(point.x * width)
                    let y = Int((1.0 - point.y) * height)
                    return ["x": x, "y": y]
                }
                
                data = [
                    "topLeft": convertAndFlipY(point: observation.topLeft, width: imageWidth, height: imageHeight),
                    "topRight": convertAndFlipY(point: observation.topRight, width: imageWidth, height: imageHeight),
                    "bottomRight": convertAndFlipY(point: observation.bottomRight, width: imageWidth, height: imageHeight),
                    "bottomLeft": convertAndFlipY(point: observation.bottomLeft, width: imageWidth, height: imageHeight),
                    "imageNativeWidth": Int(imageWidth),
                    "imageNativeHeight": Int(imageHeight),
                ]
            }
            
            let event: [String: Any] = [
                "eventType": "vertices_update",
                "data": data
            ]
            eventSink(event)
        }
    }
    
    // MARK: - FlutterStreamHandler
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        print("Flutter assinou o Event Channel.")
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        print("Flutter cancelou o Event Channel.")
        return nil
    }
}
