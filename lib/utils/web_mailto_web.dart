import 'dart:html' as html;

bool openMailTo(String email, {String? subject, String? body}) {
  final trimmed = email.trim();
  if (trimmed.isEmpty) return false;
  final queryParameters = <String, String>{};
  if (subject != null && subject.trim().isNotEmpty) {
    queryParameters['subject'] = subject.trim();
  }
  if (body != null && body.trim().isNotEmpty) {
    queryParameters['body'] = body.trim();
  }
  final mailtoUri = Uri(
    scheme: 'mailto',
    path: trimmed,
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  );
  html.window.open(mailtoUri.toString(), '_self');
  return true;
}
