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

class ProjectSaveStatus extends StatefulWidget {
  final ProjectSaveStatusType status;
  final String? savedTimeAgo; // e.g., "2 minutes ago"

  const ProjectSaveStatus({
    super.key,
    required this.status,
    this.savedTimeAgo,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Saving...',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: const Color(0xFF0C8CE9),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Please keep this page open',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: const Color(0xFF5C5C5C),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectionLostStatus() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Saving... • Low network',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.red,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Retrying automatically',
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

  Widget _buildQueuedOfflineStatus() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Queued Offline',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFFD97706),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Will sync automatically when online',
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
        const Icon(
          Icons.cloud_off,
          size: 16,
          color: Color(0xFFD97706),
        ),
      ],
    );
  }
}
