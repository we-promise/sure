import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class AccessDeniedScreen extends StatelessWidget {
  const AccessDeniedScreen({super.key});

  Future<void> _launchContactUrl(BuildContext context) async {
    final uri = Uri.parse(
        'https://chat.whatsapp.com/Ca2yaFwpSOxIMQkuh0IcGM?mode=wwc');
    final launched =
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open link')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Green logo
                SvgPicture.asset(
                  'assets/images/logomark-color.svg',
                  width: 80,
                  height: 80,
                ),
                const SizedBox(height: 32),

                // Title
                Text(
                  'Not Invited',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),

                // Message
                Text(
                  'Looks like this account has not been invited to '
                  'Chancen Companion yet. Access is by invitation only.\n\n'
                  'Please make sure you are using the right email address. '
                  'If you think this is a mistake, get in touch with us.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // Contact us button
                OutlinedButton.icon(
                  onPressed: () => _launchContactUrl(context),
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Contact Us'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Back to sign in
                ElevatedButton(
                  onPressed: () {
                    authProvider.dismissAccessDenied();
                  },
                  child: const Text('Back to Sign In'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
