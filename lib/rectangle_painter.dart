import 'package:flutter/material.dart';

// Este widget desenha o polígono com base nos vértices
class RectanglePainter extends CustomPainter {
  final List<Offset> vertices;

  RectanglePainter({required this.vertices});

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.length < 4) {
      return;
    }

    final fillPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    path.moveTo(vertices[0].dx, vertices[0].dy);
    path.lineTo(vertices[1].dx, vertices[1].dy);
    path.lineTo(vertices[2].dx, vertices[2].dy);
    path.lineTo(vertices[3].dx, vertices[3].dy);
    path.close();

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return (oldDelegate as RectanglePainter).vertices != vertices;
  }
}