// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:flutter/material.dart';

class StartupWebsiteView extends StatefulWidget {
  final String initialPath;

  const StartupWebsiteView({
    super.key,
    this.initialPath = '/index.html',
  });

  @override
  State<StartupWebsiteView> createState() => _StartupWebsiteViewState();
}

class _StartupWebsiteViewState extends State<StartupWebsiteView> {
  static const String _landingPathEncoded = '/website_8answers%20copy%202/';
  static const String _landingPathDecoded = '/website_8answers copy 2/';
  bool _hasRedirected = false;

  ({String fileName, String querySuffix}) _resolveInitialTarget() {
    final raw = widget.initialPath.trim();
    final normalizedRaw = raw.isEmpty ? '/index.html' : raw;
    final parsed = Uri.tryParse(
          normalizedRaw.startsWith('/') ? normalizedRaw : '/$normalizedRaw',
        ) ??
        Uri(path: '/index.html');
    final normalizedPath = parsed.path.toLowerCase();
    final querySuffix = parsed.hasQuery ? '?${parsed.query}' : '';

    if (normalizedPath == '/signin' || normalizedPath == 'signin') {
      return (fileName: 'signin.html', querySuffix: querySuffix);
    }
    if (normalizedPath == '/signup' || normalizedPath == 'signup') {
      return (fileName: 'signup.html', querySuffix: querySuffix);
    }
    if (normalizedPath == '/pricing' || normalizedPath == 'pricing') {
      return (fileName: 'pricing.html', querySuffix: querySuffix);
    }
    if (normalizedPath == '/terms' || normalizedPath == 'terms') {
      return (fileName: 'terms.html', querySuffix: querySuffix);
    }
    if (normalizedPath == '/privacy' || normalizedPath == 'privacy') {
      return (fileName: 'privacy.html', querySuffix: querySuffix);
    }
    if (normalizedPath.endsWith('.html')) {
      final fileName = normalizedPath.startsWith('/')
          ? normalizedPath.substring(1)
          : normalizedPath;
      return (fileName: fileName, querySuffix: querySuffix);
    }
    return (fileName: 'index.html', querySuffix: querySuffix);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _redirectIfNeeded();
  }

  void _redirectIfNeeded() {
    if (_hasRedirected) return;
    _hasRedirected = true;

    final baseUri = Uri.base;
    final queryParams = baseUri.queryParameters;
    final hashValue = html.window.location.hash;
    final hashQuery = hashValue.startsWith('#') ? hashValue.substring(1) : '';
    final hashParams = Uri.splitQueryString(
      hashQuery.contains('=') ? hashQuery : '',
    );
    final hasAuthFlowParams = queryParams.containsKey('code') ||
        queryParams.containsKey('state') ||
        queryParams.containsKey('access_token') ||
        queryParams.containsKey('refresh_token') ||
        queryParams.containsKey('id_token') ||
        queryParams.containsKey('auth') ||
        queryParams.containsKey('invite') ||
        queryParams.containsKey('projectId') ||
        queryParams.containsKey('inv') ||
        queryParams.containsKey('inviteToken') ||
        hashParams.containsKey('access_token') ||
        hashParams.containsKey('refresh_token') ||
        hashParams.containsKey('id_token');
    if (hasAuthFlowParams) {
      return;
    }

    final currentPath = html.window.location.pathname ?? '';
    final initialTarget = _resolveInitialTarget();
    final initialFileName = initialTarget.fileName;
    final initialQuerySuffix = initialTarget.querySuffix;
    if (currentPath.contains(_landingPathEncoded) ||
        currentPath.contains(_landingPathDecoded)) {
      final lowerCurrentPath = currentPath.toLowerCase();
      if (lowerCurrentPath.endsWith('/$initialFileName')) {
        return;
      }
    }

    var appBasePath = currentPath;
    if (appBasePath.endsWith('/index.html')) {
      appBasePath =
          appBasePath.substring(0, appBasePath.length - '/index.html'.length);
    } else if (!appBasePath.endsWith('/')) {
      final lastSlash = appBasePath.lastIndexOf('/');
      appBasePath =
          lastSlash >= 0 ? appBasePath.substring(0, lastSlash + 1) : '/';
    }
    if (!appBasePath.startsWith('/')) {
      appBasePath = '/$appBasePath';
    }
    if (!appBasePath.endsWith('/')) {
      appBasePath = '$appBasePath/';
    }

    final startupUrl =
        '${appBasePath}website_8answers%20copy%202/$initialFileName$initialQuerySuffix'
        '${initialQuerySuffix.isEmpty ? '?' : '&'}v=20260401';
    html.window.location.replace(startupUrl);
  }

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.white,
      child: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0C8CE9)),
        ),
      ),
    );
  }
}
