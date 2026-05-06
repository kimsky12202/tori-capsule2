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

    // 안개 = 전체 화면에서 건물 폴리곤을 뺀 영역
    Path fogPath = Path()..addRect(bounds);

    for (final poly in polygons) {
      if (poly.length < 3) continue;
      final buildingPath = Path();
      buildingPath.moveTo(poly.first.dx, poly.first.dy);
      for (final pt in poly.skip(1)) {
        buildingPath.lineTo(pt.dx, pt.dy);
      }
      buildingPath.close();
      fogPath = Path.combine(PathOperation.difference, fogPath, buildingPath);
    }

    // 안개 그리기 (건물 영역은 구멍으로 제외됨)
    canvas.drawPath(
      fogPath,
      Paint()..color = const Color(0xD0C8D8E8),
    );

    // 아침 햇살 글로우 (사진 위치 중심)
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
