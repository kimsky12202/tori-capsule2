import 'package:flutter/material.dart';

class GradientFogPainter extends CustomPainter {
  final List<List<Offset>> polygons;
  final List<Offset> centers;

  const GradientFogPainter({
    required this.polygons,
    required this.centers,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Rect.fromLTWH(0, 0, size.width, size.height);

    canvas.saveLayer(bounds, Paint());

    // 아침 안개 - 연한 회청색 (지도 색과 대비 확보)
    canvas.drawRect(
      bounds,
      Paint()..color = const Color(0xD0C8D8E8),
    );

    // 건물 모양대로 안개 걷힘
    for (final poly in polygons) {
      if (poly.length < 3) continue;

      final path = Path();
      path.moveTo(poly.first.dx, poly.first.dy);
      for (final pt in poly.skip(1)) {
        path.lineTo(pt.dx, pt.dy);
      }
      path.close();

      // 내부 완전히 걷힘
      canvas.drawPath(
        path,
        Paint()
          ..blendMode = BlendMode.dstOut
          ..color = Colors.black,
      );

      // 경계 부드러운 페이드 (20px)
      canvas.drawPath(
        path,
        Paint()
          ..blendMode = BlendMode.dstOut
          ..color = Colors.black.withValues(alpha: 0.6)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
      );
    }

    canvas.restore();

    // 아침 햇살 글로우
    for (final center in centers) {
      canvas.drawCircle(
        center,
        70,
        Paint()
          ..color = const Color(0x1EFFA040)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 45),
      );
      canvas.drawCircle(
        center,
        22,
        Paint()
          ..color = const Color(0x28FFD080)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
      );
    }
  }

  @override
  bool shouldRepaint(GradientFogPainter old) =>
      old.polygons != polygons || old.centers != centers;
}
