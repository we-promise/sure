import 'package:flutter/material.dart';

class IntroScreenPlatform extends StatelessWidget {
  const IntroScreenPlatform({super.key, this.onStartChat});

  final VoidCallback? onStartChat;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                children: <Widget>[
                  Text(
                    'Intro experience coming soon',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 12),
                  Text(
                    "We're building a richer onboarding journey to learn about your goals, milestones, and day-to-day needs. "
                    'For now, head over to the chat sidebar to start a conversation with Sure and let us know where you are in your financial journey.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
