import 'package:flutter/material.dart';

/// The Cwhale whale mark used wherever the app needs its own visual identity.
class CwhaleBrandMark extends StatelessWidget {
  const CwhaleBrandMark({
    super.key,
    required this.size,
    required this.cornerRadius,
  });

  final double size;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(cornerRadius),
    child: SizedBox.square(
      dimension: size,
      child: size <= 40
          ? const CustomPaint(painter: _CompactWhaleMarkPainter())
          : ClipRect(
              child: Transform.scale(
                scale: 1.45,
                child: Image.asset(
                  'design/CWhale-icon-centered.png',
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
    ),
  );
}

/// A small vector treatment keeps the original whale recognizable at sidebar
/// sizes, where the thin strokes in the full-resolution PNG fall below a pixel.
class _CompactWhaleMarkPainter extends CustomPainter {
  const _CompactWhaleMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / 100;
    final scaleY = size.height / 100;
    canvas.save();
    canvas.scale(scaleX, scaleY);

    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 100, 100),
      Paint()..color = Colors.white,
    );

    final shader = const LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [Color(0xFF1769FF), Color(0xFF08BFD6)],
    ).createShader(const Rect.fromLTWH(10, 20, 80, 60));
    final outline = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final detail = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final whale = Path()
      ..moveTo(13, 48)
      ..cubicTo(25, 40, 38, 35, 53, 35)
      ..cubicTo(68, 35, 77, 29, 87, 27)
      ..cubicTo(81, 34, 77, 40, 73, 47)
      ..cubicTo(64, 60, 52, 64, 39, 61)
      ..cubicTo(28, 58, 20, 52, 13, 48)
      ..moveTo(13, 48)
      ..cubicTo(27, 46, 38, 48, 48, 51)
      ..cubicTo(60, 54, 70, 51, 81, 45);
    canvas.drawPath(whale, outline);

    final belly = Path()
      ..moveTo(22, 53)
      ..cubicTo(39, 60, 57, 60, 78, 49)
      ..moveTo(28, 58)
      ..cubicTo(45, 64, 60, 61, 74, 53);
    canvas.drawPath(belly, detail);

    final waves = Path()
      ..moveTo(15, 74)
      ..cubicTo(25, 79, 33, 78, 41, 74)
      ..cubicTo(50, 70, 57, 70, 66, 74)
      ..cubicTo(74, 78, 81, 78, 86, 75);
    canvas.drawPath(waves, detail);
    canvas.drawLine(const Offset(15, 82), const Offset(86, 82), detail);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CompactWhaleMarkPainter oldDelegate) => false;
}
