import 'dart:async';

import 'package:flutter/material.dart';

import '../ledger_controller.dart';
import 'import_page.dart';
import 'motion.dart';
import 'overview_page.dart';
import 'reports_page.dart';
import 'settings_page.dart';
import 'transactions_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final LedgerController controller;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  final _pageController = PageController();
  static const _labels = ['总览', '流水', '统计', '我的'];
  static const _icons = [Icons.space_dashboard_outlined, Icons.receipt_long_outlined,
    Icons.bar_chart_rounded, Icons.person_outline_rounded];
  static const _selectedIcons = [Icons.space_dashboard_rounded, Icons.receipt_long_rounded,
    Icons.bar_chart_rounded, Icons.person_rounded];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.scheduleAutoSync();
    });
  }

  void _select(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_pageController.hasClients) return;
    final duration = ledgerMotionDuration(context, milliseconds: 280);
    if (duration == Duration.zero) {
      _pageController.jumpToPage(index);
    } else {
      unawaited(_pageController.animateToPage(index, duration: duration, curve: Curves.easeOutCubic));
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _openImport() => Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (context) => Scaffold(
      appBar: AppBar(title: const Text('导入账单')),
      body: SafeArea(child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ImportPage(controller: widget.controller),
      ))),
    ),
  ));

  Widget _page(int index) => switch (index) {
    0 => OverviewPage(controller: widget.controller, onImport: _openImport,
      onTransactions: () => _select(1)),
    1 => TransactionsPage(controller: widget.controller),
    2 => ReportsPage(controller: widget.controller),
    _ => SettingsPage(controller: widget.controller),
  };

  Widget _navigationItem(int index) => _NavigationItem(
    key: ValueKey('nav-$index'), label: _labels[index],
    icon: _index == index ? _selectedIcons[index] : _icons[index],
    selected: _index == index, onTap: () => _select(index),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
      final controller = widget.controller;
      final theme = Theme.of(context);
      final wide = constraints.maxWidth >= 840;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
      final compactActions = constraints.maxWidth < 360 || largeText;
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => openNewTransaction(context, controller),
          icon: const Icon(Icons.add), label: const Text('记一笔'),
        ),
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(74),
          child: Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: AppBar(
              toolbarHeight: 74, titleSpacing: 20,
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(const ['私有账本', '账单流水', '消费统计', '我的账本'][_index],
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                if (!largeText) ...[
                  const SizedBox(height: 3),
                  Text(const ['记录生活里的每一笔', '让每笔收支都有迹可循', '看清消费，安排生活', '账本由自己掌握'][_index],
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
                ],
              ]),
              actions: [
                if (compactActions) IconButton.filledTonal(
                  tooltip: '导入账单', onPressed: _openImport,
                  icon: const Icon(Icons.file_upload_outlined, size: 20),
                ) else TextButton.icon(
                  style: TextButton.styleFrom(backgroundColor: theme.colorScheme.surface,
                    minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: _openImport,
                  icon: const Icon(Icons.file_upload_outlined, size: 17),
                  label: const Text('导入账单'),
                ),
                IconButton(
                  tooltip: controller.pendingCount > 0 ? '${controller.pendingCount} 项待同步，点击同步' : '立即同步',
                  onPressed: controller.syncing ? null : () => unawaited(controller.syncNow()),
                  icon: controller.syncing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Badge(isLabelVisible: controller.pendingCount > 0,
                          child: const Icon(Icons.sync_rounded, size: 21)),
                ),
                const SizedBox(width: 6),
              ],
            ),
          )),
        ),
        body: SafeArea(top: false, child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Row(children: [
            if (wide) SizedBox(width: 88, child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 4, 0),
              child: Column(children: [for (var i = 0; i < 4; i++)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: _navigationItem(i))]),
            )),
            Expanded(child: NotificationListener<ScrollStartNotification>(
              onNotification: (notification) {
                if (notification.depth == 0 && notification.dragDetails != null) {
                  FocusManager.instance.primaryFocus?.unfocus();
                }
                return false;
              },
              child: PageView.builder(
              key: const ValueKey('main-page-swipe'),
              controller: _pageController,
              physics: wide ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
              onPageChanged: (index) {
                setState(() => _index = index);
              },
              itemCount: 4,
              itemBuilder: (context, index) => _KeptPage(
                key: ValueKey('tab-$index'),
                child: TickerMode(enabled: index == _index,
                  child: ExcludeFocus(excluding: index != _index,
                    child: _page(index))),
              ),
            ))),
          ]),
        ))),
        bottomNavigationBar: wide ? null : DecoratedBox(
          decoration: BoxDecoration(color: theme.colorScheme.surface,
            border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant))),
          child: SafeArea(top: false, child: Align(heightFactor: 1, child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(children: [for (var i = 0; i < 4; i++)
                Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: _navigationItem(i))),
              ])),
          ))),
        ),
      );
    }),
  );
}

class _KeptPage extends StatefulWidget {
  const _KeptPage({super.key, required this.child});
  final Widget child;
  @override
  State<_KeptPage> createState() => _KeptPageState();
}

class _KeptPageState extends State<_KeptPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({super.key, required this.label, required this.icon,
    required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(button: true, selected: selected, label: label, excludeSemantics: true,
      child: Material(color: Colors.transparent, child: InkWell(
        borderRadius: BorderRadius.circular(16), onTap: onTap,
        child: AnimatedContainer(
          duration: ledgerMotionDuration(context, milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16),
            color: selected ? colors.primaryContainer : colors.surface.withValues(alpha: 0)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedScale(scale: selected ? 1.05 : 1,
              duration: ledgerMotionDuration(context, milliseconds: 220),
              child: Icon(icon, size: 21, color: selected ? colors.primary : colors.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(
              color: selected ? colors.primary : colors.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
          ]),
        ),
      )),
    );
  }
}
