import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

typedef NoInternetActionCallback = FutureOr<void> Function();

class _NoInternetMessageLine {
  const _NoInternetMessageLine({
    required this.text,
    this.isEmphasis = false,
  });

  final String text;
  final bool isEmphasis;
}

class _NoInternetDialogAction {
  const _NoInternetDialogAction({
    required this.label,
    required this.onTap,
    this.leadingAssetPath,
    this.backgroundColor = Colors.white,
    this.labelColor = const Color(0xFF0C8CE9),
    this.width,
    this.labelFontSize = 14,
  });

  final String label;
  final NoInternetActionCallback onTap;
  final String? leadingAssetPath;
  final Color backgroundColor;
  final Color labelColor;
  final double? width;
  final double labelFontSize;
}

Future<void> showSharedProjectOfflineDialog({
  required BuildContext context,
  required NoInternetActionCallback onRecentProjects,
  required NoInternetActionCallback onRetry,
}) {
  return _showNoInternetDialog(
    context: context,
    messageLines: const <_NoInternetMessageLine>[
      _NoInternetMessageLine(text: 'You are offline.'),
      _NoInternetMessageLine(
        text: 'An internet connection is required to view this shared project.',
      ),
    ],
    leftAction: _NoInternetDialogAction(
      label: 'Recent Projects',
      leadingAssetPath: 'assets/images/Back_doc.svg',
      labelFontSize: 16,
      width: 243,
      onTap: onRecentProjects,
    ),
    rightAction: _NoInternetDialogAction(
      label: 'Retry',
      leadingAssetPath: 'assets/images/Refresh.svg',
      backgroundColor: const Color(0xFF0C8CE9),
      labelColor: Colors.white,
      width: 92,
      onTap: onRetry,
    ),
  );
}

Future<void> showProjectSyncRiskOfflineDialog({
  required BuildContext context,
  required NoInternetActionCallback onRecentProjects,
  required NoInternetActionCallback onRetry,
}) {
  return _showNoInternetDialog(
    context: context,
    messageLines: const <_NoInternetMessageLine>[
      _NoInternetMessageLine(text: 'You are offline.'),
      _NoInternetMessageLine(
        text: 'An internet connection is required to view this project.',
      ),
      _NoInternetMessageLine(
        text: 'Your connection is too weak to sync reliably.',
      ),
      _NoInternetMessageLine(
        text:
            'Un-synced changes may be at risk if you close the app before syncing completes.',
        isEmphasis: true,
      ),
      _NoInternetMessageLine(text: 'Please connect to continue.'),
    ],
    leftAction: _NoInternetDialogAction(
      label: 'Recent Projects',
      leadingAssetPath: 'assets/images/Back_doc.svg',
      labelFontSize: 16,
      width: 243,
      onTap: onRecentProjects,
    ),
    rightAction: _NoInternetDialogAction(
      label: 'Retry',
      leadingAssetPath: 'assets/images/Refresh.svg',
      backgroundColor: const Color(0xFF0C8CE9),
      labelColor: Colors.white,
      width: 92,
      onTap: onRetry,
    ),
  );
}

Future<void> showUploadRequiresInternetDialog({
  required BuildContext context,
  required NoInternetActionCallback onRetry,
  NoInternetActionCallback? onCancel,
}) {
  return _showNoInternetDialog(
    context: context,
    messageLines: const <_NoInternetMessageLine>[
      _NoInternetMessageLine(
        text: 'Documents can only be uploaded when you\'re online.',
      ),
      _NoInternetMessageLine(text: 'Your file has not been uploaded.'),
    ],
    leftAction: _NoInternetDialogAction(
      label: 'Cancel',
      labelColor: const Color(0x80FF0000),
      width: 80,
      onTap: onCancel ?? () {},
    ),
    rightAction: _NoInternetDialogAction(
      label: 'Retry',
      leadingAssetPath: 'assets/images/Refresh.svg',
      width: 92,
      onTap: onRetry,
    ),
  );
}

Future<void> _showNoInternetDialog({
  required BuildContext context,
  required List<_NoInternetMessageLine> messageLines,
  required _NoInternetDialogAction leftAction,
  required _NoInternetDialogAction rightAction,
}) async {
  final media = MediaQuery.of(context);
  final maxWidth = math.min(595.0, media.size.width - 24);

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'No internet',
    barrierColor: Colors.black.withValues(alpha: 0.12),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (dialogContext, _, __) {
      return SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: maxWidth,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FA),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 2,
                      offset: Offset(0, 0),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SvgPicture.asset(
                          'assets/images/No_network.svg',
                          width: 18,
                          height: 16,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            'No Internet Connection',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => Navigator.of(dialogContext).pop(),
                          child: SizedBox(
                            width: 22.627,
                            height: 22.627,
                            child: Center(
                              child: SvgPicture.asset(
                                'assets/images/cross.svg',
                                width: 13,
                                height: 13,
                                colorFilter: const ColorFilter.mode(
                                  Color(0xFF0C8CE9),
                                  BlendMode.srcIn,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ...messageLines.map(
                      (line) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          line.text,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: line.isEmphasis
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: line.isEmphasis
                                ? Colors.black
                                : Colors.black.withValues(alpha: 0.8),
                            height: 1.25,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildDialogActionButton(
                          dialogContext: dialogContext,
                          action: leftAction,
                        ),
                        _buildDialogActionButton(
                          dialogContext: dialogContext,
                          action: rightAction,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

Widget _buildDialogActionButton({
  required BuildContext dialogContext,
  required _NoInternetDialogAction action,
}) {
  final buttonWidth = action.width ?? 0;
  final useCompactSpacing = buttonWidth > 0 && buttonWidth <= 92;
  final horizontalPadding = useCompactSpacing ? 14.0 : 16.0;
  final iconTextSpacing = useCompactSpacing ? 6.0 : 8.0;

  return Container(
    width: action.width,
    height: 44,
    decoration: BoxDecoration(
      color: action.backgroundColor,
      borderRadius: BorderRadius.circular(8),
      boxShadow: const [
        BoxShadow(
          color: Color(0x40000000),
          blurRadius: 2,
          offset: Offset(0, 0),
        ),
      ],
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          Navigator.of(dialogContext).pop();
          await action.onTap();
        },
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 4,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (action.leadingAssetPath != null) ...[
                SvgPicture.asset(
                  action.leadingAssetPath!,
                  width: 16,
                  height: 16,
                  colorFilter: ColorFilter.mode(
                    action.labelColor,
                    BlendMode.srcIn,
                  ),
                ),
                SizedBox(width: iconTextSpacing),
              ],
              Text(
                action.label,
                style: GoogleFonts.inter(
                  fontSize: action.labelFontSize,
                  fontWeight: FontWeight.w400,
                  color: action.labelColor,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
