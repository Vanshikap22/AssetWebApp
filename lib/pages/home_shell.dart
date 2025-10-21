// lib/pages/home_shell.dart
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

import 'landing_page.dart';
import 'map_page.dart';
import 'tickets_page.dart';
import 'profile_page.dart';
import 'sign_detector.dart';

// Bulk upload service you created earlier
import '../services/bulk_upload_service.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

  final bool isDark;
  final VoidCallback onToggleTheme;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _index = 0;
  int _ticketsBadge = 2;

  // PAGE STACK ORDER: 0 Add, 1 Map, 2 Tickets, 3 Profile
  late final List<Widget> _pages = const [
    LandingPage(),
    MapPage(),
    TicketsPage(),
    ProfilePage(),
  ];

  String get _title => switch (_index) {
        0 => 'Add Asset',
        1 => 'Map',
        2 => 'Tickets',
        _ => 'Profile',
      };

  void _onTapNav(int barIndex) {
    const map = [3, 0, 1, 2]; // Profile, Add, Map, Tickets
    setState(() => _index = map[barIndex]);
  }

  // ---------- Bulk upload handler ----------
  Future<void> _onBulkUpload() async {
    final r = await BulkUploadService.pickAndUpload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(r.msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: r.ok ? null : Theme.of(context).colorScheme.error,
      ),
    );
  }
  // ----------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      key: _scaffoldKey,
      extendBody: true,
      appBar: AppBar(
        title: Text(_title),
        // Profile avatar on the LEFT to open the drawer
        leading: Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
            child: Tooltip(
              message: 'Open menu',
              child: CircleAvatar(
                radius: 18,
                backgroundColor: cs.primaryContainer,
                child: const Icon(Icons.person, size: 20),
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Bulk upload images',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: _onBulkUpload,
          ),
          const SizedBox(width: 4),
        ],
      ),

      // LEFT slide drawer
      drawer: _AppDrawer(
        isDark: widget.isDark,
        onToggleTheme: widget.onToggleTheme,
        onSelect: (route) async {
          Navigator.pop(context);
          switch (route) {
            case 'add':
              setState(() => _index = 0);
              break;
            case 'map':
              setState(() => _index = 1);
              break;
            case 'tickets':
              setState(() => _index = 2);
              break;
            case 'bulk': // NEW in drawer
              await _onBulkUpload();
              break;
            case 'profile':
              setState(() => _index = 3);
              break;
            case 'detect':
              final label = await Navigator.push<String>(
                context,
                MaterialPageRoute(builder: (_) => const SignDetectPage()),
              );
              if (!mounted) return;
              if (label != null && label.isNotEmpty) {
                // Show result; if want to push it into Add form, do it here.
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Detected: $label')),
                );
              }
              break;
            case 'settings':
              // TODO: push settings page if add one
              break;
          }
        },
      ),

      body: IndexedStack(index: _index, children: _pages),

      // Bottom nav (order: Profile, Add, Map, Tickets)
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: _GlassNavBar(
          selectedIndex: _selectedBarIndexFromPage(_index),
          onTap: _onTapNav,
          items: [
            _NavItemData(
              icon: Icons.person_outline,
              selectedIcon: Icons.person,
              label: 'Profile',
            ),
            _NavItemData(
              icon: Icons.add_box_outlined,
              selectedIcon: Icons.add_box,
              label: 'Add',
            ),
            _NavItemData(
              icon: Icons.map_outlined,
              selectedIcon: Icons.map,
              label: 'Map',
            ),
            _NavItemData(
              icon: Icons.confirmation_num_outlined,
              selectedIcon: Icons.confirmation_num,
              label: 'Tickets',
              badgeCount: _ticketsBadge,
            ),
          ],
        ),
      ),
    );
  }

  // Convert current page index back to the bottom bar index for proper highlighting
  int _selectedBarIndexFromPage(int pageIndex) {
    // inverse of [3,0,1,2] mapping → page 0(Add)=1, 1(Map)=2, 2(Tickets)=3, 3(Profile)=0
    switch (pageIndex) {
      case 0:
        return 1; // Add
      case 1:
        return 2; // Map
      case 2:
        return 3; // Tickets
      case 3:
      default:
        return 0; // Profile
    }
  }
}

// ---------------- Drawer ----------------

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.isDark,
    required this.onToggleTheme,
    required this.onSelect,
  });

  final bool isDark;
  final VoidCallback onToggleTheme;
  final void Function(String route) onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              currentAccountPicture: CircleAvatar(
                backgroundColor: cs.onPrimaryContainer.withOpacity(0.15),
                child: const Icon(Icons.person, size: 28),
              ),
              accountName: const Text('Norton'),
              accountEmail: const Text('nortona@rowan.edu'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [cs.primaryContainer, cs.surfaceVariant],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Profile'),
              onTap: () => onSelect('profile'),
            ),
            ListTile(
              leading: const Icon(Icons.add_box),
              title: const Text('Add Asset'),
              onTap: () => onSelect('add'),
            ),
            ListTile(
              leading: const Icon(Icons.map),
              title: const Text('Visualize Map'),
              onTap: () => onSelect('map'),
            ),
            ListTile(
              leading: const Icon(Icons.confirmation_num),
              title: const Text('Tickets'),
              onTap: () => onSelect('tickets'),
            ),

            // NEW: Bulk upload just below Tickets
            ListTile(
              leading: const Icon(Icons.file_upload_outlined),
              title: const Text('Bulk upload'),
              onTap: () => onSelect('bulk'),
            ),

            ListTile(
              leading: const Icon(Icons.traffic),
              title: const Text('Detect Signage'),
              onTap: () => onSelect('detect'),
            ),

            const Divider(),
            SwitchListTile(
              secondary: Icon(isDark ? Icons.wb_sunny : Icons.dark_mode),
              title: Text(isDark ? 'Day Mode' : 'Night Mode'),
              value: isDark,
              onChanged: (_) => onToggleTheme(),
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () => onSelect('settings'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Still working')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ------------- Pretty glass nav (compact) -------------

class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.items,
    required this.selectedIndex,
    required this.onTap,
  });

  final List<_NavItemData> items;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: cs.surface.withOpacity(0.65),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withOpacity(0.12),
                blurRadius: 24,
                spreadRadius: 2,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: List.generate(items.length, (i) {
              final item = items[i];
              final selected = i == selectedIndex;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => onTap(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: selected ? cs.primary.withOpacity(0.14) : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                selected ? item.selectedIcon : item.icon,
                                color: selected ? cs.primary : cs.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                              AnimatedOpacity(
                                duration: const Duration(milliseconds: 180),
                                opacity: selected ? 1 : 0,
                                child: Text(
                                  item.label,
                                  style: TextStyle(
                                    color: selected ? cs.primary : cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if ((item.badgeCount ?? 0) > 0)
                            Positioned(
                              right: 16,
                              top: 2,
                              child: _Badge(count: item.badgeCount!),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final display = count > 99 ? '99+' : count.toString();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.error,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.9), width: 1),
      ),
      child: Text(
        display,
        style: const TextStyle(
          fontSize: 10,
          height: 1.1,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _NavItemData {
  const _NavItemData({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount,
  });
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int? badgeCount;
}
