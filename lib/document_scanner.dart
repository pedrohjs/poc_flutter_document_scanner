import 'dart:async';

import 'package:flutter/services.dart';

class DocumentScanner {
  final commandChannel = const MethodChannel('document_scanner');
  final eventChannel = const EventChannel('document_scanner_events');

  Future<int?> getTextureId() async =>
      await commandChannel.invokeMethod('startScan');
  void manualCapture() => commandChannel.invokeMethod('manualCapture');
  void toggleFlash(bool active) =>
      commandChannel.invokeMethod('toggleFlash', active);

  late final Stream<dynamic> _rawEventBroadcastStream =
      eventChannel.receiveBroadcastStream().asBroadcastStream();

  Stream<dynamic> get _rawEventStream => _rawEventBroadcastStream;

  Stream<Map<dynamic, dynamic>> getVerticesStream() {
    return _rawEventStream
        .where(
          (event) => event is Map && event['eventType'] == 'vertices_update',
        )
        .map((event) => event['data'] as Map<dynamic, dynamic>);
  }

  Stream<Uint8List> getDocumentStream() {
    return _rawEventStream
        .where(
          (event) =>
              event is Map &&
              (event['eventType'] == 'document_captured' ||
                  event['eventType'] == 'manual_capture'),
        )
        .map((event) => event['data'] as Uint8List);
  }

  Stream<String> getErrorStream() {
    return eventChannel
        .receiveBroadcastStream()
        .handleError((error) {
          if (error is PlatformException) {
            return error.message ?? 'Unknown platform error';
          }
          return error.toString();
        })
        .where((event) => false)
        .cast<String>();
  }
}
