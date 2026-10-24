import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/sure_colors.dart';

/// One slice of a [CashFlowDonutChart].
class DonutSegment {
  const DonutSegment({required this.value, required this.color});

  /// Nonnegative magnitude; slices are drawn proportionally.
  final double value;
  final Color color;
}

/// Lightweight donut chart (a [CustomPainter], no charting dependency) used by
/// the cash flow screen, mirroring the web dashboard's outflows donut: one
/// slice per category with a small gap between slices and an arbitrary
/// [center] widget (typically the side total).
///
/// With [hidden] (privacy mode) only the empty track is drawn: the slice
/// proportions would give the masked amounts away.
class CashFlowDonutChart extends StatelessWidget {
  const CashFlowDonutChart({
    super.key,
    required this.segments,
    this.center,
    this.size = 200,
    this.strokeWidth = 18,
    this.semanticLabel,
    this.hidden = false,
  });

  final List<DonutSegment> segments;
  final Widget? center;
  final double size;
  final double strokeWidth;
  final String? semanticLabel;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    return Semantics(
      label: semanticLabel,
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _DonutPainter(
            segments: hidden ? const [] : segments,
            strokeWidth: strokeWidth,
            trackColor: palette.surfaceInset,
          ),
          child: center == null
              ? null
              : Center(
                  child: Padding(
                    padding: EdgeInsets.all(strokeWidth + 8),
                    child: center,
                  ),
                ),
        ),
      ),
    );
  }

  /// Parses a `#rrggbb` (or `#aarrggbb`) category color; returns [fallback]
  /// when [hex] is missing or malformed.
  static Color colorFromHex(String? hex, Color fallback) {
    if (hex == null) return fallback;
    var value = hex.trim().replaceFirst('#', '');
    if (value.length == 6) value = 'FF$value';
    if (value.length != 8) return fallback;
    final parsed = int.tryParse(value, radix: 16);
    return parsed == null ? fallback : Color(parsed);
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.segments,
    required this.strokeWidth,
    required this.trackColor,
  });

  final List<DonutSegment> segments;
  final double strokeWidth;
  final Color trackColor;

  // Gap between slices, in radians (~1.5°), like the web donut's padAngle.
  static const double _gap = 0.026;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (math.min(size.width, size.height) - strokeWidth) / 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    final total =
        segments.fold<double>(0, (sum, s) => sum + math.max(0, s.value));
    if (total <= 0) {
      canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = trackColor);
      return;
    }

    final visible = segments.where((s) => s.value > 0).toList();
    final gap = visible.length > 1 ? _gap : 0.0;
    var start = -math.pi / 2;
    for (final segment in visible) {
      final sweep = segment.value / total * math.pi * 2;
      final drawn = math.max(0.0, sweep - gap);
      if (drawn > 0) {
        canvas.drawArc(
            rect, start + gap / 2, drawn, false, paint..color = segment.color);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) {
    if (oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.segments.length != segments.length) {
      return true;
    }
    for (var i = 0; i < segments.length; i++) {
      if (oldDelegate.segments[i].value != segments[i].value ||
          oldDelegate.segments[i].color != segments[i].color) {
        return true;
      }
    }
    return false;
  }
}
