import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../data/api_client.dart';
import 'english_messages.dart';

class LedgerLanguage {
  const LedgerLanguage(this.code);

  final String code;

  static const delegate = _LedgerLanguageDelegate();
  static const locales = [Locale('zh'), Locale('en')];
}

class _LedgerLanguageDelegate extends LocalizationsDelegate<LedgerLanguage> {
  const _LedgerLanguageDelegate();

  @override
  bool isSupported(Locale locale) =>
      LedgerLanguage.locales.any((item) => item.languageCode == locale.languageCode);

  @override
  Future<LedgerLanguage> load(Locale locale) =>
      SynchronousFuture(LedgerLanguage(locale.languageCode));

  @override
  bool shouldReload(_LedgerLanguageDelegate old) => false;
}

bool isEnglish(BuildContext context) =>
    Localizations.of<LedgerLanguage>(context, LedgerLanguage)?.code == 'en';

final _placeholder = RegExp(r'\{(\d+)\}');

String _fill(String template, List<Object?> values) =>
    template.replaceAllMapped(_placeholder, (match) {
      final index = int.parse(match[1]!);
      return index < values.length ? '${values[index]}' : match[0]!;
    });

String tr(BuildContext context, String message, [List<Object?> values = const []]) {
  final template = isEnglish(context) ? englishMessages[message] ?? message : message;
  return values.isEmpty ? template : _fill(template, values);
}

// The network and storage layers keep stable errors for existing callers.
// Translate known messages at the UI boundary, including HTTP status codes.
final _statusMessages = [
  for (final entry in englishMessages.entries)
    if (entry.key.contains('（{0}）'))
      (
        RegExp('^${RegExp.escape(entry.key).replaceFirst(r'\{0\}', r'(\d+)')}\$'),
        entry.value,
      ),
];

String localizedProblem(BuildContext context, Object problem) {
  final message = switch (problem) {
    ApiException() => problem.message,
    FormatException() => problem.message,
    StateError() => problem.message.toString(),
    String() => problem,
    _ => '',
  };
  if (!isEnglish(context)) return message.isEmpty ? '操作未完成，请重试。' : message;
  final exact = englishMessages[message];
  if (exact != null) return exact;
  for (final (pattern, translation) in _statusMessages) {
    final match = pattern.firstMatch(message);
    if (match != null) return _fill(translation, [match[1]]);
  }
  return 'The operation could not be completed. Try again.';
}
