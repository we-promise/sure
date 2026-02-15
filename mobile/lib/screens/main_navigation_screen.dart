import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'dashboard_screen.dart';
import 'chat_list_screen.dart';
import 'more_screen.dart';
import 'settings_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final _dashboardKey = GlobalKey<DashboardScreenState>();

  List<Widget> _buildScreens(bool introLayout) {
    final screens = <Widget>[];

    if (!introLayout) {
      screens.add(DashboardScreen(key: _dashboardKey));
    }

    screens.add(const ChatListScreen());

    if (!introLayout) {
      screens.add(const MoreScreen());
    }

    screens.add(const SettingsScreen());

    return screens;
  }

  List<NavigationDestination> _buildDestinations(bool introLayout) {
    final destinations = <NavigationDestination>[];

    if (!introLayout) {
      destinations.add(
        const NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
      );
    }

    destinations.add(
      const NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline),
        selectedIcon: Icon(Icons.chat_bubble),
        label: 'AI Chat',
      ),
    );

    if (!introLayout) {
      destinations.add(
        const NavigationDestination(
          icon: Icon(Icons.more_horiz),
          selectedIcon: Icon(Icons.more_horiz),
          label: 'More',
        ),
      );
    }

    destinations.add(
      const NavigationDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: 'Settings',
      ),
    );

    return destinations;
  }

  Future<bool> _showEnableAiPrompt() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    final shouldEnable = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn on AI Chat?'),
        content: const Text('AI Chat is currently disabled in your account settings. Would you like to turn it on now?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn on AI'),
          ),
        ],
      ),
    );

    if (shouldEnable != true) {
      return false;
    }

    final enabled = await authProvider.enableAi();

    if (!enabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authProvider.errorMessage ?? 'Unable to enable AI right now.'),
          backgroundColor: Colors.red,
        ),
      );
    }

    return enabled;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final introLayout = authProvider.isIntroLayout;
        final screens = _buildScreens(introLayout);
        final destinations = _buildDestinations(introLayout);

        if (_currentIndex >= screens.length) {
          _currentIndex = 0;
        }

        final chatIndex = introLayout ? 0 : 1;
        final homeIndex = 0;

        return Scaffold(
          body: IndexedStack(
            index: _currentIndex,
            children: screens,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) async {
              if (index == chatIndex && !authProvider.aiEnabled) {
                final enabled = await _showEnableAiPrompt();
                if (!enabled) {
                  return;
                }
              }

              setState(() {
                _currentIndex = index;
              });

              if (!introLayout && index == homeIndex) {
                _dashboardKey.currentState?.reloadPreferences();
              }
            },
            destinations: destinations,
          ),
        );
      },
    );
  }
}
