import 'dart:html' as html;
import 'dart:ui_web' as ui;
import 'package:flutter/material.dart';

class IntroScreenPlatform extends StatefulWidget {
  const IntroScreenPlatform({super.key, this.onStartChat});

  final VoidCallback? onStartChat;

  @override
  State<IntroScreenPlatform> createState() => _IntroScreenPlatformState();
}

class _IntroScreenPlatformState extends State<IntroScreenPlatform> {
  static int _nextViewId = 0;

  late final String _viewType;

  @override
  void initState() {
    super.initState();
    final currentId = _nextViewId;
    _nextViewId += 1;
    _viewType = 'intro-screen-web-$currentId';

    ui.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final frame = html.IFrameElement()
        ..srcdoc = _introHtmlContent
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.border = '0';

      return frame;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SizedBox.expand(
        child: HtmlElementView(viewType: _viewType),
      ),
    );
  }
}

const String _introHtmlContent = '''
<!doctype html>
<html>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <style>
      :root {
        color-scheme: light dark;
      }

      body {
        margin: 0;
        min-height: 100vh;
        font-family: Geist, Inter, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        color: #111827;
        background: transparent;
      }

      .grow {
        min-height: 100vh;
      }

      .overflow-y-auto {
        overflow-y: auto;
      }

      .px-3 {
        padding-left: 0.75rem;
        padding-right: 0.75rem;
      }

      .lg\:px-10 {
        padding-left: 2.5rem;
        padding-right: 2.5rem;
      }

      .pt-0 {
        padding-top: 0;
      }

      .pb-4 {
        padding-bottom: 1rem;
      }

      .w-full {
        width: 100%;
      }

      .mx-auto {
        margin-left: auto;
        margin-right: auto;
      }

      .max-w-5xl {
        max-width: 64rem;
      }

      .max-w-3xl {
        max-width: 48rem;
      }

      .space-y-2 > * + * {
        margin-top: 0.5rem;
      }

      .text-2xl {
        font-size: 1.5rem;
      }

      .text-xl {
        font-size: 1.25rem;
      }

      .text-center {
        text-align: center;
      }

      .font-semibold {
        font-weight: 600;
      }

      .text-secondary {
        color: #4b5563;
      }

      .text-primary {
        color: #111827;
      }

      .space-y-4 > * + * {
        margin-top: 1rem;
      }

      .bg-container {
        background: #ffffff;
        box-shadow: 0 1px 2px rgba(0,0,0,0.08), 0 1px 3px rgba(0,0,0,0.1);
      }

      .intro-card-shell {
        width: min(95%, 48rem);
        box-sizing: border-box;
        padding-left: 1rem;
        padding-right: 1rem;
      }

      .shadow-border-xs {
        border: 1px solid #e5e7eb;
      }

      .rounded-2xl {
        border-radius: 1rem;
      }

      .p-8 {
        padding: 2rem;
      }

      .flex {
        display: flex;
      }

      .justify-center {
        justify-content: center;
      }

      .inline-flex {
        display: inline-flex;
      }

      .items-center {
        align-items: center;
      }

      .gap-2 {
        gap: 0.5rem;
      }

      .px-4 {
        padding-left: 1rem;
        padding-right: 1rem;
      }

      .py-2 {
        padding-top: 0.5rem;
        padding-bottom: 0.5rem;
      }

      .rounded-lg {
        border-radius: 0.5rem;
      }

      .bg-primary {
        background: #2563eb;
      }

      .text-white {
        color: #fff;
      }

      .font-medium {
        font-weight: 500;
      }

      a {
        color: #fff;
        text-decoration: none;
      }

      .w-16 {
        width: 4rem;
      }

      .h-16 {
        height: 4rem;
      }

      .container {
        padding-top: 0;
      }
    </style>
  </head>
  <body>
    <main class="grow overflow-y-auto px-3 lg:px-10 pt-0 pb-4 w-full mx-auto max-w-5xl" data-app-layout-target="content">
      <div class="mx-auto max-w-3xl intro-card-shell">
        <div class="bg-container shadow-border-xs rounded-2xl p-8 text-center space-y-4">
          <h2 class="text-xl font-semibold text-primary">Intro experience coming soon</h2>
          <p class="text-secondary">
            We're building a richer onboarding journey to learn about your goals, milestones, and day-to-day needs. For now, head over to the chat sidebar to start a conversation with Sure and let us know where you are in your financial journey.
          </p>
        </div>
      </div>
    </main>
  </body>
</html>
''';
