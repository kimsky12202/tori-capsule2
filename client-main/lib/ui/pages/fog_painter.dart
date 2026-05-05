import 'package:flutter/material.dart';

class GradientFogPainter extends CustomPainter {
  final List<Offset> positions;
  final double clearRadius;

  const GradientFogPainter({
    required this.positions,
    this.clearRadius = 190,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Rect.fromLTWH(0, 0, size.width, size.height);

    canvas.saveLayer(bounds, Paint());

    // 아침 안개 - 흰빛 도는 연한 파란색
    canvas.drawRect(
      bounds,
      Paint()..color = const Color(0xCFD6E8F0),
    );

    // 핀 위치마다 안개 걷힘 (그라데이션)
    final clearPaint = Paint()..blendMode = BlendMode.dstOut;
    for (final pos in positions) {
      clearPaint.shader = RadialGradient(
        colors: [
          Colors.white,
          Colors.white.withValues(alpha: 0.9),
          Colors.white.withValues(alpha: 0.35),
          Colors.transparent,
        ],
        stops: const [0.0, 0.25, 0.6, 1.0],
      ).createShader(Rect.fromCircle(center: pos, radius: clearRadius));
      canvas.drawCircle(pos, clearRadius, clearPaint);
    }

    canvas.restore();

    // 따뜻한 아침 햇살 글로우
    for (final pos in positions) {
      canvas.drawCircle(
        pos,
        clearRadius * 0.5,
        Paint()
          ..color = const Color(0x28FFC06A)
          ..maskFilter =
              MaskFilter.blur(BlurStyle.normal, clearRadius * 0.55),
      );
      // 중심 햇살 포인트
      canvas.drawCircle(
        pos,
        clearRadius * 0.13,
        Paint()
          ..color = const Color(0x35FFE0A0)
          ..maskFilter =
              MaskFilter.blur(BlurStyle.normal, clearRadius * 0.18),
      );
    }
  }

  @override
  bool shouldRepaint(GradientFogPainter old) =>
      old.positions != positions || old.clearRadius != clearRadius;
}
