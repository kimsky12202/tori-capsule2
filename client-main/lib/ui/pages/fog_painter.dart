import 'package:flutter/material.dart';

class HoleShape {
  final Offset center;
  final List<Offset>? polygon;
  HoleShape({required this.center, this.polygon});
}

class FogPainter extends CustomPainter {
  final List<Offset> holes;
  final double radius;

  FogPainter({required this.holes, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final fogPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    for (final hole in holes) {
      fogPath.addOval(Rect.fromCircle(center: hole, radius: radius));
    }
    fogPath.fillType = PathFillType.evenOdd;

    canvas.drawPath(
      fogPath,
      Paint()..color = const Color(0xCC1A1A2E),
    );
  }

  @override
  bool shouldRepaint(FogPainter old) =>
      old.holes != holes || old.radius != radius;
}

class NightOverlayPainter extends CustomPainter {
  final List<HoleShape> holes;
  final double circleRadius;

  NightOverlayPainter({required this.holes, required this.circleRadius});

  @override
  void paint(Canvas canvas, Size size) {
    final screenRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // 화면 경계로 clip → 꼭짓점이 화면 밖에 있어도 아티팩트 없음
    canvas.save();
    canvas.clipRect(screenRect);

    // 구멍 Path 빌드
    final holesPath = Path();
    for (final hole in holes) {
      if (hole.polygon == null || hole.polygon!.length < 3) continue;
      final poly = Path();
      poly.moveTo(hole.polygon!.first.dx, hole.polygon!.first.dy);
      for (final pt in hole.polygon!.skip(1)) {
        poly.lineTo(pt.dx, pt.dy);
      }
      poly.close();
      holesPath.addPath(poly, Offset.zero);
    }

    // 전체 overlay - 구멍
    final overlay = Path()..addRect(screenRect);
    final result = Path.combine(PathOperation.difference, overlay, holesPath);
    canvas.drawPath(result, Paint()..color = const Color(0xCC05101F));

    // 경계 글로우
    for (final hole in holes) {
      if (hole.polygon == null || hole.polygon!.length < 3) continue;
      final poly = Path();
      poly.moveTo(hole.polygon!.first.dx, hole.polygon!.first.dy);
      for (final pt in hole.polygon!.skip(1)) {
        poly.lineTo(pt.dx, pt.dy);
      }
      poly.close();
      canvas.drawPath(
        poly,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 20
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18)
          ..color = const Color(0x4005101F),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(NightOverlayPainter old) =>
      old.holes != holes || old.circleRadius != circleRadius;
}
