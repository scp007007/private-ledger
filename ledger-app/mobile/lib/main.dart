import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/ledger_l10n.dart';
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
  late String _language;

  @override
  void initState() {
    super.initState();
    _configured = widget.controller.configured;
    _appearance = widget.controller.appearance;
    _language = widget.controller.language;
    widget.controller.addListener(_onAppSettings);
  }

  void _onAppSettings() {
    final controller = widget.controller;
    // Sync events update the pages; rebuilding the entire app is unnecessary.
    if (_configured == controller.configured &&
        _appearance == controller.appearance &&
        _language == controller.language) {
      return;
    }
    setState(() {
      _configured = controller.configured;
      _appearance = controller.appearance;
      _language = controller.language;
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
      _language = widget.controller.language;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onAppSettings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    onGenerateTitle: (context) => tr(context, '私有账本'),
    debugShowCheckedModeBanner: false,
    locale: Locale(_language),
    supportedLocales: LedgerLanguage.locales,
    localizationsDelegates: const [
      LedgerLanguage.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
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
