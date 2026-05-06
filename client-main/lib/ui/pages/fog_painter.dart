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

    // ── 1. 안개 경로 계산 (전체 화면 - 걷힌 구역) ─────────
    Path fogPath = Path()..addRect(bounds);
    for (final poly in polygons) {
      if (poly.length < 3) continue;
      final p = Path();
      p.moveTo(poly.first.dx, poly.first.dy);
      for (final pt in poly.skip(1)) {
        p.lineTo(pt.dx, pt.dy);
      }
      p.close();
      fogPath = Path.combine(PathOperation.difference, fogPath, p);
    }

    // ── 2. 짙은 안개 기층 (불투명 베이스) ─────────────────
    canvas.drawPath(
      fogPath,
      Paint()..color = const Color(0xC4AABECE),
    );

    // ── 3. 블러된 안개 레이어 (경계가 서서히 흐려짐) ───────
    // 동일한 fogPath를 블러처리 → 안개 경계가 실제 안개처럼 번짐
    canvas.drawPath(
      fogPath,
      Paint()
        ..color = const Color(0x60A0B8CC)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // ── 4. 두 번째 넓은 블러 (더 멀리 퍼지는 안개 끝자락) ─
    canvas.drawPath(
      fogPath,
      Paint()
        ..color = const Color(0x30A0B8CC)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40),
    );

    // ── 5. 전체 대기 Haze ────────────────────────────────
    // 걷힌 곳도 살짝 뿌옇게 → 실제 안개처럼 완전히 맑지 않음
    canvas.drawRect(
      bounds,
      Paint()..color = const Color(0x14A0B8D0),
    );

    // ── 6. 안개 내부 밀도 변화 (불균일한 질감) ────────────
    // 화면 4구석에 큰 뭉게구름 느낌 추가
    for (final spot in [
      Offset(0, 0),
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
      Offset(size.width * 0.5, 0),
      Offset(0, size.height * 0.5),
      Offset(size.width, size.height * 0.5),
    ]) {
      canvas.drawCircle(
        spot,
        size.width * 0.45,
        Paint()
          ..color = const Color(0x18B0C8DC)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60),
      );
    }

    // ── 7. 사진 위치 아침 햇살 글로우 ──────────────────────
    for (final center in centers) {
      // 바깥 넓은 빛 퍼짐
      canvas.drawCircle(
        center,
        110,
        Paint()
          ..color = const Color(0x20FFA040)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60),
      );
      // 중간 빛
      canvas.drawCircle(
        center,
        55,
        Paint()
          ..color = const Color(0x28FFB850)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
      );
      // 중심 밝은 점
      canvas.drawCircle(
        center,
        20,
        Paint()
          ..color = const Color(0x35FFD080)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }
  }

  @override
  bool shouldRepaint(GradientFogPainter old) =>
      old.polygons != polygons || old.centers != centers;
}
