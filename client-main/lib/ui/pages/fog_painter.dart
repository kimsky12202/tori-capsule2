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

    // 아침 안개
    canvas.drawRect(bounds, Paint()..color = const Color(0xCDD4E8F2));

    // 건물 모양대로 안개 걷힘 (소프트 엣지)
    for (final poly in polygons) {
      if (poly.length < 3) continue;

      final path = Path();
      path.moveTo(poly.first.dx, poly.first.dy);
      for (final pt in poly.skip(1)) {
        path.lineTo(pt.dx, pt.dy);
      }
      path.close();

      // 건물 내부 완전히 걷힘
      canvas.drawPath(
        path,
        Paint()
          ..blendMode = BlendMode.dstOut
          ..color = Colors.black,
      );

      // 경계 부드럽게 페이드
      canvas.drawPath(
        path,
        Paint()
          ..blendMode = BlendMode.dstOut
          ..color = Colors.black.withValues(alpha: 0.55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }

    canvas.restore();

    // 건물 위에 따뜻한 아침 햇살 글로우
    for (final center in centers) {
      canvas.drawCircle(
        center,
        55,
        Paint()
          ..color = const Color(0x22FFB347)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 38),
      );
      canvas.drawCircle(
        center,
        18,
        Paint()
          ..color = const Color(0x30FFD580)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
    }
  }

  @override
  bool shouldRepaint(GradientFogPainter old) =>
      old.polygons != polygons || old.centers != centers;
}
