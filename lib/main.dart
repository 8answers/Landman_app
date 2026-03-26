import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/account_settings_screen.dart';
import 'services/project_access_service.dart';
import 'services/projects_list_cache_service.dart';
import 'utils/web_navigation_context.dart' as web_nav;
import 'widgets/app_scale_metrics.dart';
import 'widgets/unauthenticated_page.dart';

const String _landingPathEncoded = '/website_8answers%20copy%202/';
const String _landingPathDecoded = '/website_8answers copy 2/';
const String kAppBrandName = '8Answers';

String _normalizeAuthParam(String? authValue) {
  var normalized = (authValue ?? '').trim();
  if (normalized.isEmpty) return '';
  for (var i = 0; i < 3; i++) {
    if (!normalized.contains('%')) break;
    try {
      final decoded = Uri.decodeComponent(normalized).trim();
      if (decoded.isEmpty || decoded == normalized) break;
      normalized = decoded;
    } catch (_) {
      break;
    }
  }
  return normalized;
}

bool _isGoogleAuthParam(String? authValue) {
  final normalized = _normalizeAuthParam(authValue).toLowerCase();
  return normalized == 'google' || normalized.startsWith('google:');
}

Map<String, String> _extractInviteContextFromToken(String? tokenValue) {
  final raw = (tokenValue ?? '').trim();
  if (raw.isEmpty) return const <String, String>{};
  try {
    final normalized = base64.normalize(raw);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final payload = jsonDecode(decoded);
    if (payload is! Map) return const <String, String>{};
    final projectId = (payload['projectId'] ?? '').toString().trim();
    if (projectId.isEmpty) return const <String, String>{};
    final projectRole = (payload['projectRole'] ?? '').toString().trim();
    final projectName = (payload['projectName'] ?? '').toString().trim();
    final ownerEmail = (payload['ownerEmail'] ?? '').toString().trim();
    return <String, String>{
      'projectId': projectId,
      if (projectRole.isNotEmpty) 'projectRole': projectRole,
      if (projectName.isNotEmpty) 'projectName': projectName,
      if (ownerEmail.isNotEmpty) 'ownerEmail': ownerEmail,
    };
  } catch (_) {
    return const <String, String>{};
  }
}

String _extractInviteTokenFromUri(Uri uri) {
  final fromQuery =
      (uri.queryParameters['inviteToken'] ?? uri.queryParameters['inv'] ?? '')
          .trim();
  if (fromQuery.isNotEmpty) return fromQuery;

  final segments = uri.pathSegments;
  for (var i = 0; i < segments.length; i++) {
    if (segments[i].toLowerCase() == 'invite' && i + 1 < segments.length) {
      final candidate = segments[i + 1].trim();
      if (candidate.isNotEmpty) return candidate;
    }
  }
  return '';
}

Map<String, String> _extractInviteContextFromAuthValue(String? authValue) {
  final raw = _normalizeAuthParam(authValue);
  if (raw.isEmpty) return const <String, String>{};
  final separatorIndex = raw.indexOf(':');
  if (separatorIndex <= 0) return const <String, String>{};
  final provider = raw.substring(0, separatorIndex).trim().toLowerCase();
  if (provider != 'google') return const <String, String>{};
  final encodedPayload = raw.substring(separatorIndex + 1).trim();
  if (encodedPayload.isEmpty) return const <String, String>{};

  try {
    final normalized = base64.normalize(encodedPayload);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final payload = jsonDecode(decoded);
    if (payload is! Map) return const <String, String>{};
    final projectId = (payload['projectId'] ?? '').toString().trim();
    if (projectId.isEmpty) return const <String, String>{};
    final projectRole = (payload['projectRole'] ?? '').toString().trim();
    final projectName = (payload['projectName'] ?? '').toString().trim();
    final ownerEmail = (payload['ownerEmail'] ?? '').toString().trim();
    return <String, String>{
      'projectId': projectId,
      if (projectRole.isNotEmpty) 'projectRole': projectRole,
      if (projectName.isNotEmpty) 'projectName': projectName,
      if (ownerEmail.isNotEmpty) 'ownerEmail': ownerEmail,
    };
  } catch (_) {
    return const <String, String>{};
  }
}

String _composeAuthValueForGoogle({
  required String projectId,
  String? projectRole,
  String? projectName,
  String? ownerEmail,
}) {
  final normalizedProjectId = projectId.trim();
  if (normalizedProjectId.isEmpty) return 'google';
  final payload = <String, String>{
    'projectId': normalizedProjectId,
    'projectRole': (projectRole ?? '').trim().isEmpty
        ? 'partner'
        : projectRole!.trim().toLowerCase(),
  };
  final normalizedProjectName = (projectName ?? '').trim();
  if (normalizedProjectName.isNotEmpty) {
    payload['projectName'] = normalizedProjectName;
  }
  final normalizedOwnerEmail = (ownerEmail ?? '').trim().toLowerCase();
  if (normalizedOwnerEmail.isNotEmpty) {
    payload['ownerEmail'] = normalizedOwnerEmail;
  }
  final encodedPayload = base64Url.encode(utf8.encode(jsonEncode(payload)));
  return 'google:$encodedPayload';
}

bool _isLandingPath(String path) {
  final lowerPath = path.toLowerCase();
  return lowerPath.contains(_landingPathEncoded.toLowerCase()) ||
      lowerPath.contains(_landingPathDecoded.toLowerCase());
}

bool _isKnownAppShellPath(String rawPath) {
  var path = rawPath.trim();
  if (path.isEmpty) return false;
  if (path.endsWith('/index.html')) {
    path = path.substring(0, path.length - '/index.html'.length);
  }
  String decodedPath;
  try {
    decodedPath = Uri.decodeComponent(path).toLowerCase();
  } catch (_) {
    decodedPath = path.toLowerCase();
  }
  final segments = decodedPath
      .split('/')
      .where((segment) => segment.trim().isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) return false;

  const knownRoutes = <String>{
    'dashboard',
    'dataentry',
    'data-entry',
    'data entry',
    'plotstatus',
    'plot-status',
    'plot status',
    'documents',
    'report',
    'reports',
    'settings',
    'recent',
    'recentprojects',
    'recent-projects',
    'allprojects',
    'all-projects',
    'account',
    'notifications',
    'todo',
    'to-do',
    'to-do-list',
    'todolist',
    'help',
    'trash',
    'logout',
  };
  return knownRoutes.contains(segments.last.trim());
}

String _resolveAppBasePath(Uri uri) {
  var path = uri.path.isEmpty ? '/' : uri.path;
  final lowerPath = path.toLowerCase();
  final encodedIndex = lowerPath.indexOf(_landingPathEncoded.toLowerCase());
  final decodedIndex = lowerPath.indexOf(_landingPathDecoded.toLowerCase());
  final inviteIndex = lowerPath.indexOf('/invite/');
  final segmentIndex = encodedIndex >= 0
      ? encodedIndex
      : decodedIndex >= 0
          ? decodedIndex
          : inviteIndex >= 0
              ? inviteIndex
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

Future<void> _persistInviteContextFromInitialUrl() async {
  final uri = Uri.base;
  final params = uri.queryParameters;
  final authInviteContext = _extractInviteContextFromAuthValue(params['auth']);
  final tokenInviteContext =
      _extractInviteContextFromToken(_extractInviteTokenFromUri(uri));
  final projectId = (params['projectId'] ??
          authInviteContext['projectId'] ??
          tokenInviteContext['projectId'] ??
          '')
      .trim();
  final hasInviteMarker = params['invite'] == '1' || projectId.isNotEmpty;
  if (!hasInviteMarker || projectId.isEmpty) return;
  final isReload = kIsWeb ? await web_nav.isReloadNavigation() : false;
  if (isReload) return;
  final projectRole = (params['projectRole'] ??
          authInviteContext['projectRole'] ??
          tokenInviteContext['projectRole'] ??
          '')
      .trim()
      .toLowerCase();
  final resolvedInviteRole = projectRole.isEmpty ? 'partner' : projectRole;
  final projectName = (params['projectName'] ??
          authInviteContext['projectName'] ??
          tokenInviteContext['projectName'] ??
          '')
      .trim();
  final ownerEmail = (params['ownerEmail'] ??
          authInviteContext['ownerEmail'] ??
          tokenInviteContext['ownerEmail'] ??
          '')
      .trim()
      .toLowerCase();

  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('nav_current_page', 'dashboard');
  await prefs.remove('nav_previous_page');
  await prefs.setString('nav_project_id', projectId);
  if (projectName.isNotEmpty) {
    await prefs.setString('nav_project_name', projectName);
  }
  if (ownerEmail.isNotEmpty) {
    await prefs.setString('nav_project_owner_email', ownerEmail);
  }
  await prefs.setString('nav_invited_project_role', resolvedInviteRole);
  await prefs.setBool('nav_has_invite_context', true);
  await prefs.setBool('nav_open_invite_dashboard_once', true);
  await prefs.setBool('nav_force_recent_on_next_open', false);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Supabase.initialize(
      // Previous Supabase config:
      // url: 'https://dsbxgrkbmcnidlsykqwj.supabase.co',
      // anonKey: 'sb_publishable_BEJgmnl-V3uOLAwQr0qcnA_upzNyW9_',
      url: 'https://xljsafhmsncothpsbfpp.supabase.co',
      anonKey: 'sb_publishable_rA1TCLO0cW6h6y69DCdPjw_GWmr0R-r',
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  } catch (_) {
    debugPrint('Error initializing authentication service.');
  }
  await _persistInviteContextFromInitialUrl();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  bool _shouldOpenAuthFlow() {
    final uri = Uri.base;
    final params = uri.queryParameters;
    final path = uri.path;
    final inviteToken = _extractInviteTokenFromUri(uri);

    // Known in-app routes should always open the authenticated app shell.
    if (_isKnownAppShellPath(path)) {
      return true;
    }

    // Explicit auth trigger from static sign-in page.
    if (_isGoogleAuthParam(params['auth'])) {
      return true;
    }
    // Invite link should open authenticated app flow.
    if (params['invite'] == '1' ||
        inviteToken.isNotEmpty ||
        (params['projectId'] ?? '').trim().isNotEmpty) {
      return true;
    }

    // OAuth callback can arrive on base paths (e.g., subpath deploys).
    final hasCallback =
        params.containsKey('code') && params.containsKey('state');
    if (!hasCallback) return false;

    // Ignore callbacks while already on landing microsite paths.
    return !_isLandingPath(path);
  }

  @override
  Widget build(BuildContext context) {
    final openAuthFlow = _shouldOpenAuthFlow();
    final uri = Uri.base;
    final queryParams = uri.queryParameters;
    final inviteToken = _extractInviteTokenFromUri(uri);
    final triggerGoogleSignIn = _isGoogleAuthParam(queryParams['auth']) ||
        queryParams['invite'] == '1' ||
        inviteToken.isNotEmpty ||
        (queryParams['projectId'] ?? '').trim().isNotEmpty;

    return MaterialApp(
      title: kAppBrandName,
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
      home: _PhoneAccessGuard(
        child: openAuthFlow
            ? AuthWrapper(triggerGoogleSignIn: triggerGoogleSignIn)
            : const UnauthenticatedPage(),
      ),
    );
  }
}

class _PhoneAccessGuard extends StatelessWidget {
  const _PhoneAccessGuard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaQuery = MediaQuery.of(context);
        final view = View.of(context);
        final viewLogicalWidth =
            view.physicalSize.width / view.devicePixelRatio;
        final viewLogicalHeight =
            view.physicalSize.height / view.devicePixelRatio;
        final viewportWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : viewLogicalWidth;
        final viewportHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : viewLogicalHeight;
        final effectiveWidth = math.min(mediaQuery.size.width, viewportWidth);
        final effectiveHeight =
            math.min(mediaQuery.size.height, viewportHeight);
        final shortestSide = math.min(effectiveWidth, effectiveHeight);
        final isPhone = effectiveWidth < 768 || shortestSide < 600;

        if (!isPhone) return child;

        return const Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.desktop_windows_rounded,
                    size: 64,
                    color: Color(0xFF0C8CE9),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'This application is not available on phone screens.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Please open in a desktop, laptop, or tablet to view the application.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF5C5C5C),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
        // Allow the design canvas to grow vertically with viewport height
        // (in design-space units) so the app fills tall screens too.
        final designViewportHeightRaw =
            scale > 0 ? availableHeight / scale : baseHeight;
        final designViewportHeight =
            math.max(baseHeight, designViewportHeightRaw);
        final designCanvasSize =
            Size(designViewportWidth, designViewportHeight);

        return SizedBox(
          width: availableWidth,
          height: availableHeight,
          child: ClipRect(
            child: FittedBox(
              fit: useWidthPriorityScale ? BoxFit.fitWidth : BoxFit.contain,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: designCanvasSize.width,
                height: designCanvasSize.height,
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
  bool _isBootstrappingLoggedInSession = false;
  bool _isGoogleSignInInProgress = false;
  bool _hasAttemptedAutoGoogleSignIn = false;
  bool _oauthCallbackResolutionTimedOut = false;
  StreamSubscription<AuthState>? _authStateSubscription;
  static const Duration _oauthCallbackWaitTimeout = Duration(seconds: 6);

  Future<bool> _hasInviteDashboardContextInPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final projectId = (prefs.getString('nav_project_id') ?? '').trim();
    final invitedRole =
        (prefs.getString('nav_invited_project_role') ?? '').trim();
    final openInviteDashboardOnce =
        prefs.getBool('nav_open_invite_dashboard_once') ?? false;
    final hasInviteContext = prefs.getBool('nav_has_invite_context') ?? false;
    return projectId.isNotEmpty &&
        (openInviteDashboardOnce || hasInviteContext || invitedRole.isNotEmpty);
  }

  Future<bool> _hasPersistedProjectContextInPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final projectId = (prefs.getString('nav_project_id') ?? '').trim();
    return projectId.isNotEmpty;
  }

  bool _hasInviteContextInCurrentUrl() {
    final uri = Uri.base;
    final params = uri.queryParameters;
    final authInviteContext =
        _extractInviteContextFromAuthValue(params['auth']);
    final tokenInviteContext =
        _extractInviteContextFromToken(_extractInviteTokenFromUri(uri));
    final projectId = (params['projectId'] ??
            authInviteContext['projectId'] ??
            tokenInviteContext['projectId'] ??
            '')
        .trim();
    return params['invite'] == '1' || projectId.isNotEmpty;
  }

  Future<bool> _shouldApplyInviteAccessForCurrentSession() async {
    if (_hasInviteContextInCurrentUrl()) return true;
    if (await _hasInviteDashboardContextInPrefs()) return true;
    // Also validate persisted project access on refresh/open even when the
    // session did not start from an invite URL.
    return _hasPersistedProjectContextInPrefs();
  }

  Future<void> _markRecentProjectsAsStartPage(
      {bool forceRecent = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (forceRecent) {
      await prefs.setString('nav_current_page', 'recentProjects');
      await prefs.remove('nav_previous_page');
      await prefs.setBool('nav_force_recent_on_next_open', false);
      await prefs.remove('nav_open_invite_dashboard_once');
      await prefs.remove('nav_invited_project_role');
      await prefs.remove('nav_has_invite_context');
      await prefs.remove('nav_project_id');
      await prefs.remove('nav_project_name');
      await prefs.remove('nav_project_owner_email');
      return;
    }

    final projectId = (prefs.getString('nav_project_id') ?? '').trim();
    final invitedRole =
        (prefs.getString('nav_invited_project_role') ?? '').trim();
    final openInviteDashboardOnce =
        prefs.getBool('nav_open_invite_dashboard_once') ?? false;
    final hasInviteContext = prefs.getBool('nav_has_invite_context') ?? false;
    final shouldPreserveInviteDashboard = projectId.isNotEmpty &&
        (openInviteDashboardOnce || hasInviteContext || invitedRole.isNotEmpty);
    if (shouldPreserveInviteDashboard) {
      if (!hasInviteContext) {
        await prefs.setBool('nav_has_invite_context', true);
      }
      if (invitedRole.isEmpty) {
        await prefs.setString('nav_invited_project_role', 'partner');
      }
      return;
    }
    // Preserve last visited page for non-invite sessions as well.
    // Only initialize to Recent Projects when no page has ever been stored.
    final existingPage = (prefs.getString('nav_current_page') ?? '').trim();
    if (existingPage.isEmpty) {
      await prefs.setString('nav_current_page', 'recentProjects');
      await prefs.remove('nav_previous_page');
    }
    await prefs.setBool('nav_force_recent_on_next_open', false);
  }

  Future<void> _applyInviteAccessForCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final params = Uri.base.queryParameters;
    final authInviteContext =
        _extractInviteContextFromAuthValue(params['auth']);
    final tokenInviteContext =
        _extractInviteContextFromToken(_extractInviteTokenFromUri(Uri.base));
    final shouldOpenInviteDashboardOnce =
        prefs.getBool('nav_open_invite_dashboard_once') ?? false;
    final persistedProjectId = (prefs.getString('nav_project_id') ?? '').trim();
    final inviteProjectIdFromContext = (params['projectId'] ??
            authInviteContext['projectId'] ??
            tokenInviteContext['projectId'] ??
            '')
        .trim();

    final projectId = (shouldOpenInviteDashboardOnce
            ? (inviteProjectIdFromContext.isNotEmpty
                ? inviteProjectIdFromContext
                : persistedProjectId)
            : (persistedProjectId.isNotEmpty
                ? persistedProjectId
                : inviteProjectIdFromContext))
        .trim();
    if (projectId.isEmpty) return;
    final hasInviteAttempt = shouldOpenInviteDashboardOnce &&
        ((params['invite'] == '1') ||
            (params['projectId'] ?? '').trim().isNotEmpty ||
            ((authInviteContext['projectId'] ?? '').trim().isNotEmpty) ||
            ((tokenInviteContext['projectId'] ?? '').trim().isNotEmpty));
    final hasPersistedMemberContext =
        (prefs.getString('nav_project_id') ?? '').trim().isNotEmpty &&
            ((prefs.getBool('nav_has_invite_context') ?? false) ||
                (prefs.getBool('nav_open_invite_dashboard_once') ?? false) ||
                (prefs.getString('nav_invited_project_role') ?? '')
                    .trim()
                    .isNotEmpty);

    final inviteRoleFromContext = (params['projectRole'] ??
            authInviteContext['projectRole'] ??
            tokenInviteContext['projectRole'] ??
            '')
        .trim()
        .toLowerCase();
    final persistedInviteRole =
        (prefs.getString('nav_invited_project_role') ?? '')
            .trim()
            .toLowerCase();
    final invitedRole = shouldOpenInviteDashboardOnce
        ? (inviteRoleFromContext.isNotEmpty
            ? inviteRoleFromContext
            : (persistedInviteRole.isNotEmpty
                ? persistedInviteRole
                : 'partner'))
        : (persistedInviteRole.isNotEmpty ? persistedInviteRole : 'partner');
    final projectNameFromContext = (params['projectName'] ??
            authInviteContext['projectName'] ??
            tokenInviteContext['projectName'] ??
            '')
        .trim();
    final persistedProjectName =
        (prefs.getString('nav_project_name') ?? '').trim();
    final projectName = shouldOpenInviteDashboardOnce
        ? (projectNameFromContext.isNotEmpty
            ? projectNameFromContext
            : persistedProjectName)
        : persistedProjectName;
    final ownerEmailFromContext = (params['ownerEmail'] ??
            authInviteContext['ownerEmail'] ??
            tokenInviteContext['ownerEmail'] ??
            '')
        .trim()
        .toLowerCase();
    final persistedOwnerEmail =
        (prefs.getString('nav_project_owner_email') ?? '').trim().toLowerCase();
    final ownerEmail = shouldOpenInviteDashboardOnce
        ? (ownerEmailFromContext.isNotEmpty
            ? ownerEmailFromContext
            : persistedOwnerEmail)
        : persistedOwnerEmail;

    String? resolvedRole;
    var sawRoleLookupErrors = false;
    var sawRoleLookupWithoutErrorsAndNoRole = false;
    for (var attempt = 0; attempt < 5; attempt++) {
      await ProjectAccessService.acceptPendingInviteForCurrentUser(
        projectId: projectId,
        roleHint: invitedRole,
      );
      final roleLookup = await ProjectAccessService
          .resolveCurrentUserRolesForProjectWithDiagnostics(
        projectId: projectId,
      );
      if (roleLookup.hadQueryErrors) {
        sawRoleLookupErrors = true;
      } else if (roleLookup.primaryRole == null) {
        sawRoleLookupWithoutErrorsAndNoRole = true;
      }
      resolvedRole = roleLookup.primaryRole;
      if (resolvedRole != null && resolvedRole.trim().isNotEmpty) {
        break;
      }
      if (attempt < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    if (resolvedRole == null) {
      if (hasInviteAttempt && shouldOpenInviteDashboardOnce) {
        // Keep invite context so a delayed membership propagation does not
        // erase the invite flow. Next auth/page bootstrap will retry acceptance.
        await prefs.setString('nav_project_id', projectId);
        if (projectName.isNotEmpty) {
          await prefs.setString('nav_project_name', projectName);
        }
        if (ownerEmail.isNotEmpty) {
          await prefs.setString('nav_project_owner_email', ownerEmail);
        }
        await prefs.setString(
          'nav_invited_project_role',
          invitedRole.isEmpty ? 'partner' : invitedRole,
        );
        await prefs.setBool('nav_has_invite_context', true);
        await prefs.setBool('nav_open_invite_dashboard_once', true);
      } else if (hasPersistedMemberContext &&
          sawRoleLookupErrors &&
          !sawRoleLookupWithoutErrorsAndNoRole) {
        // Refresh guard: preserve existing member context only for transient
        // lookup failures. If lookup cleanly returns "no role", clear access.
        final persistedRole =
            (prefs.getString('nav_invited_project_role') ?? '').trim();
        final fallbackRole = persistedRole.isEmpty
            ? (invitedRole.isEmpty ? 'partner' : invitedRole)
            : persistedRole;
        await prefs.setString('nav_project_id', projectId);
        if (fallbackRole.isNotEmpty) {
          await prefs.setString('nav_invited_project_role', fallbackRole);
        }
        await prefs.setBool('nav_has_invite_context', true);
        await prefs.setBool('nav_open_invite_dashboard_once', false);
        await prefs.setBool('nav_force_recent_on_next_open', false);
        return;
      } else {
        await prefs.remove('nav_project_id');
        await prefs.remove('nav_project_name');
        await prefs.remove('nav_project_owner_email');
        await prefs.remove('nav_invited_project_role');
        await prefs.remove('nav_has_invite_context');
        await prefs.remove('nav_open_invite_dashboard_once');
      }
      await prefs.setString('nav_current_page', 'recentProjects');
      await prefs.remove('nav_previous_page');
      await prefs.setBool('nav_force_recent_on_next_open', false);
      if (hasInviteAttempt) {
        await prefs.setString(
          'nav_access_denied_notice',
          'Access denied. Contact admin to request project access.',
        );
      }
      return;
    }
    await prefs.remove('nav_access_denied_notice');
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId != null && currentUserId.trim().isNotEmpty) {
      ProjectsListCacheService.invalidateUser(currentUserId);
    }

    await prefs.setString('nav_project_id', projectId);
    if (projectName.isNotEmpty) {
      await prefs.setString('nav_project_name', projectName);
    }
    if (ownerEmail.isNotEmpty) {
      await prefs.setString('nav_project_owner_email', ownerEmail);
    }

    if (resolvedRole == 'owner') {
      await prefs.remove('nav_invited_project_role');
      await prefs.remove('nav_has_invite_context');
      await prefs.remove('nav_open_invite_dashboard_once');
      if (hasInviteAttempt) {
        await prefs.setString('nav_project_id', projectId);
        await prefs.setString('nav_current_page', 'dashboard');
        await prefs.remove('nav_previous_page');
        await prefs.setBool('nav_force_recent_on_next_open', false);
      }
      return;
    }

    final existingPage = (prefs.getString('nav_current_page') ?? '').trim();
    await prefs.setString('nav_invited_project_role', resolvedRole);
    await prefs.setBool('nav_has_invite_context', true);
    await prefs.setBool('nav_force_recent_on_next_open', false);
    if (hasInviteAttempt && shouldOpenInviteDashboardOnce) {
      await prefs.setBool('nav_open_invite_dashboard_once', true);
      await prefs.setString('nav_current_page', 'dashboard');
      await prefs.remove('nav_previous_page');
    } else {
      await prefs.setBool('nav_open_invite_dashboard_once', false);
      if (existingPage.isEmpty) {
        await prefs.setString('nav_current_page', 'dashboard');
        await prefs.remove('nav_previous_page');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeAuthWrapper();
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeAuthWrapper() async {
    await _persistInviteContextFromUrl();
    if (!mounted) return;
    final hasSession = Supabase.instance.client.auth.currentSession != null;
    if (hasSession) {
      setState(() {
        _isBootstrappingLoggedInSession = true;
      });
      final isReloadNavigation =
          kIsWeb ? await web_nav.isReloadNavigation() : false;
      final hasInviteContextInUrl = _hasInviteContextInCurrentUrl();
      final shouldApplyInviteAccess =
          await _shouldApplyInviteAccessForCurrentSession();
      if (shouldApplyInviteAccess) {
        await _applyInviteAccessForCurrentUser();
      }
      await _markRecentProjectsAsStartPage(
        forceRecent: !isReloadNavigation && !hasInviteContextInUrl,
      );
      if (!mounted) return;
    }
    _listenToAuthStateChanges();
    _maybeAutoSignInWithGoogle();
    _guardOAuthCallbackLoading();
    if (!mounted) return;
    setState(() {
      _isInitialized = true;
      _isLoggedIn = hasSession;
      _isBootstrappingLoggedInSession = false;
    });
  }

  Future<void> _persistInviteContextFromUrl() async {
    final uri = Uri.base;
    final params = uri.queryParameters;
    final authInviteContext =
        _extractInviteContextFromAuthValue(params['auth']);
    final tokenInviteContext =
        _extractInviteContextFromToken(_extractInviteTokenFromUri(uri));
    final projectId = (params['projectId'] ??
            authInviteContext['projectId'] ??
            tokenInviteContext['projectId'] ??
            '')
        .trim();
    final hasInviteMarker = params['invite'] == '1' || projectId.isNotEmpty;
    if (!hasInviteMarker || projectId.isEmpty) return;
    final isReload = kIsWeb ? await web_nav.isReloadNavigation() : false;
    if (isReload) return;
    final projectRole = (params['projectRole'] ??
            authInviteContext['projectRole'] ??
            tokenInviteContext['projectRole'] ??
            '')
        .trim()
        .toLowerCase();
    final resolvedInviteRole = projectRole.isEmpty ? 'partner' : projectRole;
    final projectName = (params['projectName'] ??
            authInviteContext['projectName'] ??
            tokenInviteContext['projectName'] ??
            '')
        .trim();
    final ownerEmail = (params['ownerEmail'] ??
            authInviteContext['ownerEmail'] ??
            tokenInviteContext['ownerEmail'] ??
            '')
        .trim()
        .toLowerCase();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nav_current_page', 'dashboard');
    await prefs.remove('nav_previous_page');
    await prefs.setString('nav_project_id', projectId);
    if (projectName.isNotEmpty) {
      await prefs.setString('nav_project_name', projectName);
    }
    if (ownerEmail.isNotEmpty) {
      await prefs.setString('nav_project_owner_email', ownerEmail);
    }
    await prefs.setString('nav_invited_project_role', resolvedInviteRole);
    await prefs.setBool('nav_has_invite_context', true);
    await prefs.setBool('nav_open_invite_dashboard_once', true);
    await prefs.setBool('nav_force_recent_on_next_open', false);
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

  Future<Uri> _buildOAuthRedirectUri() async {
    final baseUri = Uri.base;
    final appBasePath = _resolveAppBasePath(baseUri);
    final prefs = await SharedPreferences.getInstance();
    final inviteContextFromAuth =
        _extractInviteContextFromAuthValue(baseUri.queryParameters['auth']);
    final inviteContextFromToken =
        _extractInviteContextFromToken(_extractInviteTokenFromUri(baseUri));
    final invite = (baseUri.queryParameters['invite'] ?? '').trim();
    final projectIdFromUrl =
        (baseUri.queryParameters['projectId'] ?? '').trim();
    final authProjectId = (inviteContextFromAuth['projectId'] ?? '').trim();
    final tokenProjectId = (inviteContextFromToken['projectId'] ?? '').trim();
    final hasExplicitInviteContext = invite == '1' ||
        projectIdFromUrl.isNotEmpty ||
        authProjectId.isNotEmpty ||
        tokenProjectId.isNotEmpty;
    final storedProjectId = (prefs.getString('nav_project_id') ?? '').trim();
    final storedProjectRole =
        (prefs.getString('nav_invited_project_role') ?? '').trim();
    final storedProjectName =
        (prefs.getString('nav_project_name') ?? '').trim();
    final storedOwnerEmail =
        (prefs.getString('nav_project_owner_email') ?? '').trim();
    final hasStoredInviteContext = storedProjectId.isNotEmpty &&
        ((prefs.getBool('nav_has_invite_context') ?? false) ||
            (prefs.getBool('nav_open_invite_dashboard_once') ?? false) ||
            storedProjectRole.isNotEmpty);
    final canUseStoredInviteContext =
        hasExplicitInviteContext && hasStoredInviteContext;

    final projectId = (baseUri.queryParameters['projectId'] ??
            inviteContextFromAuth['projectId'] ??
            inviteContextFromToken['projectId'] ??
            (canUseStoredInviteContext ? storedProjectId : ''))
        .trim();
    final projectRole = (baseUri.queryParameters['projectRole'] ??
            inviteContextFromAuth['projectRole'] ??
            inviteContextFromToken['projectRole'] ??
            (canUseStoredInviteContext ? storedProjectRole : ''))
        .trim();
    final projectName = (baseUri.queryParameters['projectName'] ??
            inviteContextFromAuth['projectName'] ??
            inviteContextFromToken['projectName'] ??
            (canUseStoredInviteContext ? storedProjectName : ''))
        .trim();
    final ownerEmail = (baseUri.queryParameters['ownerEmail'] ??
            inviteContextFromAuth['ownerEmail'] ??
            inviteContextFromToken['ownerEmail'] ??
            (canUseStoredInviteContext ? storedOwnerEmail : ''))
        .trim()
        .toLowerCase();
    final queryParameters = <String, String>{
      'auth': _composeAuthValueForGoogle(
        projectId: projectId,
        projectRole: projectRole,
        projectName: projectName,
        ownerEmail: ownerEmail,
      ),
    };
    if (hasExplicitInviteContext && projectId.isNotEmpty) {
      queryParameters['invite'] = '1';
      queryParameters['projectId'] = projectId;
      if (projectRole.isNotEmpty) {
        queryParameters['projectRole'] = projectRole;
      }
      if (projectName.isNotEmpty) {
        queryParameters['projectName'] = projectName;
      }
      if (ownerEmail.isNotEmpty) {
        queryParameters['ownerEmail'] = ownerEmail;
      }
    }

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
      final redirectUri = await _buildOAuthRedirectUri();

      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: redirectUri.toString(),
        scopes:
            'openid email profile https://www.googleapis.com/auth/gmail.send',
        queryParams: const <String, String>{
          'access_type': 'offline',
          'prompt': 'consent',
        },
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _isGoogleSignInInProgress = false;
        });
      } else {
        _isGoogleSignInInProgress = false;
      }
      debugPrint('Auto Google sign-in failed.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Google sign-in failed. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _listenToAuthStateChanges() {
    // Listen for auth state changes
    _authStateSubscription?.cancel();
    _authStateSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      final AuthChangeEvent event = data.event;
      final Session? session = data.session;

      if (event == AuthChangeEvent.signedIn && session != null) {
        final userId = session.user.id.trim();
        if (userId.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(
            'show_rounding_note_after_login_$userId',
            true,
          );
        }
        final shouldApplyInviteAccess =
            await _shouldApplyInviteAccessForCurrentSession();
        if (shouldApplyInviteAccess) {
          await _applyInviteAccessForCurrentUser();
        }
        await _markRecentProjectsAsStartPage();
        if (!mounted) return;
        setState(() {
          _isGoogleSignInInProgress = false;
          _isLoggedIn = true;
          _oauthCallbackResolutionTimedOut = false;
        });
        return;
      }

      if (event == AuthChangeEvent.signedOut) {
        if (!mounted) return;
        setState(() {
          _isGoogleSignInInProgress = false;
          _isLoggedIn = false;
        });
      }
    }, onError: (error) {
      // Ignore expected PKCE local-storage miss after hard reload.
      if (error.toString().contains('Code verifier')) return;
      debugPrint('Auth state change error.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool waitingOnOAuthCallback = _hasOAuthCallbackData() &&
        !_isLoggedIn &&
        !_oauthCallbackResolutionTimedOut;

    if (!_isInitialized ||
        _isBootstrappingLoggedInSession ||
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
