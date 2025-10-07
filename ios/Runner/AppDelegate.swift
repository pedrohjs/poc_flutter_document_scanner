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
        
        let messenger = controller.engine.binaryMessenger
        let textures = controller.engine.textureRegistry
        
        documentScanner = DocumentScanner(registry: textures, messenger: messenger)
        
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
