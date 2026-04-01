import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/oauth_sign_in_service.dart';

class StartupWebsiteView extends StatefulWidget {
  const StartupWebsiteView({super.key});

  @override
  State<StartupWebsiteView> createState() => _StartupWebsiteViewState();
}

class _StartupWebsiteViewState extends State<StartupWebsiteView> {
  static const String _desktopAuthCallbackUri =
      'io.supabase.flutter://login-callback/';
  static const List<String> _landingAssetKeys = <String>[
    'web/website_8answers copy 2/index.html',
    'web/website_8answers%20copy%202/index.html',
  ];

  WebViewController? _controller;
  bool _isPageLoading = true;
  bool _isSigningIn = false;
  String? _loadError;
  Timer? _loadingWatchdog;
  HttpServer? _startupServer;
  String? _startupRootDir;
  Uri? _startupHomeUri;

  bool get _supportsEmbeddedStartupPage => Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  @override
  void dispose() {
    _loadingWatchdog?.cancel();
    _startupServer?.close(force: true);
    super.dispose();
  }

  void _startLoadingWatchdog() {
    _loadingWatchdog?.cancel();
    _loadingWatchdog = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      setState(() {
        _isPageLoading = false;
      });
    });
  }

  void _stopLoadingWatchdog() {
    _loadingWatchdog?.cancel();
    _loadingWatchdog = null;
  }

  bool _shouldInterceptForOAuth(Uri? uri) {
    if (uri == null) return false;
    final auth = (uri.queryParameters['auth'] ?? '').trim().toLowerCase();
    if (auth == 'google' || auth.startsWith('google:')) return true;
    final invite = (uri.queryParameters['invite'] ?? '').trim();
    final projectId = (uri.queryParameters['projectId'] ?? '').trim();
    return invite == '1' || projectId.isNotEmpty;
  }

  Future<void> _startGoogleSignIn() async {
    if (_isSigningIn) return;
    setState(() {
      _isSigningIn = true;
    });
    try {
      await OAuthSignInService.signInWithGoogle(
        supabase: Supabase.instance.client,
        redirectTo: _desktopAuthCallbackUri,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Google sign-in failed: $error'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSigningIn = false;
        });
      }
    }
  }

  Future<void> _initializeWebView() async {
    if (!_supportsEmbeddedStartupPage) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            _startLoadingWatchdog();
            setState(() {
              _isPageLoading = true;
              _loadError = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            _stopLoadingWatchdog();
            setState(() {
              _isPageLoading = false;
              _loadError = null;
            });
          },
          onWebResourceError: (error) {
            final isMainFrame = error.isForMainFrame ?? false;
            final resolvedError = '${error.errorCode}: ${error.description}';
            if (!isMainFrame) {
              return;
            }

            final failingUrl = (error.url ?? '').toLowerCase();
            if (failingUrl.endsWith('/favicon.ico') ||
                failingUrl.contains('/assets/assets/images/logo.svg')) {
              return;
            }
            if (!mounted) return;
            _stopLoadingWatchdog();
            setState(() {
              _loadError = resolvedError;
              _isPageLoading = false;
            });
          },
          onNavigationRequest: (request) {
            if (_shouldInterceptForOAuth(Uri.tryParse(request.url))) {
              _startGoogleSignIn();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    setState(() {
      _controller = controller;
      _isPageLoading = true;
      _loadError = null;
    });
    _startLoadingWatchdog();

    try {
      await _loadStartupLanding(controller);
    } catch (error) {
      if (!mounted) return;
      _stopLoadingWatchdog();
      final resolvedError = _describeLoadError(error);
      setState(() {
        _loadError = resolvedError;
        _isPageLoading = false;
      });
    }
  }

  Future<void> _loadStartupLanding(WebViewController controller) async {
    final List<String> attempts = <String>[];

    final localUri = await _startStartupServer();
    if (localUri != null) {
      try {
        await controller.loadRequest(localUri);
        return;
      } catch (error) {
        attempts.add('loadRequest("$localUri"): $error');
      }
    } else {
      attempts.add('startup server: unable to resolve startup root directory');
    }

    for (final key in _landingAssetKeys) {
      try {
        await controller.loadFlutterAsset(key);
        return;
      } catch (error) {
        attempts.add('loadFlutterAsset("$key"): $error');
      }
    }

    final executableFile = File(Platform.resolvedExecutable);
    final contentsDir = executableFile.parent.parent.path;
    final flutterAssetsDir =
        '$contentsDir/Frameworks/App.framework/Resources/flutter_assets';

    final htmlPath = _resolveLandingHtmlPath(flutterAssetsDir);
    if (htmlPath == null) {
      attempts.add(
        'loadFile(dynamic): no startup folder found under $flutterAssetsDir/web',
      );
    } else {
      try {
        await controller.loadFile(htmlPath);
        return;
      } catch (error) {
        attempts.add('loadFile("$htmlPath"): $error');
      }
    }

    throw StateError(
      'Unable to load startup landing HTML.\n${attempts.join('\n')}',
    );
  }

  String? _resolveLandingHtmlPath(String flutterAssetsDir) {
    final rootDir = _resolveLandingRootDir(flutterAssetsDir);
    if (rootDir == null) return null;
    final indexPath = '$rootDir/index.html';
    return File(indexPath).existsSync() ? indexPath : null;
  }

  String? _resolveLandingRootDir(String flutterAssetsDir) {
    final webDir = Directory('$flutterAssetsDir/web');
    if (!webDir.existsSync()) return null;

    final entries = webDir.listSync();
    final candidateDirs = entries.whereType<Directory>().where((dir) {
      final name = _basename(dir.path).toLowerCase();
      return name.startsWith('website_8answers');
    }).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final dir in candidateDirs) {
      final indexPath = '${dir.path}/index.html';
      if (File(indexPath).existsSync()) {
        return dir.path;
      }
    }
    return null;
  }

  Future<Uri?> _startStartupServer() async {
    if (_startupServer != null && _startupHomeUri != null) {
      return _startupHomeUri;
    }

    final executableFile = File(Platform.resolvedExecutable);
    final contentsDir = executableFile.parent.parent.path;
    final flutterAssetsDir =
        '$contentsDir/Frameworks/App.framework/Resources/flutter_assets';
    final rootDir = _resolveLandingRootDir(flutterAssetsDir);
    if (rootDir == null) return null;

    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      _startupServer = server;
      _startupRootDir = rootDir;
      _startupHomeUri = Uri.parse(
        'http://127.0.0.1:${server.port}/index.html',
      );
      server.listen(_handleStartupRequest);
      return _startupHomeUri;
    } catch (_) {
      _startupServer = null;
      _startupRootDir = null;
      _startupHomeUri = null;
      return null;
    }
  }

  Future<void> _handleStartupRequest(HttpRequest request) async {
    final rootDir = _startupRootDir;
    if (rootDir == null) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
      return;
    }

    String decodedPath = Uri.decodeComponent(request.uri.path);
    if (decodedPath.isEmpty || decodedPath == '/') {
      decodedPath = '/index.html';
    }
    if (decodedPath.contains('..')) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    String resolvedPath = '$rootDir$decodedPath';
    File file = File(resolvedPath);

    if (!file.existsSync()) {
      final lower = decodedPath.toLowerCase();
      if (lower == '/signin' || lower == '/signin/') {
        file = File('$rootDir/signin.html');
      } else if (lower == '/signup' || lower == '/signup/') {
        file = File('$rootDir/signup.html');
      } else if (lower == '/pricing' || lower == '/pricing/') {
        file = File('$rootDir/pricing.html');
      } else if (lower == '/terms' || lower == '/terms/') {
        file = File('$rootDir/terms.html');
      } else if (lower == '/privacy' || lower == '/privacy/') {
        file = File('$rootDir/privacy.html');
      } else if (!decodedPath.contains('.')) {
        file = File('$rootDir/index.html');
      }
    }

    if (!file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    request.response.headers.contentType = _contentTypeForPath(file.path);
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  ContentType _contentTypeForPath(String filePath) {
    final lowerPath = filePath.toLowerCase();
    if (lowerPath.endsWith('.html')) {
      return ContentType('text', 'html', charset: 'utf-8');
    }
    if (lowerPath.endsWith('.css')) {
      return ContentType('text', 'css', charset: 'utf-8');
    }
    if (lowerPath.endsWith('.js')) {
      return ContentType('application', 'javascript', charset: 'utf-8');
    }
    if (lowerPath.endsWith('.json')) {
      return ContentType('application', 'json', charset: 'utf-8');
    }
    if (lowerPath.endsWith('.svg')) {
      return ContentType('image', 'svg+xml');
    }
    if (lowerPath.endsWith('.png')) {
      return ContentType('image', 'png');
    }
    if (lowerPath.endsWith('.jpg') || lowerPath.endsWith('.jpeg')) {
      return ContentType('image', 'jpeg');
    }
    if (lowerPath.endsWith('.webp')) {
      return ContentType('image', 'webp');
    }
    return ContentType.binary;
  }

  String _basename(String path) {
    final separator = Platform.pathSeparator;
    final normalized =
        path.endsWith(separator) ? path.substring(0, path.length - 1) : path;
    final idx = normalized.lastIndexOf(separator);
    if (idx < 0) return normalized;
    return normalized.substring(idx + 1);
  }

  String _describeLoadError(Object error) {
    final raw = error.toString().trim();
    if (raw.isEmpty) return 'Unknown startup page load error.';
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    if (!_supportsEmbeddedStartupPage) {
      return const ColoredBox(
        color: Color(0xFFF7F9FC),
        child: Center(
          child: Text(
            'Startup page preview is supported on macOS desktop app.',
            style: TextStyle(fontSize: 16, color: Colors.black87),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return const ColoredBox(
        color: Color(0xFFF7F9FC),
        child: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0C8CE9)),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: controller),
        if (_isPageLoading || _isSigningIn)
          Container(
            color: Colors.white.withValues(alpha: 0.7),
            child: const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0C8CE9)),
              ),
            ),
          ),
        if (_loadError != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.shade600,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Startup page load failed: $_loadError',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}
