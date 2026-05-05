import 'package:flutter/material.dart';

class GradientFogPainter extends CustomPainter {
  final List<Offset> positions;
  final double clearRadius;

  const GradientFogPainter({
    required this.positions,
    this.clearRadius = 180,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Rect.fromLTWH(0, 0, size.width, size.height);

    canvas.saveLayer(bounds, Paint());

    // 짙은 안개 배경
    canvas.drawRect(
      bounds,
      Paint()..color = const Color(0xD8040D1A),
    );

    // 핀 위치마다 그라데이션으로 안개 걷어내기
    final clearPaint = Paint()..blendMode = BlendMode.dstOut;
    for (final pos in positions) {
      clearPaint.shader = RadialGradient(
        colors: [
          Colors.black,
          Colors.black.withValues(alpha: 0.85),
          Colors.black.withValues(alpha: 0.3),
          Colors.transparent,
        ],
        stops: const [0.0, 0.3, 0.65, 1.0],
      ).createShader(Rect.fromCircle(center: pos, radius: clearRadius));
      canvas.drawCircle(pos, clearRadius, clearPaint);
    }

    canvas.restore();

    // 빛 번짐 글로우
    for (final pos in positions) {
      canvas.drawCircle(
        pos,
        clearRadius * 0.45,
        Paint()
          ..color = const Color(0x20D4A855)
          ..maskFilter =
              MaskFilter.blur(BlurStyle.normal, clearRadius * 0.5),
      );
      // 중앙 밝은 점
      canvas.drawCircle(
        pos,
        clearRadius * 0.12,
        Paint()
          ..color = const Color(0x30FFD580)
          ..maskFilter =
              MaskFilter.blur(BlurStyle.normal, clearRadius * 0.15),
      );
    }
  }

  @override
  bool shouldRepaint(GradientFogPainter old) =>
      old.positions != positions || old.clearRadius != clearRadius;
}
