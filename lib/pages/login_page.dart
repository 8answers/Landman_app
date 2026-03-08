import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/account_settings_screen.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  int _currentImageIndex = 0;
  Timer? _rotationTimer;
  bool _isLoading = false;
  final List<String> _imagePaths = [
    'assets/images/Construction_amico_1.png',
    'assets/images/Work_in_progress_amico_1.png',
  ];
  final SupabaseClient _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _startImageRotation();
    _checkAuthState();
    _listenToAuthChanges();
    _handleOAuthCallback();
  }

  void _handleOAuthCallback() {
    // Handle OAuth callback from URL
    final uri = Uri.base;
    final code = uri.queryParameters['code'];
    final error = uri.queryParameters['error'];

    if (error != null) {
      print('OAuth error: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Authentication failed: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else if (code != null) {
      // OAuth callback received, Supabase will handle it automatically
      print('OAuth callback received with code');
    }
  }

  void _checkAuthState() {
    // Check if user is already logged in
    final session = _supabase.auth.currentSession;
    if (session != null) {
      // User is already logged in, navigate to dashboard
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigateToDashboard();
      });
    }
  }

  void _listenToAuthChanges() {
    // Listen for auth state changes (e.g., after OAuth redirect)
    _supabase.auth.onAuthStateChange.listen((data) {
      final AuthChangeEvent event = data.event;
      final Session? session = data.session;

      if (event == AuthChangeEvent.signedIn && session != null) {
        // User successfully signed in
        if (mounted) {
          print('User signed in successfully: ${session.user.email}');
          setState(() {
            _isLoading = false;
          });
          _navigateToDashboard();
        }
      } else if (event == AuthChangeEvent.signedOut) {
        // User signed out
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      } else if (event == AuthChangeEvent.userUpdated) {
        // User data updated
        print('User updated: ${session?.user.email}');
      }
    }, onError: (error) {
      print('Auth state change error: $error');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Authentication error: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  Future<void> _signInWithGoogle() async {
    try {
      setState(() {
        _isLoading = true;
      });

      final baseUri = Uri.base;
      final isLoopbackHost =
          baseUri.host == 'localhost' || baseUri.host == '127.0.0.1';
      final redirectUri = kDebugMode
          ? Uri(
              scheme: 'http',
              host: isLoopbackHost ? baseUri.host : 'localhost',
              port: baseUri.hasPort ? baseUri.port : 8080,
              path: '/',
            )
          : Uri(
              scheme: baseUri.scheme,
              host: baseUri.host,
              port: baseUri.hasPort ? baseUri.port : null,
              path: '/',
            );
      final redirectUrl = redirectUri.toString();

      print('Initiating Google OAuth with redirect URL: $redirectUrl');

      await _supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: redirectUrl,
      );

      // Note: For web, the user will be redirected to Google, then back to the app
      // The _listenToAuthChanges() method will handle the navigation after successful login
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error signing in: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _navigateToDashboard() async {
    // Ensure fresh login always starts from Recent Projects.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nav_current_page', 'recentProjects');
    await prefs.remove('nav_previous_page');
    await prefs.setBool('nav_force_recent_on_next_open', true);

    // Navigate to account settings screen (main app screen)
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (context) => const AccountSettingsScreen(
          forceRecentStart: true,
        ),
      ),
      (route) => false,
    );
  }

  Widget _buildErrorWidget(String message) {
    return Container(
      color: Colors.grey[100],
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 8),
            Text(
              'Error loading image',
              style: GoogleFonts.inter(fontSize: 14, color: Colors.red),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                message,
                style: GoogleFonts.inter(fontSize: 10, color: Colors.grey),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _rotationTimer?.cancel();
    super.dispose();
  }

  void _startImageRotation() {
    _rotationTimer?.cancel();
    _rotationTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        setState(() {
          _currentImageIndex = (_currentImageIndex + 1) % _imagePaths.length;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Row(
        children: [
          // Left Section
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: MediaQuery.of(context).size.height - 48,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Main Heading
                        Text(
                          'Manage Real-Estate Projects,\nTeam Roles & Financial Tracking!',
                          style: GoogleFonts.inter(
                            fontSize: 32,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                            height: 1.2,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        // Rotating Image Container
                        LayoutBuilder(
                          builder: (context, constraints) {
                            // Make image responsive - use available width or max 542px
                            final maxWidth = constraints.maxWidth > 0
                                ? constraints.maxWidth.clamp(300.0, 542.0)
                                : 542.0;
                            final aspectRatio = 542.0 / 511.0;
                            final imageHeight = maxWidth / aspectRatio;

                            return SizedBox(
                              height: imageHeight,
                              width: maxWidth,
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 500),
                                transitionBuilder: (Widget child,
                                    Animation<double> animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  );
                                },
                                child: Image.asset(
                                  _imagePaths[_currentImageIndex],
                                  key: ValueKey<int>(_currentImageIndex),
                                  fit: BoxFit.contain,
                                  width: maxWidth,
                                  height: imageHeight,
                                  frameBuilder: (context, child, frame,
                                      wasSynchronouslyLoaded) {
                                    if (wasSynchronouslyLoaded ||
                                        frame != null) {
                                      return child;
                                    }
                                    return Container(
                                      color: Colors.grey[50],
                                      child: const Center(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            CircularProgressIndicator(),
                                            SizedBox(height: 16),
                                            Text(
                                              'Loading image...',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                  errorBuilder: (context, error, stackTrace) {
                                    print(
                                        'ERROR loading image ${_imagePaths[_currentImageIndex]}: $error');
                                    return _buildErrorWidget(
                                        'Failed to load image');
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 24),
                        // Tagline
                        Text(
                          'Everything you need to Track your real-estate operations in one place.',
                          style: GoogleFonts.inter(
                            fontSize: 24,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                            height: 1.2,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Right Section
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 104),
                  // Brand Name
                  Text(
                    '8answers',
                    style: GoogleFonts.inter(
                      fontSize: 48,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 104),
                  // Google Login Button
                  Container(
                    height: 60,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.25),
                          blurRadius: 2,
                          offset: const Offset(0, 0),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _isLoading ? null : _signInWithGoogle,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          child: _isLoading
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 16),
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Google Logo
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: SvgPicture.asset(
                                        'assets/images/Google_Logoo.svg',
                                        width: 24,
                                        height: 24,
                                        fit: BoxFit.contain,
                                        placeholderBuilder: (context) =>
                                            const SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        ),
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                          print(
                                              'Error loading Google logo: $error');
                                          // Fallback: Show a simple "G" icon if SVG fails to load
                                          return Container(
                                            width: 24,
                                            height: 24,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF4285F4),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: const Center(
                                              child: Text(
                                                'G',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    // Button Text
                                    Text(
                                      'Continue with Google',
                                      style: GoogleFonts.inter(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
