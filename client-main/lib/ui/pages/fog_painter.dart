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

    // 걷힌 구역 계산
    Path clearedPath = Path();
    for (final poly in polygons) {
      if (poly.length < 3) continue;
      final p = Path();
      p.moveTo(poly.first.dx, poly.first.dy);
      for (final pt in poly.skip(1)) {
        p.lineTo(pt.dx, pt.dy);
      }
      p.close();
      clearedPath = Path.combine(PathOperation.union, clearedPath, p);
    }

    final fogPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      clearedPath,
    );

    // 안개 기본 레이어 (반투명 회청색)
    canvas.drawPath(
      fogPath,
      Paint()..color = const Color(0xC0C8D4DF),
    );

    // 안개 경계 부드럽게 블러
    canvas.drawPath(
      fogPath,
      Paint()
        ..color = const Color(0x55A8BCC8)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );

    // 걷힌 경계 안쪽으로 안개 페이드 아웃
    for (final poly in polygons) {
      if (poly.length < 3) continue;
      final p = Path();
      p.moveTo(poly.first.dx, poly.first.dy);
      for (final pt in poly.skip(1)) {
        p.lineTo(pt.dx, pt.dy);
      }
      p.close();
      canvas.drawPath(
        p,
        Paint()
          ..color = const Color(0x35B8CAD8)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 35),
      );
    }

    // 사진 위치 햇살 글로우
    for (final center in centers) {
      canvas.drawCircle(
        center,
        90,
        Paint()
          ..color = const Color(0x22FFE8A0)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 45),
      );
    }
  }

  @override
  bool shouldRepaint(GradientFogPainter old) =>
      old.polygons != polygons || old.centers != centers;
}
