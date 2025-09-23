import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    
    private var documentScanner: DocumentScanner? = nil
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
        
        let documentScannerChannel = FlutterMethodChannel(
            name: "document_scanner",
            binaryMessenger: controller.binaryMessenger
        )
        
        let messenger = controller.engine.binaryMessenger
        let textures = controller.engine.textureRegistry
        
        documentScanner = DocumentScanner(registry: textures, messenger: messenger)
        
        documentScannerChannel.setMethodCallHandler({
            [weak self] (call: FlutterMethodCall, result: FlutterResult) -> Void in
            switch (call.method){
            case "startScan":
                if #available(iOS 15.0, *) {
                    self?.documentScanner?.startCamera()
                    if let textureId = self?.documentScanner?.getTextureId() {
                        result(textureId)
                    }
                }
            case "manualCapture":
                self?.documentScanner?.manualCapture()
                result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        })
        
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
