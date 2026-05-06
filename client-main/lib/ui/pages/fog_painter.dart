import 'package:flutter/material.dart';

class GradientFogPainter extends CustomPainter {
  final List<List<Offset>> polygons;
  final List<Offset> centers;

  const GradientFogPainter({
    required this.polygons,
    required this.centers,
  });

  // 원 여러 개를 합쳐서 만든 뭉게구름 모양
  Path _makeCloud(double cx, double cy, double size) {
    final p = Path();
    // 중심 큰 원
    p.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: size * 0.50));
    // 왼쪽 봉우리
    p.addOval(Rect.fromCircle(center: Offset(cx - size * 0.38, cy + size * 0.08), radius: size * 0.36));
    // 오른쪽 봉우리
    p.addOval(Rect.fromCircle(center: Offset(cx + size * 0.38, cy + size * 0.08), radius: size * 0.33));
    // 왼쪽 위 작은 봉우리
    p.addOval(Rect.fromCircle(center: Offset(cx - size * 0.18, cy - size * 0.20), radius: size * 0.28));
    // 오른쪽 위 작은 봉우리
    p.addOval(Rect.fromCircle(center: Offset(cx + size * 0.22, cy - size * 0.14), radius: size * 0.26));
    // 하단 납작한 몸통 (구름 아랫면 채우기)
    p.addRect(Rect.fromLTWH(cx - size * 0.55, cy + size * 0.08, size * 1.1, size * 0.42));
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Rect.fromLTWH(0, 0, size.width, size.height);

    // ── 1. 걷힌 구역 계산 ──────────────────────────────────
    Path clearedPath = Path();
    for (final poly in polygons) {
      if (poly.length < 3) continue;
      final p = Path();
      p.moveTo(poly.first.dx, poly.first.dy);
      for (final pt in poly.skip(1)) { p.lineTo(pt.dx, pt.dy); }
      p.close();
      clearedPath = Path.combine(PathOperation.union, clearedPath, p);
    }

    final Path fogPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      clearedPath,
    );

    // ── 2. 구름 위치 생성 (seed 고정 → 항상 같은 위치) ────
    final rng = _SeededRng(17);
    final List<(double, double, double)> cloudSpots = [];

    // 화면을 격자로 나눠 구름 배치
    final cellW = size.width / 3;
    final cellH = size.height / 5;
    for (int row = 0; row < 5; row++) {
      for (int col = 0; col < 3; col++) {
        final cx = cellW * col + cellW * (0.25 + rng.next() * 0.5);
        final cy = cellH * row + cellH * (0.20 + rng.next() * 0.6);
        final cloudSize = cellW * (0.38 + rng.next() * 0.30);
        cloudSpots.add((cx, cy, cloudSize));
      }
    }
    // 빈 틈 채우는 추가 구름
    for (int i = 0; i < 6; i++) {
      final cx = size.width * (0.1 + rng.next() * 0.8);
      final cy = size.height * (0.1 + rng.next() * 0.8);
      final cloudSize = size.width * (0.12 + rng.next() * 0.15);
      cloudSpots.add((cx, cy, cloudSize));
    }

    // ── 3. 각 구름을 안개 영역에만 그리기 ─────────────────
    for (final (cx, cy, cloudSize) in cloudSpots) {
      final cloudShape = _makeCloud(cx, cy, cloudSize);

      // 구름을 안개 영역(fogPath)으로 클리핑
      final clipped = Path.combine(PathOperation.intersect, cloudShape, fogPath);

      // 구름 그림자 (아랫면 살짝 어둡게)
      canvas.drawPath(
        clipped,
        Paint()
          ..color = const Color(0x22B0B8C0)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, cloudSize * 0.25),
      );

      // 구름 본체 (흰색 반투명 - 지도가 비침)
      canvas.drawPath(
        clipped,
        Paint()..color = const Color(0xAAFFFFFF),
      );

      // 구름 위쪽 하이라이트 (밝은 빛 반사)
      final highlight = Path.combine(
        PathOperation.intersect,
        Path()..addOval(Rect.fromCircle(
          center: Offset(cx - cloudSize * 0.1, cy - cloudSize * 0.15),
          radius: cloudSize * 0.55,
        )),
        clipped,
      );
      canvas.drawPath(
        highlight,
        Paint()
          ..color = const Color(0x44FFFFFF)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, cloudSize * 0.2),
      );
    }

    // ── 4. 구름 경계 부드럽게 (안개-걷힌 경계 블러) ────────
    canvas.drawPath(
      fogPath,
      Paint()
        ..color = const Color(0x28FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
    );

    // ── 5. 사진 위치 햇살 글로우 ──────────────────────────
    for (final center in centers) {
      canvas.drawCircle(
        center,
        100,
        Paint()
          ..color = const Color(0x18FFE080)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 50),
      );
      canvas.drawCircle(
        center,
        45,
        Paint()
          ..color = const Color(0x22FFD060)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
      );
    }
  }

  @override
  bool shouldRepaint(GradientFogPainter old) =>
      old.polygons != polygons || old.centers != centers;
}

class _SeededRng {
  int _state;
  _SeededRng(this._state);

  double next() {
    _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return (_state & 0xFFFF) / 0xFFFF;
  }
}
