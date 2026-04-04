import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

enum ProjectSaveStatusType {
  saved,
  notSaved,
  loading,
  saving,
  connectionLost,
  queuedOffline,
}

enum ProjectSaveStatusVisualOverride {
  none,
  savedLocallyOnlineNoShare,
  savedLocallyOfflineSharedNotSynced,
  documentsOfflineNoNetwork,
  savingPoorConnection,
  saveFailedPoorConnection,
  syncingInProgressShared,
  savedAndSyncedShared,
}

class ProjectSaveStatus extends StatefulWidget {
  final ProjectSaveStatusType status;
  final String? savedTimeAgo; // e.g., "2 minutes ago"
  final ProjectSaveStatusVisualOverride visualOverride;

  const ProjectSaveStatus({
    super.key,
    required this.status,
    this.savedTimeAgo,
    this.visualOverride = ProjectSaveStatusVisualOverride.none,
  });

  @override
  State<ProjectSaveStatus> createState() => _ProjectSaveStatusState();
}

class _ProjectSaveStatusState extends State<ProjectSaveStatus>
    with SingleTickerProviderStateMixin {
  static const double _statusWidth = 213;
  static const double _statusHeight = 84;
  static const double _statusPartGap = 16;

  static const String _networkSavedAsset = 'assets/images/Network_saved.svg';
  static const String _networkAsset = 'assets/images/Network.svg';
  static const String _noNetworkAsset = 'assets/images/No_network.svg';
  static const String _noSyncAsset = 'assets/images/No_sync.svg';
  static const String _savedAndSyncedAsset =
      'assets/images/savedd_and_sync.svg';
  static const String _syncingAsset = 'assets/images/Syncing.svg';
  static const String _poorNetworkAsset = 'assets/images/Poor_network.svg';
  static const String _poorSyncAsset = 'assets/images/Poor_sync.svg';

  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget statusContent;
    switch (widget.visualOverride) {
      case ProjectSaveStatusVisualOverride.savedLocallyOnlineNoShare:
        statusContent = _buildSavedLocallyOnlineNoShareStatus();
        break;
      case ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced:
        statusContent = _buildSavedLocallyOfflineSharedNotSyncedStatus();
        break;
      case ProjectSaveStatusVisualOverride.documentsOfflineNoNetwork:
        statusContent = _buildDocumentsOfflineNoNetworkStatus();
        break;
      case ProjectSaveStatusVisualOverride.savingPoorConnection:
        statusContent = _buildSavingPoorConnectionStatus();
        break;
      case ProjectSaveStatusVisualOverride.saveFailedPoorConnection:
        statusContent = _buildSaveFailedPoorConnectionStatus();
        break;
      case ProjectSaveStatusVisualOverride.syncingInProgressShared:
        statusContent = _buildSyncingInProgressSharedStatus();
        break;
      case ProjectSaveStatusVisualOverride.savedAndSyncedShared:
        statusContent = _buildSavedAndSyncedSharedStatus();
        break;
      case ProjectSaveStatusVisualOverride.none:
        switch (widget.status) {
          case ProjectSaveStatusType.saved:
            statusContent = _buildSavedStatus();
            break;
          case ProjectSaveStatusType.notSaved:
            statusContent = _buildNotSavedStatus();
            break;
          case ProjectSaveStatusType.loading:
            statusContent = _buildLoadingStatus();
            break;
          case ProjectSaveStatusType.saving:
            statusContent = _buildSavingStatus();
            break;
          case ProjectSaveStatusType.connectionLost:
            statusContent = _buildConnectionLostStatus();
            break;
          case ProjectSaveStatusType.queuedOffline:
            statusContent = _buildQueuedOfflineStatus();
            break;
        }
        break;
    }

    return SizedBox(
      width: _statusWidth,
      height: _statusHeight,
      child: Align(
        alignment: Alignment.topLeft,
        child: statusContent,
      ),
    );
  }

  Widget _buildSinglePartStatus(Widget part) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [part],
    );
  }

  Widget _buildTwoPartStatus({
    required Widget firstPart,
    required Widget secondPart,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        firstPart,
        const SizedBox(height: _statusPartGap),
        secondPart,
      ],
    );
  }

  Widget _buildSavedStatus() {
    return _buildTwoPartStatus(
      firstPart: Text(
        'Project Saved ✓',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          color: const Color(0xFF06AB00),
        ),
      ),
      secondPart: Text(
        widget.savedTimeAgo ?? '2 minutes ago',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          color: const Color(0xFF5C5C5C),
        ),
      ),
    );
  }

  Widget _buildNotSavedStatus() {
    return _buildTwoPartStatus(
      firstPart: Text(
        'Not saved',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          color: const Color(0xFFD97706),
        ),
      ),
      secondPart: Text(
        'Recent edits pending save',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          color: const Color(0xFF5C5C5C),
        ),
      ),
    );
  }

  Widget _buildLoadingStatus() {
    return _buildTwoPartStatus(
      firstPart: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Loading',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF0C8CE9),
            ),
          ),
          const SizedBox(width: 8),
          RotationTransition(
            turns: _rotationController,
            child: const Icon(
              Icons.refresh,
              size: 16,
              color: Color(0xFF0C8CE9),
            ),
          ),
        ],
      ),
      secondPart: Text(
        'Fetching latest data',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          color: const Color(0xFF5C5C5C),
        ),
      ),
    );
  }

  Widget _buildSavingStatus() {
    return _buildOfflineSavingVisual();
  }

  Widget _buildOfflineSavingVisual() {
    return _buildTwoPartStatus(
      firstPart: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              'Saving...',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF0C8CE9),
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 2),
          _buildOfflineStatusIndicators(),
        ],
      ),
      secondPart: Text(
        'Please keep this page open',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: const Color(0xFF5C5C5C),
          height: 1.0,
        ),
      ),
    );
  }

  Widget _buildConnectionLostStatus() {
    return _buildOfflineSavingVisual();
  }

  Widget _buildStatusIconAsset(
    String assetPath, {
    required double width,
    required double height,
  }) {
    return SvgPicture.asset(
      assetPath,
      width: width,
      height: height,
      fit: BoxFit.contain,
    );
  }

  Widget _buildOfflineStatusIndicators() {
    return SizedBox(
      width: 46,
      height: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _buildStatusIconAsset(
            _noNetworkAsset,
            width: 18,
            height: 16,
          ),
          const SizedBox(width: 6),
          _buildStatusIconAsset(
            _noSyncAsset,
            width: 20,
            height: 16,
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineStatusIndicatorsWifiOnCloudOff() {
    return SizedBox(
      width: 46,
      height: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _buildStatusIconAsset(
            _networkAsset,
            width: 18,
            height: 16,
          ),
          const SizedBox(width: 6),
          _buildStatusIconAsset(
            _noSyncAsset,
            width: 20,
            height: 16,
          ),
        ],
      ),
    );
  }

  Widget _buildSyncingProgressIndicators() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildStatusIconAsset(
          _networkAsset,
          width: 18,
          height: 16,
        ),
        const SizedBox(width: 8),
        _buildStatusIconAsset(
          _syncingAsset,
          width: 20,
          height: 16,
        ),
      ],
    );
  }

  Widget _buildSyncedIndicators() {
    return SizedBox(
      width: 48,
      height: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildStatusIconAsset(
            _networkSavedAsset,
            width: 18,
            height: 16,
          ),
          const SizedBox(width: 8),
          _buildStatusIconAsset(
            _savedAndSyncedAsset,
            width: 22,
            height: 16,
          ),
        ],
      ),
    );
  }

  Widget _buildPoorConnectionIndicators() {
    return SizedBox(
      height: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildStatusIconAsset(
            _poorNetworkAsset,
            width: 9,
            height: 8,
          ),
          const SizedBox(width: 8),
          _buildStatusIconAsset(
            _poorSyncAsset,
            width: 20,
            height: 16,
          ),
        ],
      ),
    );
  }

  Widget _buildSavedLocallyOnlineNoShareStatus() {
    return _buildSinglePartStatus(
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              'Saved Locally',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF06AB00),
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildOfflineStatusIndicatorsWifiOnCloudOff(),
        ],
      ),
    );
  }

  Widget _buildSyncingInProgressSharedStatus() {
    return _buildTwoPartStatus(
      firstPart: Text(
        'Saved Locally',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: const Color(0xFF06AB00),
          height: 1.0,
        ),
      ),
      secondPart: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Syncing in Progress',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: const Color(0xFF0C8CE9),
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              _buildPoorConnectionIndicators(),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Uploading your latest changes...',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedLocallyOfflineSharedNotSyncedStatus() {
    return _buildTwoPartStatus(
      firstPart: Text(
        'Saved Locally',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: const Color(0xFF06AB00),
          height: 1.0,
        ),
      ),
      secondPart: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '(Not Synced Yet)',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: const Color(0xFFE53935),
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              _buildOfflineStatusIndicators(),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'No internet connection',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentsOfflineNoNetworkStatus() {
    return _buildTwoPartStatus(
      firstPart: Text(
        'Saved Locally',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: const Color(0xFF06AB00),
          height: 1.0,
        ),
      ),
      secondPart: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'No Network',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: const Color(0xFFE53935),
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              _buildOfflineStatusIndicators(),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Upload & edit requires internet',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavingPoorConnectionStatus() {
    return _buildTwoPartStatus(
      firstPart: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saving...',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF0C8CE9),
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Please keep this page open',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
      secondPart: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Poor Connection',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: const Color(0xFFE53935),
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              _buildPoorConnectionIndicators(),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Sync may be delayed',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveFailedPoorConnectionStatus() {
    return _buildTwoPartStatus(
      firstPart: Text(
        'Saved Locally',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: const Color(0xFF06AB00),
          height: 1.0,
        ),
      ),
      secondPart: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Poor Connection',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: const Color(0xFFE53935),
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              _buildSyncingProgressIndicators(),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Sync may be delayed',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedAndSyncedSharedStatus() {
    return _buildTwoPartStatus(
      firstPart: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'Saved & Synced',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF06AB00),
              height: 1.0,
            ),
          ),
          const SizedBox(width: 8),
          _buildSyncedIndicators(),
        ],
      ),
      secondPart: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'All data is up to date.',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            widget.savedTimeAgo ?? 'Just now',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueuedOfflineStatus() {
    return _buildSinglePartStatus(
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              'Saved Locally',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF06AB00),
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildOfflineStatusIndicators(),
        ],
      ),
    );
  }
}
