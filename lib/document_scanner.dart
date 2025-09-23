import 'dart:async';

import 'package:flutter/services.dart';

class DocumentScanner {
  final channel = const MethodChannel('document_scanner');

  Future<int?> getTextureId() async {
    return await channel.invokeMethod('startScan');
  }

  void documentScannerHandler() {
    channel.setMethodCallHandler((handler) async {
      if (handler.method == "onDocumentRecognized") {
        if (handler.arguments is Map<dynamic, dynamic>) {
          verticesStreamController.add(handler.arguments);
        }
      }

      if (handler.method == "onDocumentImageCaptured") {
        final Uint8List imageData = handler.arguments;
        documentStreamController.add(imageData);
      }
    });
  }

  Stream<Uint8List> getDocumentStream() {
    return documentStreamController.stream;
  }

  Stream<Map<dynamic, dynamic>> getVerticesStream() {
    return verticesStreamController.stream;
  }

  StreamController<Uint8List> documentStreamController =
      StreamController<Uint8List>();
  StreamController<Map<dynamic, dynamic>> verticesStreamController =
      StreamController<Map<dynamic, dynamic>>();
}
