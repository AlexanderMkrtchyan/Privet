import 'dart:html' as html;

const _defaultTitle = 'Privet';

void setBrowserTabTitle(String? title) {
  html.document.title = title ?? _defaultTitle;
}

String get defaultBrowserTabTitle => _defaultTitle;
