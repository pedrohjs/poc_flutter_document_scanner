//
//  CameraManager.swift
//  Runner
//
//  Created by Pedro Santos on 07/10/25.
//

import AVFoundation
import CoreMedia
import UIKit
import Flutter

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer)
    func cameraManager(_ manager: CameraManager, didFinishProcessingPhoto photoData: Data?, error: Error?)
}

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    
    weak var delegate: CameraManagerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var videoCaptureDevice: AVCaptureDevice?
    private var photoOutput: AVCapturePhotoOutput!
    
    private let videoOutputQueue = DispatchQueue(label: "camera_manager_video_queue", qos: .userInitiated)

    // MARK: - Lifecycle
    
    @available(iOS 15.0, *)
    func setupAndStart(completion: @escaping (Bool) -> Void) {
        // ... (Mesma lógica de inicialização de câmera que estava em DocumentScanner.startCamera()) ...
        
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720
        
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
            completion(false)
            return
        }

        guard let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else {
            completion(false)
            return
        }
        
        self.videoCaptureDevice = videoCaptureDevice
        self.captureSession = session

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        } else {
            completion(false)
            return
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        self.photoOutput = AVCapturePhotoOutput()
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        
        // Inicia a sessão
        videoOutputQueue.async {
            session.startRunning()
            DispatchQueue.main.async {
                completion(true)
            }
        }
    }
    
    func stop() {
        videoOutputQueue.async {
            self.captureSession?.stopRunning()
            self.captureSession = nil
            self.videoCaptureDevice = nil
        }
    }
    
    func pause() {
        videoOutputQueue.async {
            self.captureSession?.stopRunning()
        }
    }

    func resume() {
        videoOutputQueue.async {
            if let session = self.captureSession, !session.isRunning {
                session.startRunning()
            }
        }
    }

    func toggleFlash(on: Bool) {
        guard let device = videoCaptureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            print("Flash error: \(error.localizedDescription)")
        }
    }

    func manualCapture() {
        let photoSettings = AVCapturePhotoSettings()
        // Configurações adicionais de foto podem vir aqui, se necessário.
        self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
             // Atualiza a orientação do vídeo para que o `pixelBuffer` esteja correto
            if let videoOrientation = currentVideoOrientation() {
                connection.videoOrientation = videoOrientation
            }
            // Chama o delegado para processar o frame (texture, detecção, etc.)
            delegate?.cameraManager(self, didOutput: sampleBuffer)
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Pode ser usado para monitorar a performance
    }

    // MARK: - AVCapturePhotoCaptureDelegate
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let imageData = photo.fileDataRepresentation()
        // Chama o delegado com o resultado da foto
        delegate?.cameraManager(self, didFinishProcessingPhoto: imageData, error: error)
    }

    // MARK: - Utilities

    private func currentVideoOrientation() -> AVCaptureVideoOrientation? {
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .landscapeRight: return .landscapeLeft // Invertido por causa da câmera traseira
        case .landscapeLeft: return .landscapeRight // Invertido por causa da câmera traseira
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
}
