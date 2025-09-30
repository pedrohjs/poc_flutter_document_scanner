import 'package:flutter/material.dart';
import 'dart:typed_data';

class DocumentViewPage extends StatelessWidget {
  final Uint8List imageData;

  const DocumentViewPage({super.key, required this.imageData});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanned Document'),
      ),
      body: Center(
        child: Image.memory(imageData),
      ),
    );
  }
} 