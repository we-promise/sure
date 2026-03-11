import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/accounts_provider.dart';
import 'providers/transactions_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/backend_config_screen.dart';
import 'screens/login_screen.dart';
import 'screens/main_navigation_screen.dart';
import 'screens/access_denied_screen.dart';
import 'screens/sso_onboarding_screen.dart';
import 'services/api_config.dart';
import 'services/connectivity_service.dart';
import 'services/log_service.dart';

// warm white background used throughout the light theme
const Color _warmBackground = Color(0xFFFDFBF7);

// create color schemes once so they can be reused
final ColorScheme _lightScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xFF62A446),
  brightness: Brightness.light,
).copyWith(
  background: _warmBackground,
  surface: _warmBackground,
);

final ColorScheme _darkScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xFF62A446),
  brightness: Brightness.dark,
).copyWith(
  // choose dark-friendly background; for example a very dark grey
  background: const Color(0xFF121212),
  surface: const Color(0xFF121212),
);



void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiConfig.initialize();

  // Add initial log entry
  LogService.instance.info('App', 'Sure app starting...');

  runApp(const SureApp());
}

class SureApp extends StatelessWidget {
  const SureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LogService.instance),
        ChangeNotifierProvider(create: (_) => ConnectivityService()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProxyProvider<ConnectivityService, AccountsProvider>(
          create: (_) => AccountsProvider(),
          update: (_, connectivityService, accountsProvider) {
            if (accountsProvider == null) {
              final provider = AccountsProvider();
              provider.setConnectivityService(connectivityService);
              return provider;
            } else {
              accountsProvider.setConnectivityService(connectivityService);
              return accountsProvider;
            }
          },
        ),
        ChangeNotifierProxyProvider<ConnectivityService, TransactionsProvider>(
          create: (_) => TransactionsProvider(),
          update: (_, connectivityService, transactionsProvider) {
            if (transactionsProvider == null) {
              final provider = TransactionsProvider();
              provider.setConnectivityService(connectivityService);
              return provider;
            } else {
              transactionsProvider.setConnectivityService(connectivityService);
              return transactionsProvider;
            }
          },
        ),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
        title: 'Companion',
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          // Keep content above system UI (status bar, navigation bar, notches).
          // Protects all screens globally from being hidden behind system UI.
          return SafeArea(
            top: false,
            left: false,
            right: false,
            bottom: true,
            child: child ?? const SizedBox.shrink(),
          );
        },
        theme: ThemeData(
          fontFamily: 'Geist',
          fontFamilyFallback: const [
            'Inter',
            'Arial',
            'sans-serif',
          ],
          // start with a seed-based scheme for the green primary color
          colorScheme: _lightScheme,
          scaffoldBackgroundColor: _lightScheme.background,
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
          ),
          cardTheme: CardThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        darkTheme: ThemeData(
          fontFamily: 'Geist',
          fontFamilyFallback: const [
            'Inter',
            'Arial',
            'sans-serif',
          ],
          colorScheme: _darkScheme,
          scaffoldBackgroundColor: _darkScheme.background,
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
          ),
          cardTheme: CardThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        themeMode: themeProvider.themeMode,
        routes: {
          '/config': (context) => const BackendConfigScreen(),
          '/login': (context) => const LoginScreen(),
          '/home': (context) => const MainNavigationScreen(),
        },
        home: const AppWrapper(),
      )),
    );
  }
}

class AppWrapper extends StatefulWidget {
  const AppWrapper({super.key});

  @override
  State<AppWrapper> createState() => _AppWrapperState();
}

class _AppWrapperState extends State<AppWrapper> {
  bool _isCheckingConfig = true;
  bool _hasBackendUrl = false;
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _checkBackendConfig();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  void _initDeepLinks() {
    _appLinks = AppLinks();

    // Handle deep link that launched the app (cold start)
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _handleDeepLink(uri);
    }).catchError((e, stackTrace) {
      LogService.instance.error('DeepLinks', 'Initial link error: $e\n$stackTrace');
    });

    // Listen for deep links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen(
      (uri) => _handleDeepLink(uri),
      onError: (e, stackTrace) {
        LogService.instance.error('DeepLinks', 'Link stream error: $e\n$stackTrace');
      },
    );
  }

  void _handleDeepLink(Uri uri) {
    if (uri.scheme == 'sureapp' && uri.host == 'oauth') {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      authProvider.handleSsoCallback(uri);
    }
  }

  Future<void> _checkBackendConfig() async {
    final hasUrl = await ApiConfig.initialize();
    if (mounted) {
      setState(() {
        _hasBackendUrl = hasUrl;
        _isCheckingConfig = false;
      });
    }
  }

  void _onBackendConfigSaved() {
    setState(() {
      _hasBackendUrl = true;
    });
  }

  void _goToBackendConfig() {
    setState(() {
      _hasBackendUrl = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingConfig) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (!_hasBackendUrl) {
      return BackendConfigScreen(
        onConfigSaved: _onBackendConfigSaved,
      );
    }

    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        // Only show loading spinner during initial auth check
        if (authProvider.isInitializing) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (authProvider.isAuthenticated) {
          return const MainNavigationScreen();
        }

        if (authProvider.ssoAccessDenied) {
          return const AccessDeniedScreen();
        }

        if (authProvider.ssoOnboardingPending) {
          return const SsoOnboardingScreen();
        }

        return LoginScreen(
          onGoToSettings: _goToBackendConfig,
        );
      },
    );
  }
}
