import 'package:flutter/material.dart';
import 'intro_screen_stub.dart' if (dart.library.html) 'intro_screen_web.dart';

class IntroScreen extends StatelessWidget {
  const IntroScreen({super.key, this.onStartChat});

  final VoidCallback? onStartChat;

  @override
  Widget build(BuildContext context) {
    return IntroScreenPlatform(onStartChat: onStartChat);
  }
}
