import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/account_settings_screen.dart';
import 'widgets/app_scale_metrics.dart';
import 'widgets/unauthenticated_page.dart';

const String _landingPathEncoded = '/website_8answers%20copy%202/';
const String _landingPathDecoded = '/website_8answers copy 2/';

bool _isLandingPath(String path) {
  final lowerPath = path.toLowerCase();
  return lowerPath.contains(_landingPathEncoded.toLowerCase()) ||
      lowerPath.contains(_landingPathDecoded.toLowerCase());
}

String _resolveAppBasePath(Uri uri) {
  var path = uri.path.isEmpty ? '/' : uri.path;
  final lowerPath = path.toLowerCase();
  final encodedIndex = lowerPath.indexOf(_landingPathEncoded.toLowerCase());
  final decodedIndex = lowerPath.indexOf(_landingPathDecoded.toLowerCase());
  final segmentIndex = encodedIndex >= 0
      ? encodedIndex
      : decodedIndex >= 0
          ? decodedIndex
          : -1;

  if (segmentIndex >= 0) {
    path = path.substring(0, segmentIndex + 1);
  } else if (path.endsWith('/index.html')) {
    path = path.substring(0, path.length - '/index.html'.length);
  } else if (!path.endsWith('/')) {
    final lastSlash = path.lastIndexOf('/');
    path = lastSlash >= 0 ? path.substring(0, lastSlash + 1) : '/';
  }

  if (!path.startsWith('/')) path = '/$path';
  if (!path.endsWith('/')) path = '$path/';
  return path;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Supabase.initialize(
      url: 'https://dsbxgrkbmcnidlsykqwj.supabase.co',
      anonKey: 'sb_publishable_BEJgmnl-V3uOLAwQr0qcnA_upzNyW9_',
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  } catch (e) {
    print('Error initializing Supabase: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  bool _shouldOpenAuthFlow() {
    final uri = Uri.base;
    final params = uri.queryParameters;
    final path = uri.path;

    // Explicit auth trigger from static sign-in page.
    if (params['auth'] == 'google') {
      return true;
    }

    // OAuth callback can arrive on base paths (e.g., subpath deploys).
    final hasCallback = params.containsKey('code') && params.containsKey('state');
    if (!hasCallback) return false;

    // Ignore callbacks while already on landing microsite paths.
    return !_isLandingPath(path);
  }

  @override
  Widget build(BuildContext context) {
    final openAuthFlow = _shouldOpenAuthFlow();

    return MaterialApp(
      title: 'Landman Website',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Inter',
        useMaterial3: true,
        scrollbarTheme: ScrollbarThemeData(
          thumbVisibility: const WidgetStatePropertyAll(true),
          trackVisibility: const WidgetStatePropertyAll(false),
          interactive: true,
          thickness: const WidgetStatePropertyAll(8),
          radius: const Radius.circular(8),
          crossAxisMargin: 8,
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.dragged)) {
              return const Color(0xFF5C5C5C);
            }
            return const Color(0x665C5C5C);
          }),
        ),
      ),
      home: openAuthFlow
          ? AuthWrapper(triggerGoogleSignIn: openAuthFlow)
          : const UnauthenticatedPage(),
    );
  }
}

class AppScaleWrapper extends StatelessWidget {
  const AppScaleWrapper({
    super.key,
    required this.child,
    required this.baseWidth,
    required this.baseHeight,
  });

  final Widget child;
  final double baseWidth;
  final double baseHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaQuery = MediaQuery.of(context);
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;

        if (!availableWidth.isFinite || !availableHeight.isFinite) {
          return child;
        }

        final widthRatio = availableWidth / baseWidth;
        final heightRatio = availableHeight / baseHeight;
        final designAspectRatio = baseWidth / baseHeight;
        final viewportAspectRatio = availableWidth / availableHeight;
        // Keep 1300..1440 edge-to-edge only on aspect ratios close to design.
        // On short-height screens (wide aspect), fall back to contain to avoid bottom clipping.
        final widthPriorityCandidate =
            availableWidth >= 1300 && availableWidth <= baseWidth;
        final isShortHeightViewport =
            viewportAspectRatio > (designAspectRatio * 1.12);
        final widthPriorityFitsHeight =
            (baseHeight * widthRatio) <= availableHeight;
        final useWidthPriorityScale = widthPriorityCandidate &&
            !isShortHeightViewport &&
            widthPriorityFitsHeight;
        final rawScale = useWidthPriorityScale
            ? widthRatio
            : math.min(widthRatio, heightRatio);
        final scale = rawScale.clamp(0.0, 1.0);
        final shouldStretchHorizontally = availableWidth > baseWidth;

        final designViewportWidthRaw =
            scale > 0 ? availableWidth / scale : baseWidth;
        final designViewportWidth =
            shouldStretchHorizontally ? designViewportWidthRaw : baseWidth;
        final rightOverflowWidth = shouldStretchHorizontally
            ? 0.0
            : math.max(0.0, designViewportWidthRaw - designViewportWidth);
        final designCanvasSize = Size(designViewportWidth, baseHeight);

        return SizedBox(
          width: availableWidth,
          height: availableHeight,
          child: ClipRect(
            child: FittedBox(
              fit: useWidthPriorityScale ? BoxFit.fitWidth : BoxFit.contain,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: designCanvasSize.width,
                height: baseHeight,
                child: AppScaleMetrics(
                  designViewportWidth: designViewportWidth,
                  rightOverflowWidth: rightOverflowWidth,
                  child: MediaQuery(
                    // Below 1440 keep fixed-width scaling; above 1440 allow horizontal stretch.
                    data: mediaQuery.copyWith(
                      size: designCanvasSize,
                      textScaler: const TextScaler.linear(1.0),
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({
    super.key,
    this.triggerGoogleSignIn = false,
  });

  final bool triggerGoogleSignIn;

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _isInitialized = false;
  bool _isLoggedIn = false;
  bool _isGoogleSignInInProgress = false;
  bool _hasAttemptedAutoGoogleSignIn = false;
  bool _oauthCallbackResolutionTimedOut = false;
  static const Duration _oauthCallbackWaitTimeout = Duration(seconds: 6);

  Future<void> _markRecentProjectsAsStartPage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nav_current_page', 'recentProjects');
    await prefs.remove('nav_previous_page');
    await prefs.setBool('nav_force_recent_on_next_open', true);
  }

  @override
  void initState() {
    super.initState();
    _checkAuthState();
    _listenToAuthStateChanges();
    _maybeAutoSignInWithGoogle();
    _guardOAuthCallbackLoading();
  }

  void _checkAuthState() {
    // Check if user is already logged in
    final session = Supabase.instance.client.auth.currentSession;
    setState(() {
      _isInitialized = true;
      _isLoggedIn = session != null;
    });
  }

  bool _hasOAuthCallbackData() {
    final params = Uri.base.queryParameters;
    return params.containsKey('code') ||
        params.containsKey('access_token') ||
        params.containsKey('refresh_token');
  }

  void _guardOAuthCallbackLoading() {
    if (!_hasOAuthCallbackData()) return;
    if (Supabase.instance.client.auth.currentSession != null) return;

    Future<void>.delayed(_oauthCallbackWaitTimeout, () {
      if (!mounted) return;
      // Avoid a permanent loading screen when callback query params are stale.
      if (!_isLoggedIn) {
        setState(() {
          _oauthCallbackResolutionTimedOut = true;
        });
      }
    });
  }

  Uri _buildOAuthRedirectUri() {
    final baseUri = Uri.base;
    final appBasePath = _resolveAppBasePath(baseUri);
    final queryParameters = const {'auth': 'google'};

    if (!kDebugMode) {
      return Uri(
        scheme: baseUri.scheme,
        host: baseUri.host,
        port: baseUri.hasPort ? baseUri.port : null,
        path: appBasePath,
        queryParameters: queryParameters,
      );
    }

    final isLoopbackHost =
        baseUri.host == 'localhost' || baseUri.host == '127.0.0.1';

    return Uri(
      scheme: 'http',
      host: isLoopbackHost ? baseUri.host : 'localhost',
      port: baseUri.hasPort ? baseUri.port : 8080,
      path: appBasePath,
      queryParameters: queryParameters,
    );
  }

  Future<void> _maybeAutoSignInWithGoogle() async {
    if (!widget.triggerGoogleSignIn) return;
    if (_hasAttemptedAutoGoogleSignIn) return;
    _hasAttemptedAutoGoogleSignIn = true;

    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) return;

    final params = Uri.base.queryParameters;

    // If we are already on callback URL, let Supabase process callback.
    if (params.containsKey('code') ||
        params.containsKey('error') ||
        params.containsKey('access_token') ||
        params.containsKey('refresh_token')) {
      return;
    }

    _isGoogleSignInInProgress = true;
    try {
      final redirectUri = _buildOAuthRedirectUri();

      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: redirectUri.toString(),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _isGoogleSignInInProgress = false;
        });
      } else {
        _isGoogleSignInInProgress = false;
      }
      print('Auto Google sign-in error: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Google sign-in failed: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _listenToAuthStateChanges() {
    // Listen for auth state changes
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final AuthChangeEvent event = data.event;
      final Session? session = data.session;

      setState(() {
        if (event == AuthChangeEvent.signedIn && session != null) {
          _markRecentProjectsAsStartPage();
          _isGoogleSignInInProgress = false;
          _isLoggedIn = true;
          _oauthCallbackResolutionTimedOut = false;
        } else if (event == AuthChangeEvent.signedOut) {
          _isGoogleSignInInProgress = false;
          _isLoggedIn = false;
        }
      });
    }, onError: (error) {
      print('Auth state change error: $error');
      // Don't show error for code verifier issues on initial load
      if (error.toString().contains('Code verifier')) {
        print('PKCE code verifier issue, this is expected on page reload');
        // Keep the current auth state
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool waitingOnOAuthCallback = _hasOAuthCallbackData() &&
        !_isLoggedIn &&
        !_oauthCallbackResolutionTimedOut;

    if (!_isInitialized ||
        _isGoogleSignInInProgress ||
        waitingOnOAuthCallback) {
      // Show loading screen while checking auth state
      return const AppScaleWrapper(
        baseWidth: 1440,
        baseHeight: 1024,
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0C8CE9)),
            ),
          ),
        ),
      );
    }

    if (_isLoggedIn) {
      // User is logged in, show main app
      return const AppScaleWrapper(
        baseWidth: 1440,
        baseHeight: 1024,
        child: AccountSettingsScreen(),
      );
    } else {
      // User is not logged in, show login page
      return const AppScaleWrapper(
        baseWidth: 1440,
        baseHeight: 1024,
        child: UnauthenticatedPage(),
      );
    }
  }
}
