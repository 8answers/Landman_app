import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as windows_webview;

import '../services/oauth_sign_in_service.dart';

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
  static const String _desktopAuthCallbackUri =
      'com.example.landmanWebsite://login-callback/';

  WebViewController? _controller;
  windows_webview.WebviewController? _windowsController;
  StreamSubscription<String>? _windowsUrlSubscription;
  StreamSubscription<windows_webview.LoadingState>? _windowsLoadingSubscription;
  bool _isPageLoading = true;
  bool _isSigningIn = false;
  String? _loadError;
  Timer? _loadingWatchdog;
  HttpServer? _startupServer;
  String? _startupRootDir;
  Uri? _startupHomeUri;
  bool _didFallbackToLocalFile = false;
  bool _isRecoveringFromLoadError = false;

  bool get _supportsEmbeddedStartupPage =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  String _resolveInitialPath() {
    final raw = widget.initialPath.trim();
    if (raw.isEmpty || raw == '/') return '/index.html';
    return raw.startsWith('/') ? raw : '/$raw';
  }

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  @override
  void dispose() {
    _loadingWatchdog?.cancel();
    _windowsUrlSubscription?.cancel();
    _windowsLoadingSubscription?.cancel();
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

  Uri? _resolveWindowsSigninUri() {
    final home = _startupHomeUri;
    if (home == null) return null;
    return home.replace(
      path: _resolveInitialPath(),
      queryParameters: null,
      fragment: '',
    );
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
      ).timeout(const Duration(seconds: 8));
    } on TimeoutException {
      // Some desktop OAuth launches can keep this Future pending even after the
      // browser has opened. Do not block the startup page spinner indefinitely.
      debugPrint('Startup OAuth launch timed out; waiting for auth callback.');
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
    if (Platform.isWindows) {
      await _initializeWindowsWebView();
      return;
    }
    try {
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

      await _loadStartupLanding(controller);
    } catch (error) {
      if (!mounted) return;
      _stopLoadingWatchdog();
      final resolvedError = _describeLoadError(error);
      setState(() {
        _controller = null;
        _loadError = resolvedError;
        _isPageLoading = false;
      });
    }
  }

  Future<void> _initializeWindowsWebView() async {
    try {
      final controller = windows_webview.WebviewController();
      await controller.initialize();
      await controller.setPopupWindowPolicy(
        windows_webview.WebviewPopupWindowPolicy.deny,
      );

      _windowsUrlSubscription?.cancel();
      _windowsUrlSubscription = controller.url.listen((url) {
        final parsed = Uri.tryParse(url);
        if (_shouldInterceptForOAuth(parsed)) {
          _startGoogleSignIn();
          final signinUri = _resolveWindowsSigninUri();
          if (signinUri != null) {
            unawaited(controller.loadUrl(signinUri.toString()));
          }
        }
      });

      _windowsLoadingSubscription?.cancel();
      _windowsLoadingSubscription =
          controller.loadingState.listen((loadingState) {
        if (!mounted) return;
        final isLoading = loadingState != windows_webview.LoadingState.none;
        if (_isPageLoading == isLoading) return;
        setState(() {
          _isPageLoading = isLoading;
          if (!isLoading) {
            _loadError = null;
          }
        });
      });

      setState(() {
        _windowsController = controller;
        _controller = null;
        _isPageLoading = true;
        _loadError = null;
      });
      _startLoadingWatchdog();

      final localUri = await _startStartupServer();
      if (localUri == null) {
        throw StateError(
            'startup server: unable to resolve startup root directory');
      }
      await controller.loadUrl(localUri.toString());
    } catch (error) {
      if (!mounted) return;
      _stopLoadingWatchdog();
      setState(() {
        _windowsController = null;
        _controller = null;
        _isPageLoading = false;
        _loadError = _describeLoadError(error);
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

  Future<bool> _loadStartupLandingFromLocalFile(
      WebViewController controller) async {
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
    final executablePath = executableFile.path;
    final executableDir = executableFile.parent.path;
    final contentsDir = executableFile.parent.parent.path;

    final candidates = <String>[
      // Windows/Linux packaged app location.
      _joinPath(_joinPath(executableDir, 'data'), 'flutter_assets'),
      // macOS packaged app location.
      _joinPath(
        _joinPath(_joinPath(contentsDir, 'Frameworks'), 'App.framework'),
        'Resources/flutter_assets',
      ),
      // Some debug/profile runs expose App.framework as a sibling product.
      _joinPath(
        _joinPath(_joinPath(contentsDir, '..'), 'App.framework'),
        'Versions/A/Resources/flutter_assets',
      ),
      _joinPath(
        _joinPath(_joinPath(contentsDir, '..'), 'App.framework'),
        'Resources/flutter_assets',
      ),
      // Fallback near executable.
      _joinPath(executableDir, 'flutter_assets'),
      // Local build output fallback for flutter run/debug.
      _joinPath(
        Directory.current.path,
        'build/windows/x64/runner/Debug/data/flutter_assets',
      ),
      _joinPath(
        Directory.current.path,
        'build/windows/x64/runner/Release/data/flutter_assets',
      ),
      _joinPath(
        Directory.current.path,
        'build/macos/Build/Products/Debug/8answers.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets',
      ),
      _joinPath(
        Directory.current.path,
        'build/macos/Build/Products/Release/8answers.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets',
      ),
    ];

    for (final rawCandidate in candidates) {
      final normalized = rawCandidate.replaceAll('\\', '/');
      final dir = Directory(normalized);
      if (dir.existsSync()) {
        return dir.path;
      }
    }

    debugPrint(
      'StartupWebsiteView: flutter_assets directory not found. '
      'resolvedExecutable=$executablePath, cwd=${Directory.current.path}',
    );
    // Keep the original packaged-app path as a final deterministic fallback.
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
    final candidateDirs =
        baseDir.listSync().whereType<Directory>().where((dir) {
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
        'http://127.0.0.1:${server.port}${_resolveInitialPath()}',
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
      final shouldRouteOAuthHintToSignin =
          _shouldInterceptForOAuth(request.uri) &&
              (normalizedPath == '/' ||
                  normalizedPath == '/index' ||
                  normalizedPath == '/index.html');
      String resolvedPath = '$rootDir$normalizedPath';
      File file = shouldRouteOAuthHintToSignin
          ? File('$rootDir/signin.html')
          : File(resolvedPath);

      if (!file.existsSync()) {
        final lower = normalizedPath.toLowerCase();
        if (lower == '/signin' || lower == '/signin/') {
          file = File('$rootDir/signin.html');
        } else if (lower == '/invite' || lower == '/invite/') {
          file = File('$rootDir/invite.html');
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
    final windowsController = _windowsController;
    final hasRenderableWebView =
        (Platform.isWindows && windowsController != null) ||
            (!Platform.isWindows && controller != null);

    if (!hasRenderableWebView) {
      if (_loadError != null) {
        return ColoredBox(
          color: const Color(0xFFF7F9FC),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 48,
                    color: Colors.redAccent,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Unable to load sign-in page.',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _loadError!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.black87,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _initializeWebView,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
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
        if (Platform.isWindows)
          windows_webview.Webview(windowsController!)
        else
          WebViewWidget(controller: controller!),
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
