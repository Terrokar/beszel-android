import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class AppLanguage {
  final Locale locale;
  final String label;
  const AppLanguage(this.locale, this.label);
}

const supportedLanguages = <AppLanguage>[
  AppLanguage(Locale('en'), '🇺🇸 English'),
  AppLanguage(Locale('ru'), '🇷🇺 Русский'),
  AppLanguage(Locale('uz'), '🇺🇿 Oʻzbekcha'),
  AppLanguage(Locale('zh', 'CN'), '🇨🇳 简体中文'),
];

List<Locale> get supportedLocales =>
    supportedLanguages.map((l) => l.locale).toList();

class LanguageMenuButton extends StatelessWidget {
  const LanguageMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Locale>(
      icon: const Icon(Icons.language),
      tooltip: 'menu_language'.tr(),
      onSelected: (Locale locale) => context.setLocale(locale),
      itemBuilder: (BuildContext context) => [
        for (final lang in supportedLanguages)
          PopupMenuItem<Locale>(value: lang.locale, child: Text(lang.label)),
      ],
    );
  }
}

Future<void> showLanguageDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (BuildContext ctx) {
      return SimpleDialog(
        title: Text('select_language'.tr()),
        children: [
          for (final lang in supportedLanguages)
            SimpleDialogOption(
              onPressed: () {
                context.setLocale(lang.locale);
                Navigator.pop(ctx);
              },
              child: Text(lang.label),
            ),
        ],
      );
    },
  );
}
