import 'package:flutter/material.dart';

import 'ledger_controller.dart';
import 'ui/app_theme.dart';
import 'ui/connection_screen.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await LedgerController.create();
  runApp(LedgerApp(controller: controller));
}

class LedgerApp extends StatefulWidget {
  const LedgerApp({super.key, required this.controller});
  final LedgerController controller;
  @override
  State<LedgerApp> createState() => _LedgerAppState();
}

class _LedgerAppState extends State<LedgerApp> {
  static final _lightTheme = ledgerTheme(Brightness.light);
  static final _darkTheme = ledgerTheme(Brightness.dark);
  late bool _configured;
  late String _appearance;

  @override
  void initState() {
    super.initState();
    _configured = widget.controller.configured;
    _appearance = widget.controller.appearance;
    widget.controller.addListener(_onAppSettings);
  }

  void _onAppSettings() {
    final controller = widget.controller;
    // Sync events update the pages; rebuilding the entire app is unnecessary.
    if (_configured == controller.configured && _appearance == controller.appearance) return;
    setState(() {
      _configured = controller.configured;
      _appearance = controller.appearance;
    });
  }

  @override
  void didUpdateWidget(LedgerApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onAppSettings);
      widget.controller.addListener(_onAppSettings);
      _configured = widget.controller.configured;
      _appearance = widget.controller.appearance;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onAppSettings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '私有账本', debugShowCheckedModeBanner: false,
    theme: _lightTheme, darkTheme: _darkTheme,
    themeMode: switch (_appearance) {
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.light,
    },
    home: _configured
        ? HomeScreen(controller: widget.controller)
        : ConnectionScreen(controller: widget.controller, initialSetup: true),
  );
}
