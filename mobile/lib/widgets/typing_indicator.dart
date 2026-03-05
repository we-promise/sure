import 'package:flutter/material.dart';

/// A typing indicator widget that shows "Thinking" text with animated dots
/// to indicate that the AI assistant is generating a response.
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
      duration: const Duration(milliseconds: 1400),
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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Thinking',
          style: TextStyle(
            color: colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(width: 8),
        ...List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final delay = index * 0.2;
              final progress = (_controller.value - delay) % 1.0;
              final opacity = _calculateOpacity(progress);

              return Padding(
                padding: EdgeInsets.only(
                  right: index < 2 ? 4 : 0,
                ),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color:
                        colorScheme.onSurfaceVariant.withValues(alpha: opacity),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            },
          );
        }),
      ],
    );
  }

  double _calculateOpacity(double progress) {
    if (progress < 0.5) {
      // Fade in
      return 0.3 + (progress * 2 * 0.7);
    } else {
      // Fade out
      return 1.0 - ((progress - 0.5) * 2 * 0.7);
    }
  }
}
