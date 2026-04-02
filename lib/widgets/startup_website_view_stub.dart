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

  WebViewController? _controller;
  bool _isPageLoading = true;
  bool _isSigningIn = false;
  String? _loadError;
  Timer? _loadingWatchdog;
  HttpServer? _startupServer;
  String? _startupRootDir;
  Uri? _startupHomeUri;
  bool _didFallbackToLocalFile = false;
  bool _isRecoveringFromLoadError = false;

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
            final failingUrl = (error.url ?? '').trim();
            final resolvedError = failingUrl.isEmpty
                ? '${error.errorCode}: ${error.description}'
                : '${error.errorCode}: ${error.description} ($failingUrl)';
            if (!isMainFrame) {
              return;
            }

            final lowerFailingUrl = failingUrl.toLowerCase();
            if (lowerFailingUrl.endsWith('/favicon.ico') ||
                lowerFailingUrl.contains('/assets/assets/images/logo.svg')) {
              return;
            }

            final canRecoverFromLocalServerDrop = !_didFallbackToLocalFile &&
                !_isRecoveringFromLoadError &&
                error.errorCode == -1005 &&
                lowerFailingUrl.contains('http://127.0.0.1:');
            if (canRecoverFromLocalServerDrop) {
              _recoverFromLocalServerDrop();
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
    _didFallbackToLocalFile = false;
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

    throw StateError(
      'Unable to load startup landing HTML.\n${attempts.join('\n')}',
    );
  }

  void _recoverFromLocalServerDrop() {
    if (_isRecoveringFromLoadError) return;
    final controller = _controller;
    if (controller == null) return;
    _isRecoveringFromLoadError = true;

    if (mounted) {
      _startLoadingWatchdog();
      setState(() {
        _isPageLoading = true;
        _loadError = null;
      });
    }

    unawaited(() async {
      final recovered = await _loadStartupLandingFromLocalFile(controller);
      _isRecoveringFromLoadError = false;
      if (recovered || !mounted) return;

      _stopLoadingWatchdog();
      setState(() {
        _loadError = '-1005: The network connection was lost.';
        _isPageLoading = false;
      });
    }());
  }

  Future<bool> _loadStartupLandingFromLocalFile(WebViewController controller) async {
    final indexPath = _resolveStartupIndexPath();
    if (indexPath == null) return false;
    try {
      await controller.loadFile(indexPath);
      _didFallbackToLocalFile = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  String _resolveFlutterAssetsDirFromExecutable() {
    final executableFile = File(Platform.resolvedExecutable);
    final contentsDir = executableFile.parent.parent.path;
    return _joinPath(
      _joinPath(_joinPath(contentsDir, 'Frameworks'), 'App.framework'),
      'Resources/flutter_assets',
    );
  }

  String? _resolveStartupIndexPath() {
    final flutterAssetsDir = _resolveFlutterAssetsDirFromExecutable();
    final existingRoot = _startupRootDir;
    if (existingRoot != null) {
      final normalizedExistingRoot = existingRoot.replaceAll('\\', '/');
      final normalizedFlutterAssetsDir = flutterAssetsDir.replaceAll('\\', '/');
      final isBundledRoot =
          normalizedExistingRoot.startsWith(normalizedFlutterAssetsDir);
      if (isBundledRoot) {
        final directIndex = File(_joinPath(existingRoot, 'index.html'));
        if (directIndex.existsSync()) {
          return directIndex.path;
        }
      }
    }

    final rootDir = _resolveLandingRootDir(flutterAssetsDir);
    if (rootDir == null) return null;
    final indexFile = File(_joinPath(rootDir, 'index.html'));
    if (!indexFile.existsSync()) return null;
    return indexFile.path;
  }

  bool _hasLandingIndex(String dirPath) {
    if (dirPath.trim().isEmpty) return false;
    final directory = Directory(dirPath);
    if (!directory.existsSync()) return false;
    return File('${directory.path}/index.html').existsSync();
  }

  String _joinPath(String base, String child) {
    final separator = Platform.pathSeparator;
    if (base.endsWith(separator)) return '$base$child';
    return '$base$separator$child';
  }

  String? _resolveLandingRootFromBase(String basePath) {
    if (basePath.trim().isEmpty) return null;

    // Prefer exact startup folder names first.
    final directCandidates = <String>[
      _joinPath(basePath, 'website_8answers copy 2'),
      _joinPath(basePath, 'website_8answers%20copy%202'),
    ];
    for (final candidate in directCandidates) {
      if (_hasLandingIndex(candidate)) {
        return Directory(candidate).path;
      }
    }

    // Then fallback to scanning any matching folder.
    final baseDir = Directory(basePath);
    if (!baseDir.existsSync()) return null;
    final candidateDirs = baseDir.listSync().whereType<Directory>().where((dir) {
      final name = _basename(dir.path).toLowerCase();
      return name.startsWith('website_8answers');
    }).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final dir in candidateDirs) {
      if (_hasLandingIndex(dir.path)) {
        return dir.path;
      }
    }
    return null;
  }

  String? _resolveLandingRootDir(String flutterAssetsDir) {
    // Use bundled app assets only to avoid macOS sandbox file-access violations.
    final bundledBases = <String>[
      _joinPath(flutterAssetsDir, 'web'),
      _joinPath(_joinPath(flutterAssetsDir, 'assets'), 'web'),
    ];
    for (final base in bundledBases) {
      final bundledRoot = _resolveLandingRootFromBase(base);
      if (bundledRoot != null) {
        return bundledRoot;
      }
    }

    return null;
  }

  Future<Uri?> _startStartupServer() async {
    if (_startupServer != null && _startupHomeUri != null) {
      return _startupHomeUri;
    }

    final flutterAssetsDir = _resolveFlutterAssetsDirFromExecutable();
    final rootDir = _resolveLandingRootDir(flutterAssetsDir);
    if (rootDir == null) return null;

    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      server.autoCompress = false;
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
    try {
      final rootDir = _startupRootDir;
      if (rootDir == null) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }

      String decodedPath;
      try {
        decodedPath = Uri.decodeComponent(request.uri.path);
      } catch (_) {
        decodedPath = request.uri.path;
      }

      if (decodedPath.isEmpty || decodedPath == '/') {
        decodedPath = '/index.html';
      }

      if (!decodedPath.startsWith('/')) {
        decodedPath = '/$decodedPath';
      }

      // Normalize prefixed startup paths to root-relative files under rootDir.
      final lowerPath = decodedPath.toLowerCase();
      const landingPrefixes = <String>[
        '/website_8answers copy 2',
        '/website_8answers%20copy%202',
      ];
      for (final prefix in landingPrefixes) {
        if (lowerPath == prefix) {
          decodedPath = '/index.html';
          break;
        }
        if (lowerPath.startsWith('$prefix/')) {
          decodedPath = decodedPath.substring(prefix.length);
          if (decodedPath.isEmpty || decodedPath == '/') {
            decodedPath = '/index.html';
          } else if (!decodedPath.startsWith('/')) {
            decodedPath = '/$decodedPath';
          }
          break;
        }
      }

      if (decodedPath.contains('..')) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }

      final normalizedPath = decodedPath.replaceAll('\\', '/');
      String resolvedPath = '$rootDir$normalizedPath';
      File file = File(resolvedPath);

      if (!file.existsSync()) {
        final lower = normalizedPath.toLowerCase();
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
        } else if (!normalizedPath.contains('.')) {
          file = File('$rootDir/index.html');
        }
      }

      if (!file.existsSync()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      request.response.headers.contentType = _contentTypeForPath(file.path);
      request.response.contentLength = await file.length();
      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {}
    }
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
