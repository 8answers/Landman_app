import 'package:flutter/material.dart';
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
    switch (widget.visualOverride) {
      case ProjectSaveStatusVisualOverride.savedLocallyOnlineNoShare:
        return _buildSavedLocallyOnlineNoShareStatus();
      case ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced:
        return _buildSavedLocallyOfflineSharedNotSyncedStatus();
      case ProjectSaveStatusVisualOverride.syncingInProgressShared:
        return _buildSyncingInProgressSharedStatus();
      case ProjectSaveStatusVisualOverride.savedAndSyncedShared:
        return _buildSavedAndSyncedSharedStatus();
      case ProjectSaveStatusVisualOverride.none:
        break;
    }

    switch (widget.status) {
      case ProjectSaveStatusType.saved:
        return _buildSavedStatus();
      case ProjectSaveStatusType.notSaved:
        return _buildNotSavedStatus();
      case ProjectSaveStatusType.loading:
        return _buildLoadingStatus();
      case ProjectSaveStatusType.saving:
        return _buildSavingStatus();
      case ProjectSaveStatusType.connectionLost:
        return _buildConnectionLostStatus();
      case ProjectSaveStatusType.queuedOffline:
        return _buildQueuedOfflineStatus();
    }
  }

  Widget _buildSavedStatus() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Project Saved ✓',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: const Color(0xFF06AB00),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.savedTimeAgo ?? '2 minutes ago',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: const Color(0xFF5C5C5C),
          ),
        ),
      ],
    );
  }

  Widget _buildNotSavedStatus() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Not saved',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: const Color(0xFFD97706),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Recent edits pending save',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: const Color(0xFF5C5C5C),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingStatus() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Loading',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF0C8CE9),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Fetching latest data',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
            ],
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
    );
  }

  Widget _buildSavingStatus() {
    return _buildOfflineSavingVisual();
  }

  Widget _buildOfflineSavingVisual() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
    );
  }

  Widget _buildConnectionLostStatus() {
    return _buildOfflineSavingVisual();
  }

  Widget _buildSlashedStatusIcon(IconData iconData) {
    return SizedBox(
      width: 16,
      height: 16,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Icon(
            iconData,
            size: 15,
            color: const Color(0xFF111111),
          ),
          Transform.rotate(
            angle: -0.72,
            child: Container(
              width: 1.6,
              height: 15,
              decoration: BoxDecoration(
                color: const Color(0xFFE53935),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ],
      ),
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
          _buildSlashedStatusIcon(Icons.wifi),
          const SizedBox(width: 6),
          _buildSlashedStatusIcon(Icons.cloud_outlined),
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
          const Icon(
            Icons.wifi,
            size: 15,
            color: Color(0xFF111111),
          ),
          const SizedBox(width: 6),
          _buildSlashedStatusIcon(Icons.cloud_outlined),
        ],
      ),
    );
  }

  Widget _buildSyncingProgressIndicators() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: const [
        Icon(
          Icons.wifi,
          size: 15,
          color: Color(0xFF111111),
        ),
        SizedBox(width: 8),
        Icon(
          Icons.cloud_upload_outlined,
          size: 17,
          color: Color(0xFF0C8CE9),
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
          const Icon(
            Icons.wifi,
            size: 15,
            color: Color(0xFF111111),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 20,
            height: 16,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                const Icon(
                  Icons.cloud_outlined,
                  size: 16,
                  color: Color(0xFF111111),
                ),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: Color(0xFF06AB00),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      size: 7,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedLocallyOnlineNoShareStatus() {
    return Row(
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
    );
  }

  Widget _buildSyncingInProgressSharedStatus() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Saved Locally',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: const Color(0xFF06AB00),
            height: 1.0,
          ),
        ),
        const SizedBox(height: 6),
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
            _buildSyncingProgressIndicators(),
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
    );
  }

  Widget _buildSavedLocallyOfflineSharedNotSyncedStatus() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Saved Locally',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: const Color(0xFF06AB00),
            height: 1.0,
          ),
        ),
        const SizedBox(height: 6),
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
    );
  }

  Widget _buildSavedAndSyncedSharedStatus() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
        const SizedBox(height: 2),
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
    );
  }

  Widget _buildQueuedOfflineStatus() {
    return Row(
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
    );
  }
}
