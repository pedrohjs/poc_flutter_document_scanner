import 'dart:io';

import 'package:document_scanner_poc/document_scanner.dart';
import 'package:document_scanner_poc/rectangle_painter.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class DocumentScanPage extends StatefulWidget {
  const DocumentScanPage({super.key});

  @override
  State<DocumentScanPage> createState() => _DocumentScanPageState();
}

class _DocumentScanPageState extends State<DocumentScanPage> {
  final _scanner = DocumentScanner();

  File? file;
  Size _imageNativeSize = Size(1, 1);

  Future<void> _requestCameraPermission() async {
    await Permission.camera.request();
  }

  Future<int?> getTextureId() async {
    return await _scanner.getTextureId();
  }

  void _onGetDocument() {
    _scanner.subscribeDocumentStream();

    _scanner.getDocumentStream().listen((event) async {
      final file = File(
        '${Directory.systemTemp.path}/ocr-${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(event);

      setState(() {
        this.file = file;
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
    _scanner.subscribeVerticesStream();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Document Scanner POC')),
        body: FutureBuilder<int?>(
          future: getTextureId(),
          builder: (_, snapshot) {
            if (snapshot.hasData) {
              return Stack(
                children: [
                  Texture(textureId: snapshot.data!),
                  StreamBuilder<dynamic>(
                    stream: _scanner.getVerticesStream(),
                    builder: (context, streamSnapshot) {
                      List<Offset> rectangleVertices = [];

                      if (streamSnapshot.hasData) {
                        final Map<dynamic, dynamic> verticesMap =
                            streamSnapshot.data;

                        // Checa se a lista de vértices não está vazia
                        if (verticesMap.containsKey('topLeft')) {
                          if (verticesMap.containsKey('imageNativeWidth')) {
                            _imageNativeSize = Size(
                              verticesMap['imageNativeWidth'].toDouble(),
                              verticesMap['imageNativeHeight'].toDouble(),
                            );
                          }

                          rectangleVertices = [
                            Offset(
                              verticesMap['topLeft']['x'].toDouble(),
                              verticesMap['topLeft']['y'].toDouble(),
                            ),
                            Offset(
                              verticesMap['topRight']['x'].toDouble(),
                              verticesMap['topRight']['y'].toDouble(),
                            ),
                            Offset(
                              verticesMap['bottomRight']['x'].toDouble(),
                              verticesMap['bottomRight']['y'].toDouble(),
                            ),
                            Offset(
                              verticesMap['bottomLeft']['x'].toDouble(),
                              verticesMap['bottomLeft']['y'].toDouble(),
                            ),
                          ];
                        }
                      }

                      return LayoutBuilder(
                        builder: (
                          BuildContext context,
                          BoxConstraints constraints,
                        ) {
                          final double previewWidth = constraints.maxWidth;
                          final double previewHeight = constraints.maxHeight;

                          final double scaleX =
                              previewWidth / _imageNativeSize.width;
                          final double scaleY =
                              previewHeight / _imageNativeSize.height;

                          final List<Offset> scaledVertices =
                              rectangleVertices.map((v) {
                                return Offset(v.dx * scaleX, v.dy * scaleY);
                              }).toList();

                          return CustomPaint(
                            painter: RectanglePainter(vertices: scaledVertices),
                            child: Container(),
                          );
                        },
                      );
                    },
                  ),
                  Positioned(
                    bottom: 60,
                    right: 20,
                    child:
                        file == null
                            ? SizedBox(
                              height: 120,
                              width: 80,
                              child: Container(color: Colors.white24),
                            )
                            : SizedBox(
                              height: 120,
                              width: 80,
                              child: Image.file(file!),
                            ),
                  ),
                ],
              );
            } else {
              return const CircularProgressIndicator();
            }
          },
        ),
      ),
    );
  }
}
