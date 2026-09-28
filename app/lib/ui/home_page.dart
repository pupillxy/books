import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/mo_theme.dart';
import 'bookshelf_page.dart';
import 'drama_page.dart';
import 'settings_page.dart';
import 'store_page.dart';

/// 主框架：4 Tab（书架 / 书城 / 短剧 / 我的）
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _index = 0;

  static const _pages = [BookshelfPage(), StorePage(), DramaPage(), SettingsPage()];

  static const _icons = [
    Icons.auto_stories_outlined,
    Icons.travel_explore_outlined,
    Icons.smart_display_outlined,
    Icons.person_outline,
  ];
  static const _selectedIcons = [
    Icons.auto_stories,
    Icons.travel_explore,
    Icons.smart_display,
    Icons.person,
  ];
  static const _labels = ['书架', '书城', '短剧', '我的'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _index, children: _pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (var i = 0; i < _pages.length; i++)
            NavigationDestination(
              icon: Icon(_icons[i]),
              selectedIcon: Icon(_selectedIcons[i], color: MoStyle.primary),
              label: _labels[i],
            ),
        ],
      ),
    );
  }
}
