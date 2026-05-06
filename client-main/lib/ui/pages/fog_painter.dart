import 'dart:math';
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

    // ── 1. 걷힌 구역 경로 계산 ─────────────────────────────
    Path clearedPath = Path();
    for (final poly in polygons) {
      if (poly.length < 3) continue;
      final p = Path();
      p.moveTo(poly.first.dx, poly.first.dy);
      for (final pt in poly.skip(1)) p.lineTo(pt.dx, pt.dy);
      p.close();
      clearedPath = Path.combine(PathOperation.union, clearedPath, p);
    }

    // 안개 경로 = 전체 - 걷힌 구역
    Path fogPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      clearedPath,
    );

    // ── 2. saveLayer로 구름 레이어 시작 ──────────────────────
    canvas.saveLayer(bounds, Paint());

    // ── 3. 구름 베이스 (흰색 불투명) ────────────────────────
    canvas.drawPath(
      fogPath,
      Paint()..color = const Color(0xDDFFFFFF),
    );

    // ── 4. 구름 뭉게 질감 - 격자형 원형 덩어리들 ──────────────
    // 화면을 격자로 나눠 각 셀에 구름 덩어리 배치
    final rng = _SeededRng(42);
    final cellW = size.width / 5;
    final cellH = size.height / 7;

    for (int row = 0; row < 7; row++) {
      for (int col = 0; col < 5; col++) {
        final cx = cellW * col + cellW * (0.3 + rng.next() * 0.4);
        final cy = cellH * row + cellH * (0.3 + rng.next() * 0.4);
        final r = cellW * (0.55 + rng.next() * 0.35);

        // 해당 점이 걷힌 영역에 있으면 스킵
        if (clearedPath.contains(Offset(cx, cy))) continue;

        // 큰 구름 덩어리
        canvas.drawCircle(
          Offset(cx, cy),
          r,
          Paint()
            ..color = const Color(0xCCFFFFFF)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.4),
        );

        // 위쪽 밝은 하이라이트
        canvas.drawCircle(
          Offset(cx - r * 0.15, cy - r * 0.2),
          r * 0.6,
          Paint()
            ..color = const Color(0x88FFFFFF)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.25),
        );
      }
    }

    // ── 5. 구름 그림자 (하단 약간 어두움) ────────────────────
    final shadowPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      clearedPath,
    );
    canvas.drawPath(
      shadowPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0x00D0D8E0),
            const Color(0x28B8C4CC),
          ],
        ).createShader(bounds),
    );

    // ── 6. 구름 경계 블러 (걷힌 경계 부드럽게) ─────────────
    canvas.drawPath(
      fogPath,
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );

    canvas.restore();

    // ── 7. 사진 위치 햇살 글로우 ──────────────────────────────
    for (final center in centers) {
      canvas.drawCircle(
        center,
        120,
        Paint()
          ..color = const Color(0x18FFE080)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 55),
      );
      canvas.drawCircle(
        center,
        50,
        Paint()
          ..color = const Color(0x22FFD060)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 25),
      );
    }
  }

  @override
  bool shouldRepaint(GradientFogPainter old) =>
      old.polygons != polygons || old.centers != centers;
}

// 결정론적 난수 (seed 고정 → 매번 같은 구름 위치)
class _SeededRng {
  int _state;
  _SeededRng(this._state);

  double next() {
    _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return (_state & 0xFFFF) / 0xFFFF;
  }
}
