import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

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

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with TickerProviderStateMixin {
  int _currentIndex = 0;
  int _previousIndex = 0;
  final _dashboardKey = GlobalKey<DashboardScreenState>();
  AnimationController? _slideController;
  Animation<Offset>? _slideAnimation;
  bool _isAnimating = false;

  @override
  void dispose() {
    _slideController?.dispose();
    super.dispose();
  }

  List<Widget> _buildScreens(bool introLayout, VoidCallback? onStartChat) {
    final screens = <Widget>[];

    if (!introLayout) {
      screens.add(DashboardScreen(key: _dashboardKey));
      screens.add(const ChatListScreen());
      screens.add(const MoreScreen());
    } else {
      screens.add(const ChatListScreen());
      screens.add(IntroScreen(onStartChat: onStartChat));
    }

    return screens;
  }

  Future<void> _handleDestinationSelected(
    int index,
    AuthProvider authProvider,
    bool introLayout,
  ) async {
    final chatIndex = introLayout ? 0 : 1;

    if (index == chatIndex && !authProvider.aiEnabled) {
      final enabled = await _showEnableAiPrompt();
      if (!enabled) {
        return;
      }
    }

    if (mounted && index != _currentIndex) {
      _animateToIndex(index);

      if (!introLayout && index == 0) {
        _dashboardKey.currentState?.reloadPreferences();
      }
    }
  }

  void _animateToIndex(int newIndex) {
    final goingForward = newIndex > _currentIndex;
    _previousIndex = _currentIndex;

    _slideController?.dispose();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _slideAnimation = Tween<Offset>(
      begin: Offset(goingForward ? 1.0 : -1.0, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController!,
      curve: Curves.easeOutCubic,
    ));

    setState(() {
      _isAnimating = true;
      _currentIndex = newIndex;
    });

    _slideController!.forward().then((_) {
      if (mounted) {
        setState(() {
          _isAnimating = false;
        });
      }
    });
  }

  void _handleSelectSettings() {
    showSettingsPanel(context);
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

    if (!introLayout) {
      destinations.add(
        const NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          selectedIcon: Icon(Icons.chat_bubble),
          label: 'Companion',
        ),
      );
    } else {
      destinations.add(
        const NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          selectedIcon: Icon(Icons.chat_bubble),
          label: 'Companion',
        ),
      );
      destinations.add(
        const NavigationDestination(
          icon: Icon(Icons.pie_chart_outline),
          selectedIcon: Icon(Icons.pie_chart),
          label: 'Insights',
        ),
      );
    }

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
            'assets/images/logomark-color.svg',
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
                _handleSelectSettings();
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

  Widget _buildBody(List<Widget> screens) {
    if (!_isAnimating || _slideAnimation == null) {
      // No animation — just show the current screen using IndexedStack
      // to preserve state of all screens.
      return IndexedStack(
        index: _currentIndex,
        children: screens,
      );
    }

    // During animation: show previous screen underneath, new screen sliding
    // on top — the "card shuffle" effect.
    return Stack(
      children: [
        // Previous screen stays in place as background
        IndexedStack(
          index: _previousIndex,
          children: screens,
        ),
        // New screen slides in on top
        SlideTransition(
          position: _slideAnimation!,
          child: IndexedStack(
            index: _currentIndex,
            children: screens,
          ),
        ),
      ],
    );
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
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        final introLayout = authProvider.isIntroLayout;
        final chatIndex = introLayout ? 0 : 1;
        final screens = _buildScreens(
          introLayout,
          () => _handleDestinationSelected(chatIndex, authProvider, introLayout),
        );
        final destinations = _buildDestinations(introLayout);
        final bottomNavIndex = _resolveBottomSelectedIndex(destinations);

        if (_currentIndex >= screens.length) {
          _currentIndex = 0;
        }

        return Scaffold(
          appBar: _buildTopBar(authProvider, introLayout),
          body: _buildBody(screens),
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
