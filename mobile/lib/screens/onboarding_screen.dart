import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_config.dart';
import '../services/preferences_service.dart';
import 'login_screen.dart';
import 'web_page_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  // Screen 3 state
  bool _consentChecked = false;
  String _selectedCountryCode = 'KE';

  static const _supportedCountries = [
    {'name': 'Kenya',        'code': 'KE'},
    {'name': 'Rwanda',       'code': 'RW'},
    {'name': 'South Africa', 'code': 'ZA'},
    {'name': 'Ghana',        'code': 'GH'},
  ];

  static const _availableCountryCodes = {'KE', 'RW', 'ZA'};

  String get _selectedCountryName => _supportedCountries.firstWhere(
        (c) => c['code'] == _selectedCountryCode,
        orElse: () => _supportedCountries.first,
      )['name']!;

  static String get _privacyUrl => '${ApiConfig.baseUrl}/privacy';
  static String get _termsUrl => '${ApiConfig.baseUrl}/terms';
  static const _consentVersion = '1.0';

  @override
  void initState() {
    super.initState();
    _detectCountryFromIp();
  }

  Future<void> _detectCountryFromIp() async {
    try {
      final response = await http.get(Uri.parse('https://ipapi.co/json/'))
          .timeout(const Duration(seconds: 4));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final code = data['country_code'] as String?;
      final supported = _supportedCountries.any((c) => c['code'] == code);
      if (mounted && supported) {
        setState(() => _selectedCountryCode = code!);
      }
    } catch (_) {
      // Silent fail — default Kenya remains selected
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int page) {
    _pageController.jumpToPage(page);
    setState(() => _currentPage = page);
  }

  Future<void> _completeOnboarding() async {
    final prefs = PreferencesService.instance;
    await prefs.setUserCountry(_selectedCountryName);
    await prefs.setConsent(version: _consentVersion);
    await prefs.setOnboardingComplete(true);
    widget.onComplete();
  }

  void _openUrl(String url, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebPageScreen(url: url, title: title),
      ),
    );
  }

  // ── Screen 1: Welcome ──

  Widget _buildWelcomePage() {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),
          SvgPicture.asset(
            'assets/images/logomark-color.svg',
            width: 80,
            height: 80,
          ),
          const SizedBox(height: 32),
          Text(
            'Meet Your Chancen Companion',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Text(
            'I am here to help you navigate your finances, understand your '
            'Chancen ISA, and build smart money habits.\n\n'
            'Think of me as your personal finance buddy. I will answer your '
            'questions, help you budget like a pro, and support you on your '
            'journey to financial confidence.\n\n'
            'Everything here is for learning purposes; I am not a financial '
            'advisor, just a helpful guide.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _buildKeyPoint(Icons.question_answer_outlined, 'Get instant answers about your Chancen ISA'),
          const SizedBox(height: 12),
          _buildKeyPoint(Icons.account_balance_wallet_outlined, 'Learn budgeting that actually works'),
          const SizedBox(height: 12),
          _buildKeyPoint(Icons.trending_up, 'Build financial skills for life'),
          const Spacer(flex: 3),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => _goToPage(1),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text("Let's Get Started"),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildKeyPoint(IconData icon, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: colorScheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
      ],
    );
  }

  // ── Screen 2: Sign In / Sign Up ──

  Widget _buildSignInPage() {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        if (authProvider.isAuthenticated && _currentPage == 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _goToPage(2));
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: const LoginFormBody(branded: true, allowSignUp: true),
        );
      },
    );
  }

  // ── Screen 3: Country & Legal Consent ──

  Widget _buildConsentPage() {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),
          SvgPicture.asset(
            'assets/images/logomark-color.svg',
            width: 64,
            height: 64,
          ),
          const SizedBox(height: 32),
          Text(
            'Almost there!',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Country section
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Select your country',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          const SizedBox(height: 8),
          ..._supportedCountries.map((country) {
            final code = country['code']!;
            final name = country['name']!;
            final isAvailable = _availableCountryCodes.contains(code);
            final isSelected = _selectedCountryCode == code;
            return GestureDetector(
              onTap: isAvailable ? () => setState(() => _selectedCountryCode = code) : null,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: isSelected
                      ? colorScheme.primaryContainer.withValues(alpha: 0.3)
                      : colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? colorScheme.primary.withValues(alpha: 0.4)
                        : colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: isAvailable
                                  ? colorScheme.onSurface
                                  : colorScheme.onSurface.withValues(alpha: 0.35),
                            ),
                      ),
                    ),
                    if (!isAvailable)
                      Text(
                        'Coming soon',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurface.withValues(alpha: 0.35),
                            ),
                      ),
                    if (isSelected)
                      Icon(Icons.check_circle, size: 18, color: colorScheme.primary),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 24),

          // Legal section
          Text(
            'To continue, please review and accept our terms.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () => _openUrl(_privacyUrl, 'Privacy Policy'),
                child: const Text('Privacy Policy'),
              ),
              const SizedBox(width: 16),
              TextButton(
                onPressed: () => _openUrl(_termsUrl, 'Terms of Use'),
                child: const Text('Terms of Use'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Consent checkbox
          InkWell(
            onTap: () => setState(() => _consentChecked = !_consentChecked),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: _consentChecked,
                  onChanged: (v) => setState(() => _consentChecked = v ?? false),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'I have read and agree to the Privacy Policy and Terms of Use',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Spacer(flex: 3),

          // Continue button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _consentChecked ? _completeOnboarding : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Continue'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (i) => setState(() => _currentPage = i),
          children: [
            _buildWelcomePage(),
            _buildSignInPage(),
            _buildConsentPage(),
          ],
        ),
      ),
    );
  }
}
