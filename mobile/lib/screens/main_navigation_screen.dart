import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../constants/ai_messages.dart';
import '../providers/auth_provider.dart';
import 'chat_list_screen.dart';
import 'dashboard_screen.dart';
import 'intro_screen.dart';
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
      _showAiDisabledMessage();
      return;
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

  Future<void> _handleSelectSettings(
    AuthProvider authProvider,
    bool introLayout,
  ) async {
    final settingsIndex = introLayout ? 2 : 3;
    await _handleDestinationSelected(settingsIndex, authProvider, introLayout);
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

    if (introLayout) {
      destinations.add(
        const NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          selectedIcon: Icon(Icons.auto_awesome),
          label: 'Intro',
        ),
      );
    }

    destinations.add(
      const NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline),
        selectedIcon: Icon(Icons.chat_bubble),
        label: 'Assistant',
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
        child: Padding(
          padding: const EdgeInsets.only(top: 12, left: 12),
          child: SvgPicture.asset(
            'assets/images/logomark.svg',
            width: 36,
            height: 36,
          ),
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

  void _showAiDisabledMessage() {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          aiDisabledAccountMessage,
        ),
      ),
    );
  }

  int _resolveCurrentIndex({
    required int screenCount,
    required bool aiEnabled,
  }) {
    if (screenCount == 0) {
      return 0;
    }

    var index = _currentIndex;

    if (index == 1 && !aiEnabled) {
      index = 0;
    }

    if (index < 0) {
      return 0;
    }

    if (index >= screenCount) {
      return screenCount - 1;
    }

    return index;
  }

  int _resolveBottomSelectedIndex({
    required int currentIndex,
    required int destinationCount,
  }) {
    if (destinationCount == 0) {
      return 0;
    }

    if (currentIndex < 0) {
      return 0;
    }

    if (currentIndex >= destinationCount) {
      return destinationCount - 1;
    }

    return currentIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final introLayout = authProvider.isIntroLayout;
        const chatIndex = 1;
        final screens = _buildScreens(
          introLayout,
          () => _handleDestinationSelected(chatIndex, authProvider, introLayout),
        );
        final destinations = _buildDestinations(introLayout);
        final currentIndex = _resolveCurrentIndex(
          screenCount: screens.length,
          aiEnabled: authProvider.aiEnabled,
        );
        final bottomNavIndex = _resolveBottomSelectedIndex(
          currentIndex: currentIndex,
          destinationCount: destinations.length,
        );

        return Scaffold(
          appBar: _buildTopBar(authProvider, introLayout),
          body: IndexedStack(
            index: currentIndex,
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
