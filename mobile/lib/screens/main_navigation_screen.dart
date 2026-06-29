import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/sure_dialog.dart';
import '../widgets/sure_logo.dart';
import 'chat_list_screen.dart';
import 'dashboard_screen.dart';
import 'intro_screen.dart';
import 'more_screen.dart';
import 'settings_screen.dart';
import '../l10n/app_localizations.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final _dashboardKey = GlobalKey<DashboardScreenState>();

  List<Widget> _buildScreens(bool introLayout, VoidCallback? onStartChat) {
    final screens = <Widget>[];

    if (!introLayout) {
      screens.add(DashboardScreen(key: _dashboardKey));
    }

    if (introLayout) {
      screens.add(IntroScreen(onStartChat: onStartChat));
    }

    screens.add(const ChatListScreen());

    if (!introLayout) {
      screens.add(const MoreScreen());
    }

    screens.add(const SettingsScreen());

    return screens;
  }

  Future<void> _handleDestinationSelected(
    int index,
    AuthProvider authProvider,
    bool introLayout,
  ) async {
    const chatIndex = 1;

    if (index == chatIndex && !authProvider.aiEnabled) {
      final enabled = await _showEnableAiPrompt();
      if (!enabled) {
        return;
      }
    }

    if (mounted) {
      setState(() {
        _currentIndex = index;
      });

      if (!introLayout && index == 0) {
        _dashboardKey.currentState?.reloadPreferences();
      }
    }
  }

  Future<void> _handleSelectSettings(AuthProvider authProvider, bool introLayout) async {
    final settingsIndex = introLayout ? 2 : 3;
    await _handleDestinationSelected(settingsIndex, authProvider, introLayout);
  }

  List<NavigationDestination> _buildDestinations(bool introLayout, AppLocalizations l) {
    final destinations = <NavigationDestination>[];

    if (!introLayout) {
      destinations.add(
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: l.navHome,
        ),
      );
    }

    if (introLayout) {
      destinations.add(
        NavigationDestination(
          icon: const Icon(Icons.auto_awesome_outlined),
          selectedIcon: const Icon(Icons.auto_awesome),
          label: l.navIntro,
        ),
      );
    }

    destinations.add(
      NavigationDestination(
        icon: const Icon(Icons.chat_bubble_outline),
        selectedIcon: const Icon(Icons.chat_bubble),
        label: l.navAssistant,
      ),
    );

    if (!introLayout) {
      destinations.add(
        NavigationDestination(
          icon: const Icon(Icons.more_horiz),
          selectedIcon: const Icon(Icons.more_horiz),
          label: l.navMore,
        ),
      );
    }

    return destinations;
  }

  PreferredSizeWidget _buildTopBar(AuthProvider authProvider, bool introLayout) {
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: 60,
      elevation: 0,
      titleSpacing: 0,
      centerTitle: false,
      actionsPadding: EdgeInsets.zero,
      title: Container(
        width: 60,
        height: 60,
        alignment: Alignment.topLeft,
        child: const Padding(
          padding: EdgeInsets.only(top: 12, left: 12),
          child: SureLogo(),
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Center(
            child: InkWell(
              onTap: () {
                _handleSelectSettings(authProvider, introLayout);
              },
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.settings_outlined),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<bool> _showEnableAiPrompt() async {
    final l = AppLocalizations.of(context);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    final shouldEnable = await SureDialog.confirm(
      context,
      title: l.navEnableAiChatTitle,
      message: l.navEnableAiChatContent,
      confirmLabel: l.navEnableAiChatConfirm,
      cancelLabel: l.navEnableAiChatNotNow,
    );

    if (shouldEnable != true) {
      return false;
    }

    final enabled = await authProvider.enableAi();

    if (!enabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authProvider.errorMessage ?? l.navEnableAiChatFailed),
          backgroundColor: Colors.red,
        ),
      );
    }

    return enabled;
  }

  int _resolveBottomSelectedIndex(List<NavigationDestination> destinations) {
    if (destinations.isEmpty) {
      return 0;
    }

    if (_currentIndex < 0) {
      return 0;
    }

    if (_currentIndex >= destinations.length) {
      return destinations.length - 1;
    }

    return _currentIndex;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final introLayout = authProvider.isIntroLayout;
        const chatIndex = 1;
        final screens = _buildScreens(
          introLayout,
          () => _handleDestinationSelected(chatIndex, authProvider, introLayout),
        );
        final destinations = _buildDestinations(introLayout, l);
        final bottomNavIndex = _resolveBottomSelectedIndex(destinations);

        if (_currentIndex >= screens.length) {
          _currentIndex = 0;
        }

        return Scaffold(
          appBar: _buildTopBar(authProvider, introLayout),
          body: IndexedStack(
            index: _currentIndex,
            children: screens,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: bottomNavIndex,
            onDestinationSelected: (index) {
              _handleDestinationSelected(index, authProvider, introLayout);
            },
            destinations: destinations,
          ),
        );
      },
    );
  }
}
