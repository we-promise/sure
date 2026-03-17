import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../services/preferences_service.dart';

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

  static const _privacyUrl = 'https://chancen.com/privacy';
  static const _termsUrl = 'https://chancen.com/terms';
  static const _consentVersion = '1.0';

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
    await prefs.setUserCountry('Kenya');
    await prefs.setConsent(version: _consentVersion);
    await prefs.setOnboardingComplete(true);
    widget.onComplete();
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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

  // ── Screen 2: Google Sign-In ──

  Widget _buildSignInPage() {
    final colorScheme = Theme.of(context).colorScheme;

    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Auto-advance when auth completes
        if (authProvider.isAuthenticated && _currentPage == 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _goToPage(2);
          });
        }

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
                'Sign in to get started with your Companion',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Sign in to access your ISA info, financial tools, and personalised guidance.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                textAlign: TextAlign.center,
              ),
              const Spacer(flex: 2),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: authProvider.isLoading
                      ? null
                      : () => authProvider.startSsoLogin('google_oauth2'),
                  icon: SvgPicture.asset(
                    'assets/images/google_g_logo.svg',
                    width: 18,
                    height: 18,
                  ),
                  label: const Text('Sign in with Google'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              if (authProvider.isLoading) ...[
                const SizedBox(height: 20),
                const CircularProgressIndicator(),
              ],
              const Spacer(flex: 3),
            ],
          ),
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
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Country: Kenya',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
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
                onPressed: () => _openUrl(_privacyUrl),
                child: const Text('Privacy Policy'),
              ),
              const SizedBox(width: 16),
              TextButton(
                onPressed: () => _openUrl(_termsUrl),
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
