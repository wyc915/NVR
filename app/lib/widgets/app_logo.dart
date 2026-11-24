import 'package:flutter/material.dart';

/// The app icon's glyph (house with a camera lens and a recording dot) without its orange
/// tile: white on dark backgrounds, black on light ones; the dot is always red.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: '監控',
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _LogoPainter(dark ? Colors.white : Colors.black),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.color);

  final Color color;
  static const _red = Color(0xFFE5484D);

  // Same geometry as the home-screen icon (120×120 box), cropped to the glyph.
  static const _origin = Offset(17, 15);
  static const _extent = 88.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _extent);
    canvas.translate(-_origin.dx, -_origin.dy);

    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(
      Path()
        ..moveTo(24, 58)
        ..lineTo(60, 28)
        ..lineTo(96, 58),
      line,
    );
    canvas.drawPath(
      Path()
        ..moveTo(33, 52)
        ..lineTo(33, 92)
        ..lineTo(87, 92)
        ..lineTo(87, 52),
      line..strokeCap = StrokeCap.butt,
    );
    // Lens: ring from r6 to r13.
    canvas.drawCircle(const Offset(60, 70), 9.5, line);
    // Recording dot: red center, outlined in the glyph color.
    canvas.drawCircle(const Offset(92, 28), 9, Paint()..color = _red);
    canvas.drawCircle(
      const Offset(92, 28),
      9,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.color != color;
}
