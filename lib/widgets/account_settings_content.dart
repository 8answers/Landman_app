import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:universal_html/html.dart' as html;

import '../pages/login_page.dart';
import 'app_scale_metrics.dart';
import 'unauthenticated_page.dart';

enum _AccountSettingsTab { loginDetails, reportIdentitySettings }

class AccountSettingsContent extends StatefulWidget {
  final ValueChanged<bool>? onReportIdentityErrorsChanged;

  const AccountSettingsContent({
    super.key,
    this.onReportIdentityErrorsChanged,
  });

  @override
  State<AccountSettingsContent> createState() => _AccountSettingsContentState();
}

class _AccountSettingsContentState extends State<AccountSettingsContent> {
  static const String _reportIdentityLogoBucket = 'account-report-logos';
  static const String _accountSettingsTabPrefKey = 'nav_account_active_tab';

  _AccountSettingsTab _selectedTab = _AccountSettingsTab.loginDetails;

  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _organizationController = TextEditingController();
  final TextEditingController _roleController = TextEditingController();
  final FocusNode _fullNameFocusNode = FocusNode();
  final FocusNode _organizationFocusNode = FocusNode();
  final FocusNode _roleFocusNode = FocusNode();
  Uint8List? _organizationLogoBytes;
  String? _organizationLogoSvg;
  String? _organizationLogoFileName;
  String? _organizationLogoStoragePath;
  Timer? _reportIdentitySaveDebounce;
  bool _isHydratingReportIdentity = false;
  bool _isSavingReportIdentity = false;
  bool _hasQueuedReportIdentitySave = false;

  bool _hasReportIdentityWarnings = false;

  String _accountSettingsTabPrefKeyForUser() {
    final userId = Supabase.instance.client.auth.currentUser?.id.trim() ?? '';
    if (userId.isEmpty) return _accountSettingsTabPrefKey;
    return '${_accountSettingsTabPrefKey}_$userId';
  }

  _AccountSettingsTab? _parseAccountSettingsTabName(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.isEmpty) return null;
    for (final tab in _AccountSettingsTab.values) {
      if (tab.name == normalized) return tab;
    }
    return null;
  }

  Future<void> _restoreSelectedTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userScopedValue =
          prefs.getString(_accountSettingsTabPrefKeyForUser());
      final restored = _parseAccountSettingsTabName(
        userScopedValue ?? prefs.getString(_accountSettingsTabPrefKey),
      );
      if (restored == null || !mounted || _selectedTab == restored) return;
      setState(() {
        _selectedTab = restored;
      });
    } catch (_) {
      // Best-effort restore only.
    }
  }

  Future<void> _persistSelectedTab(_AccountSettingsTab tab) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accountSettingsTabPrefKeyForUser(), tab.name);
      await prefs.setString(_accountSettingsTabPrefKey, tab.name);
    } catch (_) {
      // Best-effort persistence only.
    }
  }

  void _setSelectedTab(_AccountSettingsTab tab, {bool persist = true}) {
    if (_selectedTab != tab) {
      if (mounted) {
        setState(() {
          _selectedTab = tab;
        });
      } else {
        _selectedTab = tab;
      }
    }
    if (persist) {
      unawaited(_persistSelectedTab(tab));
    }
  }

  @override
  void initState() {
    super.initState();
    _fullNameController.addListener(_handleReportIdentityInputStateChanged);
    _organizationController.addListener(_handleReportIdentityInputStateChanged);
    _roleController.addListener(_handleReportIdentityInputStateChanged);
    _fullNameFocusNode.addListener(_handleReportIdentityInputStateChanged);
    _organizationFocusNode.addListener(_handleReportIdentityInputStateChanged);
    _roleFocusNode.addListener(_handleReportIdentityInputStateChanged);

    unawaited(_restoreSelectedTab());
    _loadReportIdentitySettings();
  }

  @override
  void dispose() {
    _fullNameController.removeListener(_handleReportIdentityInputStateChanged);
    _organizationController
        .removeListener(_handleReportIdentityInputStateChanged);
    _roleController.removeListener(_handleReportIdentityInputStateChanged);
    _fullNameFocusNode.removeListener(_handleReportIdentityInputStateChanged);
    _organizationFocusNode
        .removeListener(_handleReportIdentityInputStateChanged);
    _roleFocusNode.removeListener(_handleReportIdentityInputStateChanged);

    _fullNameController.dispose();
    _organizationController.dispose();
    _roleController.dispose();
    _fullNameFocusNode.dispose();
    _organizationFocusNode.dispose();
    _roleFocusNode.dispose();
    _reportIdentitySaveDebounce?.cancel();
    super.dispose();
  }

  bool _isFieldIncomplete(TextEditingController controller) =>
      controller.text.trim().isEmpty;

  bool get _hasUploadedOrganizationLogo =>
      (_organizationLogoBytes != null && _organizationLogoBytes!.isNotEmpty) ||
      (_organizationLogoSvg?.trim().isNotEmpty ?? false);

  bool _getHasReportIdentityWarnings() =>
      _isFieldIncomplete(_fullNameController) ||
      _isFieldIncomplete(_organizationController) ||
      _isFieldIncomplete(_roleController) ||
      !_hasUploadedOrganizationLogo;

  void _syncReportIdentityWarningState({
    bool notifyParent = false,
    bool rebuild = true,
  }) {
    final hasWarnings = _getHasReportIdentityWarnings();
    if (_hasReportIdentityWarnings != hasWarnings) {
      _hasReportIdentityWarnings = hasWarnings;
      notifyParent = true;
    }

    if (notifyParent) {
      widget.onReportIdentityErrorsChanged?.call(_hasReportIdentityWarnings);
    }

    if (rebuild && mounted) {
      setState(() {});
    }
  }

  void _handleReportIdentityInputStateChanged() {
    if (_isHydratingReportIdentity) return;
    _syncReportIdentityWarningState();
    _schedulePersistReportIdentitySettings();
  }

  Future<void> _loadReportIdentitySettings() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _isHydratingReportIdentity = true;
    try {
      final row = await Supabase.instance.client
          .from('account_report_identity_settings')
          .select(
              'full_name, organization, role, logo_storage_path, logo_svg, logo_base64, logo_file_name')
          .eq('user_id', userId)
          .maybeSingle();

      if (!mounted || row == null) return;

      final fullName = (row['full_name'] ?? '').toString();
      final organization = (row['organization'] ?? '').toString();
      final role = (row['role'] ?? '').toString();
      final logoStoragePath =
          (row['logo_storage_path'] ?? '').toString().trim();
      final logoSvg = (row['logo_svg'] ?? '').toString();
      final logoBase64 = (row['logo_base64'] ?? '').toString();
      final logoFileName = (row['logo_file_name'] ?? '').toString();

      Uint8List? logoBytes;
      String? resolvedLogoSvg;

      if (logoStoragePath.isNotEmpty) {
        try {
          final downloadedLogoBytes = await Supabase.instance.client.storage
              .from(_reportIdentityLogoBucket)
              .download(logoStoragePath);
          if (_isSvgFileName(
              logoFileName.isNotEmpty ? logoFileName : logoStoragePath)) {
            final svgText =
                utf8.decode(downloadedLogoBytes, allowMalformed: true).trim();
            if (svgText.isNotEmpty) {
              resolvedLogoSvg = svgText;
            } else {
              logoBytes = downloadedLogoBytes;
            }
          } else {
            logoBytes = downloadedLogoBytes;
          }
        } catch (error) {
          print(
              'AccountSettingsContent: failed to download logo from storage: $error');
        }
      }

      if (resolvedLogoSvg == null &&
          (logoBytes == null || logoBytes.isEmpty) &&
          logoBase64.trim().isNotEmpty) {
        try {
          logoBytes = base64Decode(logoBase64.trim());
        } catch (_) {
          logoBytes = null;
        }
      }

      if (resolvedLogoSvg == null &&
          (logoBytes == null || logoBytes.isEmpty) &&
          logoSvg.trim().isNotEmpty) {
        resolvedLogoSvg = logoSvg;
      }

      _fullNameController.text = fullName;
      _organizationController.text = organization;
      _roleController.text = role;

      setState(() {
        _organizationLogoSvg = resolvedLogoSvg;
        _organizationLogoBytes = logoBytes;
        _organizationLogoFileName =
            logoFileName.trim().isNotEmpty ? logoFileName : null;
        _organizationLogoStoragePath =
            logoStoragePath.isNotEmpty ? logoStoragePath : null;
      });
    } catch (error) {
      print(
          'AccountSettingsContent: failed to load report identity settings: $error');
    } finally {
      _isHydratingReportIdentity = false;
      if (mounted) {
        _syncReportIdentityWarningState(notifyParent: true);
      }
    }
  }

  void _schedulePersistReportIdentitySettings() {
    if (_isHydratingReportIdentity) return;
    _reportIdentitySaveDebounce?.cancel();
    _reportIdentitySaveDebounce = Timer(
        const Duration(milliseconds: 450), _persistReportIdentitySettings);
  }

  Future<void> _persistReportIdentitySettings() async {
    if (_isHydratingReportIdentity) return;

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    if (_isSavingReportIdentity) {
      _hasQueuedReportIdentitySave = true;
      return;
    }

    _isSavingReportIdentity = true;
    try {
      await Supabase.instance.client
          .from('account_report_identity_settings')
          .upsert(
        {
          'user_id': userId,
          'full_name': _fullNameController.text.trim(),
          'organization': _organizationController.text.trim(),
          'role': _roleController.text.trim(),
          'logo_storage_path': _organizationLogoStoragePath,
          'logo_svg': _organizationLogoSvg,
          'logo_base64': (_organizationLogoBytes != null &&
                  _organizationLogoBytes!.isNotEmpty)
              ? base64Encode(_organizationLogoBytes!)
              : null,
          'logo_file_name': _organizationLogoFileName,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id',
      );
    } catch (error) {
      print(
          'AccountSettingsContent: failed to persist report identity: $error');
    } finally {
      _isSavingReportIdentity = false;
      if (_hasQueuedReportIdentitySave) {
        _hasQueuedReportIdentitySave = false;
        await _persistReportIdentitySettings();
      }
    }
  }

  bool _isAllowedLogoFile(html.File file) {
    final fileName = file.name.toLowerCase();
    final mimeType = file.type.toLowerCase();
    final isPng = fileName.endsWith('.png') || mimeType == 'image/png';
    final isJpg = fileName.endsWith('.jpg') ||
        fileName.endsWith('.jpeg') ||
        mimeType == 'image/jpeg';
    final isSvg = fileName.endsWith('.svg') || mimeType == 'image/svg+xml';
    return isPng || isJpg || isSvg;
  }

  bool _isSvgFileName(String fileName) {
    return fileName.trim().toLowerCase().endsWith('.svg');
  }

  String _sanitizeFileName(String input) {
    return input.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  }

  String _detectMimeTypeFromFileName(String fileName) {
    final normalized = fileName.toLowerCase();
    if (normalized.endsWith('.svg')) return 'image/svg+xml';
    if (normalized.endsWith('.jpg') || normalized.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    return 'image/png';
  }

  Future<Uint8List> _readFileBytes(html.File file) async {
    final result = await _readFileContent(file, readAsText: false);
    if (result is ByteBuffer) {
      return Uint8List.view(result);
    }
    if (result is Uint8List) {
      return result;
    }
    if (result is List<int>) {
      return Uint8List.fromList(result);
    }
    throw StateError('Unsupported file read result: ${result.runtimeType}');
  }

  Future<void> _deleteLogoFromStorage(String storagePath) async {
    try {
      await Supabase.instance.client.storage
          .from(_reportIdentityLogoBucket)
          .remove([storagePath]);
    } catch (error) {
      print(
          'AccountSettingsContent: failed to remove logo from storage: $error');
    }
  }

  Future<dynamic> _readFileContent(
    html.File file, {
    required bool readAsText,
    bool readAsDataUrl = false,
  }) async {
    final completer = Completer<dynamic>();
    final reader = html.FileReader();

    reader.onLoadEnd.listen((_) {
      completer.complete(reader.result);
    });
    reader.onError.listen((_) {
      completer.completeError(reader.error ?? 'Failed to read selected file.');
    });

    if (readAsText) {
      reader.readAsText(file);
    } else if (readAsDataUrl) {
      reader.readAsDataUrl(file);
    } else {
      reader.readAsArrayBuffer(file);
    }

    return completer.future;
  }

  Future<void> _pickOrganizationLogo() async {
    final fileInput = html.FileUploadInputElement()
      ..accept = '.png,.jpg,.jpeg,.svg,image/png,image/jpeg,image/svg+xml'
      ..multiple = false;

    fileInput.click();
    await fileInput.onChange.first;

    final selectedFiles = fileInput.files;
    if (selectedFiles == null || selectedFiles.isEmpty) return;

    final file = selectedFiles.first;
    if (!_isAllowedLogoFile(file)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please upload only PNG, JPG, JPEG, or SVG files.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null || userId.isEmpty) {
        throw StateError('No authenticated user for logo upload.');
      }

      final bytes = await _readFileBytes(file);
      if (bytes.isEmpty) {
        throw StateError('Selected image file is empty.');
      }

      final normalizedName = _sanitizeFileName(file.name);
      final storagePath =
          '$userId/${DateTime.now().millisecondsSinceEpoch}_$normalizedName';

      final contentType = file.type.trim().isNotEmpty
          ? file.type.trim()
          : _detectMimeTypeFromFileName(file.name);

      await Supabase.instance.client.storage
          .from(_reportIdentityLogoBucket)
          .uploadBinary(
            storagePath,
            bytes,
            fileOptions: FileOptions(
              upsert: true,
              contentType: contentType,
            ),
          );

      final previousStoragePath = _organizationLogoStoragePath;
      final isSvg = _isSvgFileName(file.name);
      String? svgString;
      Uint8List? imageBytes;

      if (isSvg) {
        final decodedSvg = utf8.decode(bytes, allowMalformed: true).trim();
        if (decodedSvg.isEmpty) {
          throw StateError('Unable to read SVG file.');
        }
        svgString = decodedSvg;
      } else {
        imageBytes = bytes;
      }

      if (!mounted) return;
      setState(() {
        _organizationLogoSvg = svgString;
        _organizationLogoBytes = imageBytes;
        _organizationLogoFileName = file.name;
        _organizationLogoStoragePath = storagePath;
      });

      if (previousStoragePath != null &&
          previousStoragePath.isNotEmpty &&
          previousStoragePath != storagePath) {
        unawaited(_deleteLogoFromStorage(previousStoragePath));
      }

      _syncReportIdentityWarningState(notifyParent: true, rebuild: false);
      _schedulePersistReportIdentitySettings();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to upload logo: $error'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _removeOrganizationLogo() {
    final previousStoragePath = _organizationLogoStoragePath;
    setState(() {
      _organizationLogoBytes = null;
      _organizationLogoSvg = null;
      _organizationLogoFileName = null;
      _organizationLogoStoragePath = null;
    });
    _syncReportIdentityWarningState(notifyParent: true, rebuild: false);
    _schedulePersistReportIdentitySettings();
    if (previousStoragePath != null && previousStoragePath.isNotEmpty) {
      unawaited(_deleteLogoFromStorage(previousStoragePath));
    }
  }

  Widget _buildOrganizationLogo({
    required double width,
    required double height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  }) {
    if (_organizationLogoSvg != null &&
        _organizationLogoSvg!.trim().isNotEmpty) {
      return SvgPicture.string(
        _organizationLogoSvg!,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );
    }
    if (_organizationLogoBytes != null && _organizationLogoBytes!.isNotEmpty) {
      return Image.memory(
        _organizationLogoBytes!,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );
    }
    return const SizedBox.shrink();
  }

  List<BoxShadow> get _primaryControlShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.25),
          blurRadius: 2,
          offset: const Offset(0, 0),
        ),
      ];

  Future<void> _handleLogout() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to logout: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (context) =>
            kIsWeb ? const UnauthenticatedPage() : const LoginPage(),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final isCompact = screenWidth < 768;
        final scaleMetrics = AppScaleMetrics.of(context);
        final extraRightWidth = scaleMetrics?.rightOverflowWidth ?? 0.0;

        final user = Supabase.instance.client.auth.currentUser;
        final userEmail = user?.email?.trim().isNotEmpty == true
            ? user!.email!.trim()
            : 'landmanpro@login.com';

        final horizontalPadding = isCompact ? 16.0 : 24.0;

        return Container(
          color: Colors.white,
          child: Align(
            alignment: Alignment.topLeft,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: horizontalPadding),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Account Settings',
                            style: GoogleFonts.inter(
                              fontSize: isCompact ? 30 : 32,
                              fontWeight: FontWeight.w600,
                              color: Colors.black,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Manage your account information and security',
                            style: GoogleFonts.inter(
                              fontSize: isCompact ? 18 : 20,
                              fontWeight: FontWeight.w400,
                              color: Colors.black.withValues(alpha: 0.8),
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 32,
                      child: Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: 0,
                            right: -extraRightWidth,
                            bottom: 0,
                            child: Container(
                              height: 0.5,
                              color: const Color(0xFF5C5C5C),
                            ),
                          ),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                SizedBox(width: horizontalPadding),
                                _buildTabItem(
                                  label: 'Login Details',
                                  isActive: _selectedTab ==
                                      _AccountSettingsTab.loginDetails,
                                  showWarningBadge: false,
                                  onTap: () {
                                    _setSelectedTab(
                                        _AccountSettingsTab.loginDetails);
                                  },
                                ),
                                const SizedBox(width: 36),
                                _buildTabItem(
                                  label: 'Report Identity Settings',
                                  isActive: _selectedTab ==
                                      _AccountSettingsTab
                                          .reportIdentitySettings,
                                  showWarningBadge: _hasReportIdentityWarnings,
                                  onTap: () {
                                    _setSelectedTab(
                                      _AccountSettingsTab
                                          .reportIdentitySettings,
                                    );
                                  },
                                ),
                                SizedBox(width: horizontalPadding),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                    Padding(
                      padding: EdgeInsets.only(
                        left: horizontalPadding,
                        right: horizontalPadding,
                      ),
                      child: _selectedTab == _AccountSettingsTab.loginDetails
                          ? _buildLoginDetailsContent(
                              context,
                              userEmail: userEmail,
                              isCompact: isCompact,
                            )
                          : _buildReportIdentityContent(
                              context,
                              isCompact: isCompact,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabItem({
    required String label,
    required bool isActive,
    required bool showWarningBadge,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Container(
        height: 32,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isActive ? const Color(0xFF0C8CE9) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                color: isActive
                    ? const Color(0xFF0C8CE9)
                    : const Color(0xFF858585),
                height: 20 / 14,
              ),
            ),
            if (showWarningBadge)
              Positioned(
                top: -13,
                child: SvgPicture.asset(
                  'assets/images/Warning.svg',
                  width: 17,
                  height: 15,
                  fit: BoxFit.contain,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWarningAwareField({
    required String label,
    required String hintText,
    required TextEditingController controller,
    required FocusNode focusNode,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: _primaryControlShadow,
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            textAlignVertical: TextAlignVertical.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black.withValues(alpha: 0.75),
              height: 1.0,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: hintText,
              hintStyle: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFFADADAD).withValues(alpha: 0.75),
                height: 1.0,
              ),
              contentPadding: const EdgeInsets.only(
                left: 12,
                right: 12,
                top: 16,
                bottom: 6,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginDetailsContent(
    BuildContext context, {
    required String userEmail,
    required bool isCompact,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: isCompact ? double.infinity : 503,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration.copyWith(
            color: const Color(0xFFF8F9FA),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Email Address',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 40,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: _primaryControlShadow,
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  userEmail,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black.withValues(alpha: 0.75),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: _primaryControlShadow,
                  ),
                  child: TextButton(
                    onPressed: _handleLogout,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF0C8CE9),
                      backgroundColor: Colors.transparent,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      'Log Out',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFF0C8CE9),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReportIdentityContent(
    BuildContext context, {
    required bool isCompact,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const reportDetailsCardWidth = 616.0;
        const previewCardWidth = 484.0;
        const cardsGap = 40.0;
        final useColumnLayout = isCompact ||
            constraints.maxWidth <
                (reportDetailsCardWidth + previewCardWidth + cardsGap);

        if (useColumnLayout) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildReportDetailsCard(width: double.infinity),
              const SizedBox(height: 24),
              _buildPreviewCard(width: double.infinity, minHeight: 609),
            ],
          );
        }

        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildReportDetailsCard(width: reportDetailsCardWidth),
              const SizedBox(width: cardsGap),
              _buildPreviewCard(
                width: previewCardWidth,
                minHeight: 609,
                expandToParentHeight: true,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReportDetailsCard({required double width}) {
    final hasLogo = _hasUploadedOrganizationLogo;

    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration.copyWith(
        color: const Color(0xFFF8F9FA),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Report Details',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Configure your identity details that will be displayed on report covers.',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 24),
          _buildWarningAwareField(
            label: 'Full Name',
            hintText: 'Name displayed on report cover.',
            controller: _fullNameController,
            focusNode: _fullNameFocusNode,
          ),
          const SizedBox(height: 16),
          _buildWarningAwareField(
            label: 'Organization',
            hintText: 'Company or firm generating the report.',
            controller: _organizationController,
            focusNode: _organizationFocusNode,
          ),
          const SizedBox(height: 16),
          _buildWarningAwareField(
            label: 'Role',
            hintText: 'Example: Accountant, CA, Broker.',
            controller: _roleController,
            focusNode: _roleFocusNode,
          ),
          const SizedBox(height: 16),
          Text(
            'Organization Logo',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Upload organization logo for reports (maximum dimensions: 100px width × 50px height).',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: Colors.black.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: 200,
            height: 100,
            decoration: BoxDecoration(
              color: hasLogo ? Colors.white : const Color(0xFFD9D9D9),
              boxShadow: [
                BoxShadow(
                  color: hasLogo
                      ? Colors.black.withValues(alpha: 0.25)
                      : const Color(0xFFFFFB00),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: hasLogo
                ? ClipRect(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: SizedBox.expand(
                        child: _buildOrganizationLogo(
                          width: 184,
                          height: 84,
                          fit: BoxFit.contain,
                          alignment: Alignment.center,
                        ),
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 16),
          if (!hasLogo) ...[
            SizedBox(
              height: 36,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
                child: TextButton(
                  onPressed: _pickOrganizationLogo,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF0C8CE9),
                    backgroundColor: Colors.transparent,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Upload Organization Logo',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF0C8CE9),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.file_upload_outlined,
                        color: Color(0xFF0C8CE9),
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'PNG, JPG, SVG',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: Colors.black.withValues(alpha: 0.8),
              ),
            ),
          ] else ...[
            SizedBox(
              height: 36,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: _primaryControlShadow,
                ),
                child: TextButton(
                  onPressed: _removeOrganizationLogo,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF0000),
                    backgroundColor: Colors.transparent,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    'Remove',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: const Color(0xFFFF0000),
                    ),
                  ),
                ),
              ),
            ),
            if (_organizationLogoFileName != null) ...[
              const SizedBox(height: 4),
              Text(
                _organizationLogoFileName!,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Colors.black.withValues(alpha: 0.55),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildPreviewCard({
    required double width,
    required double minHeight,
    bool expandToParentHeight = false,
  }) {
    return Container(
      width: width,
      height: expandToParentHeight ? double.infinity : null,
      constraints: BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration.copyWith(
        color: const Color(0xFFF8F9FA),
      ),
      child: Column(
        children: [
          Text(
            'Preview',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: 380,
            height: 538,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildDotPattern(rows: 4),
                    const SizedBox(height: 16),
                    Container(
                      height: 1,
                      color: const Color(0xFF404040),
                    ),
                    const SizedBox(height: 10.22),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Project Summary\n',
                            style: GoogleFonts.inriaSerif(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              color: Colors.black,
                              height: 1.2,
                            ),
                          ),
                          TextSpan(
                            text: 'Report',
                            style: GoogleFonts.inriaSerif(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF0C8CE9),
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 25.56),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Project:',
                          style: GoogleFonts.inriaSerif(
                            fontSize: 15.34,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF404040),
                          ),
                        ),
                        const SizedBox(width: 5.11),
                        const Expanded(
                          child: SizedBox(height: 42.17),
                        ),
                      ],
                    ),
                    const SizedBox(height: 25.56),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Project Location:',
                          style: GoogleFonts.inriaSerif(
                            fontSize: 8.95,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF404040),
                          ),
                        ),
                        const SizedBox(width: 5.11),
                        const Expanded(
                          child: SizedBox(height: 58.78),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5.11),
                    Container(
                      width: 63.9,
                      height: 31.95,
                      color: Colors.white,
                      alignment: Alignment.centerLeft,
                      child: _hasUploadedOrganizationLogo
                          ? Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2),
                              child: _buildOrganizationLogo(
                                width: 60,
                                height: 28,
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 5.11),
                    Text(
                      'By: ${_fullNameController.text.isEmpty ? '' : _fullNameController.text}',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 8.95,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFF404040),
                      ),
                    ),
                    const SizedBox(height: 5.11),
                    Text(
                      'Organization: ${_organizationController.text.isEmpty ? '' : _organizationController.text}',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 8.95,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFF404040),
                      ),
                    ),
                    const SizedBox(height: 5.11),
                    Text(
                      'Role: ${_roleController.text.isEmpty ? '' : _roleController.text}',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 8.95,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFF404040),
                      ),
                    ),
                    const SizedBox(height: 5.11),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Generated On:',
                          style: GoogleFonts.inriaSerif(
                            fontSize: 8.95,
                            fontWeight: FontWeight.w400,
                            color: const Color(0xFF404040),
                          ),
                        ),
                        const SizedBox(width: 5.11),
                        Text(
                          'DD/MM/YYYY',
                          style: GoogleFonts.inriaSerif(
                            fontSize: 8.95,
                            fontWeight: FontWeight.w400,
                            color: const Color(0xFF404040),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 20,
                  ),
                  color: const Color(0x0A404040),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 1,
                        color: const Color(0xFF0C8CE9),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildFooterDotPattern(),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SvgPicture.asset(
                                'assets/images/8answers.svg',
                                width: 71,
                                height: 14,
                                fit: BoxFit.contain,
                              ),
                              const SizedBox(height: 3),
                              RichText(
                                text: TextSpan(
                                  style: GoogleFonts.inriaSerif(
                                    fontSize: 6.4,
                                    fontWeight: FontWeight.w400,
                                    height: 1.15,
                                  ),
                                  children: const [
                                    TextSpan(
                                      text: 'Generated using',
                                      style: TextStyle(
                                        color: Colors.black,
                                      ),
                                    ),
                                    TextSpan(
                                      text: ' 8Answers',
                                      style: TextStyle(
                                        color: Color(0xFF0C8CE9),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                'www.8answers.com',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 6.4,
                                  fontWeight: FontWeight.w400,
                                  color: const Color(0xFF0C8CE9),
                                  height: 1.15,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDotPattern({required int rows}) {
    return Column(
      children: List.generate(rows, (rowIndex) {
        return Padding(
          padding: EdgeInsets.only(bottom: rowIndex == rows - 1 ? 0 : 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(16, (_) {
              return Container(
                width: 1.4,
                height: 1.4,
                decoration: const BoxDecoration(
                  color: Color(0xFF404040),
                  shape: BoxShape.circle,
                ),
              );
            }),
          ),
        );
      }),
    );
  }

  Widget _buildFooterDotPattern() {
    const dotSize = 1.3;
    const dotGap = 20.4;
    const rowGap = 10.2;
    const columns = 10;
    const rows = 4;

    return Column(
      children: List.generate(rows, (rowIndex) {
        return Padding(
          padding: EdgeInsets.only(bottom: rowIndex == rows - 1 ? 0 : rowGap),
          child: Row(
            children: List.generate(columns, (colIndex) {
              return Padding(
                padding: EdgeInsets.only(
                    right: colIndex == columns - 1 ? 0 : dotGap),
                child: Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: const BoxDecoration(
                    color: Color(0xFF404040),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          ),
        );
      }),
    );
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 2,
            offset: const Offset(0, 0),
          ),
        ],
      );
}
