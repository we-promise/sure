import 'package:flutter/material.dart';

/// Animated 3-dot "Thinking..." indicator shown while the AI generates a response.
/// Each dot bounces up in sequence, giving the classic chat typing indicator feel.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dotColor = colorScheme.onSurfaceVariant;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Thinking',
          style: TextStyle(
            color: colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          height: 20,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(3, (index) {
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  final offset = _dotOffset(index, _controller.value);
                  return Padding(
                    padding: EdgeInsets.only(right: index < 2 ? 5 : 0),
                    child: Transform.translate(
                      offset: Offset(0, offset),
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: dotColor.withValues(alpha: 0.75),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                },
              );
            }),
          ),
        ),
      ],
    );
  }

  /// Returns the vertical offset (px) for a dot at [index] given the
  /// controller's current [value] in [0, 1).
  /// Each dot is delayed by 1/3 of the cycle so they bounce in sequence.
  double _dotOffset(int index, double value) {
    const bounceHeight = 5.0;
    const dotCount = 3;
    final phase = (value - index / dotCount + 1.0) % 1.0;

    // Bounce occupies the first 40% of each dot's phase; rest is idle.
    if (phase < 0.2) {
      // Rising: 0 → peak
      return -bounceHeight * (phase / 0.2);
    } else if (phase < 0.4) {
      // Falling: peak → 0
      return -bounceHeight * (1.0 - (phase - 0.2) / 0.2);
    }
    return 0.0;
  }
}
