import 'dart:async';

import 'package:flutter/services.dart';

class DocumentScanner {
  final channel = const MethodChannel('document_scanner');

  Future<int?> getTextureId() async => await channel.invokeMethod('startScan');

  void manualCapture() => channel.invokeMethod('manualCapture');

  void toggleFlash(bool active) => channel.invokeMethod('toggleFlash', active);

  StreamController<Uint8List> documentStreamController =
      StreamController<Uint8List>();
  StreamController<Map<dynamic, dynamic>> verticesStreamController =
      StreamController<Map<dynamic, dynamic>>();

  Stream<Uint8List> getDocumentStream() => documentStreamController.stream;

  Stream<Map<dynamic, dynamic>> getVerticesStream() =>
      verticesStreamController.stream;

  void documentScannerHandler() {
    channel.setMethodCallHandler((handler) async {
      if (handler.method == "onDocumentRecognized") {
        if (handler.arguments is Map<dynamic, dynamic>) {
          verticesStreamController.add(handler.arguments);
        }
      }

      if (handler.method == "onDocumentImageCaptured" ||
          handler.method == "onManualImageCaptured") {
        final Uint8List imageData = handler.arguments;
        documentStreamController.add(imageData);
      }
    });
  }
}
