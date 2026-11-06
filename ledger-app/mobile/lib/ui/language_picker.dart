import 'package:flutter/material.dart';

import '../l10n/ledger_l10n.dart';
import '../ledger_controller.dart';

class LanguagePicker extends StatelessWidget {
  const LanguagePicker({super.key, required this.controller});

  final LedgerController controller;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    key: const ValueKey('ledger-language'),
    initialValue: controller.language,
    isExpanded: true,
    decoration: InputDecoration(labelText: isEnglish(context) ? 'Language' : '语言'),
    items: const [
      DropdownMenuItem(value: 'zh', child: Text('简体中文')),
      DropdownMenuItem(value: 'en', child: Text('English')),
    ],
    onChanged: (value) async {
      if (value == null) return;
      try {
        await controller.setLanguage(value);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isEnglish(context)
                ? 'Could not save the language. Try again.'
                : '语言设置未保存，请重试。'),
          ));
        }
      }
    },
  );
}
