import 'dart:async';

import 'package:flutter/services.dart';

class DocumentScanner {
  final channel = const MethodChannel('document_scanner');

  Future<int?> getTextureId() async {
    return await channel.invokeMethod('startScan');
  }

  void subscribeDocumentStream() {
    channel.setMethodCallHandler((handler) async {
      if (handler.method == "onDocumentCropped") {
        if (handler.arguments is List<int>) {
          documentStreamController.add(handler.arguments);
        }
      }
    });
  }

  void subscribeVerticesStream() {
    channel.setMethodCallHandler((handler) async {
      if (handler.method == "onDocumentRecognized") {
        if (handler.arguments is Map<dynamic, dynamic>) {
          verticesStreamController.add(handler.arguments);
        }
      }
    });
  }

  Stream<List<int>> getDocumentStream() {
    return documentStreamController.stream;
  }

  Stream<Map<dynamic, dynamic>> getVerticesStream() {
    return verticesStreamController.stream;
  }

  StreamController<List<int>> documentStreamController =
      StreamController<List<int>>();
  StreamController<Map<dynamic, dynamic>> verticesStreamController =
      StreamController<Map<dynamic, dynamic>>();
}
