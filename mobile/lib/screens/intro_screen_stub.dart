import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class IntroScreenPlatform extends StatefulWidget {
  const IntroScreenPlatform({super.key, this.onStartChat});

  final VoidCallback? onStartChat;

  @override
  State<IntroScreenPlatform> createState() => _IntroScreenPlatformState();
}

class _IntroScreenPlatformState extends State<IntroScreenPlatform>
    with AutomaticKeepAliveClientMixin {
  late final WebViewController _controller;
  bool? _lastIsDark;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.transparent);
  }

  void _reloadIfThemeChanged(bool isDark) {
    if (isDark != _lastIsDark) {
      _lastIsDark = isDark;
      _controller.loadHtmlString(_buildHtml(isDark));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    _reloadIfThemeChanged(isDark);
    return WebViewWidget(controller: _controller);
  }
}

String _buildHtml(bool isDark) {
  final bg = isDark ? '#1a1a1a' : '#ffffff';
  final textPrimary = isDark ? '#f5f5f5' : '#111827';
  final textSecondary = isDark ? '#a3a3a3' : '#4b5563';
  final cardBg = isDark ? '#262626' : '#ffffff';
  final cardBorder = isDark ? '#404040' : '#e5e7eb';
  final badgeBg = isDark ? '#333333' : '#f3f4f6';
  const colorSuccess = '#10A861';

  const prompts = [
    {
      'title': '\u26A0\uFE0F UPDATE \u26A0\uFE0F',
      'desc':
          'Your side hustle income could cover groceries and several other expenses, reducing the need for a loan. Consider redirecting your side hustle earnings to priority expenses like groceries before borrowing. Family support is your largest expense category. However, you can trim eating out and reduce uncategorised spending to minimise future loan dependence. By maximising your side hustle and cutting back on non-essential expenses, you could avoid loans altogether and build a stronger financial foundation.',
    },
    {
      'title': '\uD83D\uDD0D Show spending insights',
      'desc': 'We update this data weekly with fresh insights.',
    },
    {
      'title': '\uD83D\uDCA1 Your Turn Soon',
      'desc':
          'You will soon be able to get personalized insights just like this!',
    },
    {
      'title': '\uD83D\uDCF3 M-PESA Integration',
      'desc':
          'We are working on integrating M-PESA to make it easier to add income and expenses.',
    },
  ];

  final promptCards = StringBuffer();
  for (final p in prompts) {
    promptCards.write('''
    <div style="background:$cardBg;border:1px solid $cardBorder;border-radius:16px;padding:16px;margin-bottom:12px;">
      <p style="font-weight:600;color:$textPrimary;margin:0 0 4px 0;font-size:14px;">${p['title']}</p>
      <p style="color:$textSecondary;margin:0;font-size:13px;line-height:1.5;">${p['desc']}</p>
    </div>
    ''');
  }

  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">
  <style>
    * { margin:0; padding:0; box-sizing:border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: $bg;
      color: $textPrimary;
      padding: 16px;
      -webkit-text-size-adjust: 100%;
    }
    .container { max-width: 560px; margin: 0 auto; }
    .header-card {
      background: $cardBg;
      border: 1px solid $cardBorder;
      border-radius: 16px;
      padding: 24px;
      margin-bottom: 24px;
    }
    .header-top {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 12px;
      margin-bottom: 8px;
    }
    .badge {
      flex-shrink: 0;
      background: $badgeBg;
      border: 1px solid $cardBorder;
      border-radius: 999px;
      padding: 4px 10px;
      font-size: 11px;
      white-space: nowrap;
      color: $textPrimary;
    }
    h1 { font-size: 20px; font-weight: 600; margin: 0; }
    .subtitle { color: $textSecondary; font-size: 14px; }
    .chart-container {
      width: 100%;
      margin-bottom: 24px;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
    }
    .chart-container svg {
      display: block;
      width: 100%;
      height: auto;
    }
    .text-xs { font-size: 11px; }
    .font-medium { font-weight: 500; }
    .font-mono { font-family: ui-monospace, SFMono-Regular, monospace; }
    .text-primary { fill: $textPrimary; }
    .text-secondary { fill: $textSecondary; }
    .fill-current { fill: currentColor; }
    .select-none { user-select: none; -webkit-user-select: none; }
  </style>
</head>
<body>
  <div class="container">
    <div class="header-card">
      <div class="header-top">
        <h1>Budget Analyser Preview</h1>
        <div class="badge">Coming Soon!</div>
      </div>
      <p class="subtitle">See how average students in Nairobi spend their money.</p>
    </div>

    <div class="chart-container">
      <svg viewBox="0 0 388 384" xmlns="http://www.w3.org/2000/svg">
        <defs>
          <linearGradient id="lg-1-0" gradientUnits="userSpaceOnUse" x1="31" x2="186.5">
            <stop offset="0%" stop-color="rgba(97,114,243,0.1)"/>
            <stop offset="100%" stop-color="rgba(16,168,97,0.1)"/>
          </linearGradient>
          <linearGradient id="lg-2-0" gradientUnits="userSpaceOnUse" x1="31" x2="186.5">
            <stop offset="0%" stop-color="rgba(106,210,138,0.1)"/>
            <stop offset="100%" stop-color="rgba(16,168,97,0.1)"/>
          </linearGradient>
          <linearGradient id="lg-0-3" gradientUnits="userSpaceOnUse" x1="201.5" x2="357">
            <stop offset="0%" stop-color="rgba(16,168,97,0.1)"/>
            <stop offset="100%" stop-color="rgba(97,114,243,0.1)"/>
          </linearGradient>
          <linearGradient id="lg-0-10" gradientUnits="userSpaceOnUse" x1="201.5" x2="357">
            <stop offset="0%" stop-color="rgba(16,168,97,0.1)"/>
            <stop offset="100%" stop-color="rgba(115,115,115,0.1)"/>
          </linearGradient>
          <linearGradient id="lg-0-11" gradientUnits="userSpaceOnUse" x1="201.5" x2="357">
            <stop offset="0%" stop-color="rgba(16,168,97,0.1)"/>
            <stop offset="100%" stop-color="rgba(16,168,97,0.1)"/>
          </linearGradient>
        </defs>

        <!-- Links: income → Cash Flow -->
        <g fill="none">
          <path d="M31,176.57C108.75,176.57,108.75,192.17,186.5,192.17" stroke="url(#lg-1-0)" stroke-width="41.14"/>
          <path d="M31,292.57C108.75,292.57,108.75,288.17,186.5,288.17" stroke="url(#lg-2-0)" stroke-width="150.86"/>
          <!-- Cash Flow → expenses -->
          <path d="M201.5,181.2C279.25,181.2,279.25,25.6,357,25.6" stroke="url(#lg-0-3)" stroke-width="19.2"/>
          <path d="M201.5,198.42C279.25,198.42,279.25,62.83,357,62.83" stroke="url(#lg-0-3)" stroke-width="15.25"/>
          <path d="M201.5,210.85C279.25,210.85,279.25,95.25,357,95.25" stroke="url(#lg-0-3)" stroke-width="9.6"/>
          <path d="M201.5,218.39C279.25,218.39,279.25,122.79,357,122.79" stroke="url(#lg-0-3)" stroke-width="5.49"/>
          <path d="M201.5,232.1C279.25,232.1,279.25,156.51,357,156.51" stroke="url(#lg-0-3)" stroke-width="21.94"/>
          <path d="M201.5,247.87C279.25,247.87,279.25,192.28,357,192.28" stroke="url(#lg-0-3)" stroke-width="9.6"/>
          <path d="M201.5,267.76C279.25,267.76,279.25,232.16,357,232.16" stroke="url(#lg-0-3)" stroke-width="30.17"/>
          <path d="M201.5,302.82C279.25,302.82,279.25,287.23,357,287.23" stroke="url(#lg-0-10)" stroke-width="39.95"/>
          <path d="M201.5,343.2C279.25,343.2,279.25,347.6,357,347.6" stroke="url(#lg-0-11)" stroke-width="40.8"/>
        </g>

        <!-- Cash Flow node (center) -->
        <g>
          <rect x="186.5" y="171.6" width="15" height="192" fill="$colorSuccess" rx="0"/>
          <text x="207.5" y="264" dy="-0.2em" text-anchor="start" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Cash Flow</tspan>
            <tspan x="207.5" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh7,000.00</tspan>
          </text>
        </g>

        <!-- Loan node (left) -->
        <g>
          <path d="M24,156 L31,156 L31,197.14 L24,197.14 Q16,197.14 16,189.14 L16,164 Q16,156 24,156Z" fill="#6172F3"/>
          <text x="37" y="176.57" dy="-0.2em" text-anchor="start" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Loan</tspan>
            <tspan x="37" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh1,500.00</tspan>
          </text>
        </g>

        <!-- Side Hustle node (left) -->
        <g>
          <path d="M24,217.14 L31,217.14 L31,368 L24,368 Q16,368 16,360 L16,225.14 Q16,217.14 24,217.14Z" fill="#6ad28a"/>
          <text x="37" y="292.57" dy="-0.2em" text-anchor="start" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Side Hustle</tspan>
            <tspan x="37" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh5,500.00</tspan>
          </text>
        </g>

        <!-- Groceries (right) -->
        <g>
          <path d="M357,16 L364,16 Q372,16 372,24 L372,27.2 Q372,35.2 364,35.2 L357,35.2Z" fill="#6172F3"/>
          <text x="351" y="25.6" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Groceries</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh700.00</tspan>
          </text>
        </g>

        <!-- Matatu & Boda (right) -->
        <g>
          <path d="M357,55.2 L364.37,55.2 Q372,55.2 372,62.83 L372,62.83 Q372,70.45 364.37,70.45 L357,70.45Z" fill="#6172F3"/>
          <text x="351" y="62.83" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Matatu &amp; Boda</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh556.00</tspan>
          </text>
        </g>

        <!-- Airtime (right) -->
        <g>
          <path d="M357,90.45 L367.2,90.45 Q372,90.45 372,95.25 L372,95.25 Q372,100.05 367.2,100.05 L357,100.05Z" fill="#6172F3"/>
          <text x="351" y="95.25" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Airtime</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh350.00</tspan>
          </text>
        </g>

        <!-- Clothing (right) -->
        <g>
          <path d="M357,120.05 L369.26,120.05 Q372,120.05 372,122.79 L372,122.79 Q372,125.54 369.26,125.54 L357,125.54Z" fill="#6172F3"/>
          <text x="351" y="122.79" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Clothing</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh200.00</tspan>
          </text>
        </g>

        <!-- Transport (right) -->
        <g>
          <path d="M357,145.54 L364,145.54 Q372,145.54 372,153.54 L372,159.48 Q372,167.48 364,167.48 L357,167.48Z" fill="#6172F3"/>
          <text x="351" y="156.51" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Transport</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh800.00</tspan>
          </text>
        </g>

        <!-- Eating Out (right) -->
        <g>
          <path d="M357,187.48 L367.2,187.48 Q372,187.48 372,192.28 L372,192.28 Q372,197.08 367.2,197.08 L357,197.08Z" fill="#6172F3"/>
          <text x="351" y="192.28" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Eating Out</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh350.00</tspan>
          </text>
        </g>

        <!-- Family Support (right) -->
        <g>
          <path d="M357,217.08 L364,217.08 Q372,217.08 372,225.08 L372,239.25 Q372,247.25 364,247.25 L357,247.25Z" fill="#6172F3"/>
          <text x="351" y="232.16" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Family Support</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh1,100.00</tspan>
          </text>
        </g>

        <!-- Uncategorized (right) -->
        <g>
          <path d="M357,267.25 L364,267.25 Q372,267.25 372,275.25 L372,299.2 Q372,307.2 364,307.2 L357,307.2Z" fill="#737373"/>
          <text x="351" y="287.23" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Uncategorized</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh1,456.50</tspan>
          </text>
        </g>

        <!-- Surplus (right) -->
        <g>
          <path d="M357,327.2 L364,327.2 Q372,327.2 372,335.2 L372,360 Q372,368 364,368 L357,368Z" fill="$colorSuccess"/>
          <text x="351" y="347.6" dy="-0.2em" text-anchor="end" style="font-size:11px;font-weight:500;fill:$textPrimary;cursor:default;">
            <tspan>Surplus</tspan>
            <tspan x="351" dy="1.2em" style="font-size:9px;fill:$textSecondary;font-family:monospace;">KSh1,487.50</tspan>
          </text>
        </g>
      </svg>
    </div>

    $promptCards
  </div>
</body>
</html>
''';
}
