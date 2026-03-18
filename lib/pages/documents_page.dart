import 'dart:async';
import 'dart:convert';
import 'dart:math' show max, min, pi;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;
import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/app_scale_metrics.dart';

class DocumentsPage extends StatefulWidget {
  final String? projectId;
  final int dataVersion;

  const DocumentsPage({
    super.key,
    this.projectId,
    this.dataVersion = 0,
  });

  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

// Upload progress model
class _UploadProgress {
  final String id;
  final String fileName;
  final String extension;
  final String? parentId;
  double progress;
  bool isCanceled;
  bool isCompleted;
  bool isFailed;
  html.File? file;

  _UploadProgress({
    required this.id,
    required this.fileName,
    required this.extension,
    this.parentId,
    this.progress = 0.0,
    this.isCanceled = false,
    this.isCompleted = false,
    this.isFailed = false,
    this.file,
  });
}

class _DocumentsPageState extends State<DocumentsPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  static const String _defaultExpensesFolderName = 'Expenses';
  static const String _defaultAmenityFolderName = 'Amenity Area';
  static const String _defaultLayoutsFolderName = 'Layouts';
  static const List<String> _pinnedRootFolderOrder = <String>[
    _defaultExpensesFolderName,
    _defaultAmenityFolderName,
    _defaultLayoutsFolderName,
  ];
  String _searchQuery = '';
  final List<Map<String, dynamic>> _documents = [];
  bool _isLoading = false;
  bool _showAddFolderDialog = false;
  String? _currentFolderId; // Track which folder we're currently viewing
  int? _nextId; // Auto-incrementing ID for documents/folders
  String?
      _newlyCreatedFolderId; // Track the folder that was just created for auto-rename
  String _sortOrder = 'default'; // 'default', 'created', 'updated'
  final GlobalKey _filterButtonKey = GlobalKey();
  final Map<String, _UploadProgress> _activeUploads =
      {}; // Track active uploads
  final List<Map<String, dynamic>> _completedUploads =
      []; // Track completed uploads
  bool _showUploadingPopup = false; // Control uploading popup visibility
  bool _showUploadedPopup = false; // Control uploaded popup visibility
  bool _isSelectMode = false; // Track if we're in select mode
  final Set<String> _selectedDocumentIds = {}; // Track selected document IDs
  bool _isLayoutImageViewerOpen = false;
  String _activeLayoutImageUrl = '';
  String _activeLayoutImageStoragePath = '';
  String _activeLayoutImageDocId = '';
  String _activeLayoutImageName = '';
  String _activeLayoutImageExtension = '';
  bool _isLayoutPenModeActive = true;
  bool _isLayoutEraserModeActive = false;
  bool _isLayoutPanModeActive = false;
  bool _isLayoutThicknessPickerVisible = false;
  bool _isLayoutThicknessPickerForEraser = false;
  int _selectedLayoutThicknessIndex = 1;
  int _selectedLayoutEraserThicknessIndex = 1;
  static const List<double> _layoutThicknessOptions = [1, 3, 5, 7];
  bool _isLayoutColorPickerVisible = false;
  int _selectedLayoutColorIndex = 0;
  static const List<Color> _layoutColorOptions = [
    Color(0xFF06AB00),
    Color(0xFFFF0000),
    Color(0xFF0C8CE9),
    Color(0xFFFFB12A),
  ];
  final List<_DocumentLayoutViewerStroke> _layoutViewerStrokes =
      <_DocumentLayoutViewerStroke>[];
  int? _activeLayoutStrokeIndex;
  int? _activeLayoutStrokePointerId;
  final ValueNotifier<int> _layoutViewerPaintVersion = ValueNotifier<int>(0);
  Size _layoutViewerLastCanvasSize = Size.zero;
  final TransformationController _layoutImageViewerController =
      TransformationController();
  bool _hasPendingLayoutViewerEdits = false;
  bool _isSavingLayoutViewerEdits = false;
  Timer? _layoutViewerAutosaveTimer;
  OverlayEntry? _layoutImageViewerOverlayEntry;
  bool _isDeletingLayoutViewerImage = false;

  Widget _skeletonBlock({required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE3E7EB),
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  Widget _buildDocumentsLoadingSkeleton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF8F9FA),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 2,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _skeletonBlock(width: 120, height: 36),
                const SizedBox(width: 24),
                _skeletonBlock(width: 140, height: 36),
                const SizedBox(width: 24),
                _skeletonBlock(width: 100, height: 36),
                const SizedBox(width: 24),
                Expanded(
                    child: _skeletonBlock(width: double.infinity, height: 36)),
              ],
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 24,
              runSpacing: 24,
              children: List.generate(
                8,
                (index) => Container(
                  width: 220,
                  height: 180,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _skeletonBlock(width: 88, height: 88),
                      const SizedBox(height: 12),
                      _skeletonBlock(width: 160, height: 14),
                      const SizedBox(height: 8),
                      _skeletonBlock(width: 120, height: 12),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentsActionRow(
    List<Map<String, dynamic>> documents,
    double extraTabLineWidth,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final actionRowWidth = constraints.maxWidth + extraTabLineWidth;
          const actionRowHeight = 36.0;
          return SizedBox(
            height: actionRowHeight,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: actionRowWidth,
              maxWidth: actionRowWidth,
              minHeight: actionRowHeight,
              maxHeight: actionRowHeight,
              child: SizedBox(
                width: actionRowWidth,
                height: actionRowHeight,
                child: Row(
                  children: [
                    _PrimaryActionButton(
                      label: 'Upload',
                      iconAssetPath: 'assets/images/Upload.svg',
                      onTap: _uploadDocuments,
                    ),
                    const SizedBox(width: 24),
                    _PrimaryActionButton(
                      label: 'Add Folder',
                      iconAssetPath: 'assets/images/Add_folder.svg',
                      onTap: _createFolder,
                    ),
                    const SizedBox(width: 24),
                    Opacity(
                      opacity: documents.isEmpty ? 0.5 : 1.0,
                      child: IgnorePointer(
                        ignoring: documents.isEmpty,
                        child: _SecondaryActionButton(
                          key: _filterButtonKey,
                          label: 'Filter',
                          leading: SvgPicture.asset(
                            'assets/images/Filter.svg',
                            width: 16,
                            height: 10,
                            colorFilter: const ColorFilter.mode(
                              Color(0xFF0C8CE9),
                              BlendMode.srcIn,
                            ),
                          ),
                          onTap: _filterDocuments,
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Opacity(
                      opacity: documents.isEmpty ? 0.5 : 1.0,
                      child: IgnorePointer(
                        ignoring: documents.isEmpty,
                        child: _SecondaryActionButton(
                          label: 'Download All',
                          trailing: SvgPicture.asset(
                            'assets/images/Download_all.svg',
                            width: 16,
                            height: 16,
                            colorFilter: const ColorFilter.mode(
                              Color(0xFF0C8CE9),
                              BlendMode.srcIn,
                            ),
                          ),
                          onTap: _downloadDocuments,
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Opacity(
                      opacity: documents.isEmpty ? 0.5 : 1.0,
                      child: IgnorePointer(
                        ignoring: documents.isEmpty,
                        child: _isSelectMode
                            ? _SecondaryActionButton(
                                label: 'Cancel',
                                trailing: SvgPicture.asset(
                                  'assets/images/cross.svg',
                                  width: 16,
                                  height: 16,
                                  colorFilter: const ColorFilter.mode(
                                    Color(0xFF0C8CE9),
                                    BlendMode.srcIn,
                                  ),
                                ),
                                onTap: () {
                                  setState(() {
                                    _exitSelectMode();
                                  });
                                },
                              )
                            : _SecondaryActionButton(
                                label: 'Select',
                                trailing: SvgPicture.asset(
                                  'assets/images/select.svg',
                                  width: 16,
                                  height: 16,
                                  colorFilter: const ColorFilter.mode(
                                    Color(0xFF0C8CE9),
                                    BlendMode.srcIn,
                                  ),
                                ),
                                onTap: () {
                                  setState(() => _isSelectMode = true);
                                },
                              ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Container(
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(color: Colors.black, width: 0.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 1.75,
                              offset: const Offset(0, 0),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: SvgPicture.asset(
                                'assets/images/Search_doc.svg',
                                width: 16,
                                height: 16,
                                colorFilter: const ColorFilter.mode(
                                  Colors.black,
                                  BlendMode.srcIn,
                                ),
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                onChanged: (value) =>
                                    setState(() => _searchQuery = value),
                                textAlignVertical: TextAlignVertical.center,
                                decoration: InputDecoration(
                                  hintText: 'Search Documents',
                                  hintStyle: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: Colors.black.withOpacity(0.5),
                                  ),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    _activeUploads.isNotEmpty
                        ? GestureDetector(
                            onTap: () => setState(() =>
                                _showUploadingPopup = !_showUploadingPopup),
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: Lottie.asset(
                                'assets/images/Animation - 1770546911567.json',
                                width: 24,
                                height: 24,
                                fit: BoxFit.contain,
                                repeat: true,
                                delegates: LottieDelegates(
                                  values: [
                                    ValueDelegate.color(
                                      const ["**"],
                                      value: const Color(0xFF0C8CE9),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        : (_completedUploads.isNotEmpty
                            ? GestureDetector(
                                onTap: () => setState(() =>
                                    _showUploadedPopup = !_showUploadedPopup),
                                child: SvgPicture.asset(
                                  'assets/images/active_upload.svg',
                                  width: 24,
                                  height: 24,
                                  colorFilter: const ColorFilter.mode(
                                    Color(0xFF0C8CE9),
                                    BlendMode.srcIn,
                                  ),
                                ),
                              )
                            : SvgPicture.asset(
                                'assets/images/upload_doc.svg',
                                width: 24,
                                height: 24,
                              )),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDocumentsTabLine(double extraTabLineWidth) {
    return SizedBox(
      height: 16,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: -extraTabLineWidth,
            bottom: 0,
            child: Container(
              height: 0.5,
              color: const Color(0xFF5C5C5C),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final day = date.day.toString().padLeft(2, '0');
    final month = months[date.month - 1];
    final year = date.year.toString();
    return '$day $month, $year';
  }

  @override
  void initState() {
    super.initState();
    _nextId ??= 0;
    _completedUploads.clear(); // Clear any previous uploads when app starts
    _loadDocuments();
  }

  @override
  void didUpdateWidget(covariant DocumentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final projectChanged = widget.projectId != oldWidget.projectId;
    final dataVersionChanged = widget.dataVersion != oldWidget.dataVersion;
    if (projectChanged || dataVersionChanged) {
      _currentFolderId = null;
      _loadDocuments();
    }
  }

  @override
  void dispose() {
    _layoutViewerAutosaveTimer?.cancel();
    _removeLayoutImageViewerOverlayEntry();
    _layoutImageViewerController.dispose();
    _layoutViewerPaintVersion.dispose();
    super.dispose();
  }

  int _consumeNextId() {
    final nextId = _nextId ?? 0;
    _nextId = nextId + 1;
    return nextId;
  }

  void _exitSelectMode() {
    setState(() {
      _isSelectMode = false;
      _selectedDocumentIds.clear();
    });
  }

  void _deleteSelectedFiles() async {
    try {
      final protectedRootFolderIds = _documents
          .where(
            (doc) =>
                (doc['parentId'] == null ||
                    doc['parentId'].toString().trim().isEmpty) &&
                _isPinnedRootFolder(doc),
          )
          .map((doc) => (doc['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      final deletableIds = _selectedDocumentIds
          .where((id) => !protectedRootFolderIds.contains(id))
          .toList();

      for (final docId in deletableIds) {
        final doc = _documents.firstWhere((item) => item['id'] == docId,
            orElse: () => {});
        if (doc.isNotEmpty) {
          // Delete file from storage if it has a URL
          final fileUrl = doc['url'] as String?;
          if (fileUrl != null && fileUrl.isNotEmpty) {
            final path = Uri.parse(fileUrl).path.split('/documents/').last;
            await _supabase.storage.from('documents').remove([path]);
          }
        }
      }

      // Delete from database
      for (final docId in deletableIds) {
        await _supabase.from('documents').delete().eq('id', docId);
      }

      setState(() {
        for (final docId in deletableIds) {
          _documents.removeWhere((item) => item['id'] == docId);
        }
        _exitSelectMode();
      });
    } catch (e) {
      debugPrint('Error deleting files: $e');
    }
  }

  Future<void> _loadDocuments() async {
    setState(() => _isLoading = true);
    try {
      if (widget.projectId == null) {
        if (mounted) {
          setState(() {
            _documents.clear();
            _isLoading = false;
          });
        }
        return;
      }

      // Load documents from Supabase
      final response = await _supabase
          .from('documents')
          .select(
              'id, name, type, parent_id, created_at, updated_at, file_url, file_size')
          .eq('project_id', widget.projectId!);
      final docs = List<dynamic>.from(response as List);

      final hasRootExpensesFolder = docs.any((doc) {
        if (doc is! Map) return false;
        final type = (doc['type'] ?? '').toString().toLowerCase();
        final name = (doc['name'] ?? '').toString().trim().toLowerCase();
        final parentId = doc['parent_id'];
        final isRoot = parentId == null || parentId.toString().trim().isEmpty;
        return type == 'folder' &&
            name == _defaultExpensesFolderName.toLowerCase() &&
            isRoot;
      });

      if (!hasRootExpensesFolder) {
        try {
          final inserted = await _supabase
              .from('documents')
              .insert({
                'project_id': widget.projectId!,
                'name': _defaultExpensesFolderName,
                'type': 'folder',
                'parent_id': null,
              })
              .select()
              .single();
          docs.add(inserted);
        } catch (e) {
          debugPrint('Error ensuring default Expenses folder: $e');
          try {
            final retry = await _supabase
                .from('documents')
                .select()
                .eq('project_id', widget.projectId!)
                .eq('type', 'folder')
                .eq('name', _defaultExpensesFolderName)
                .limit(1);
            if (retry is List && retry.isNotEmpty) {
              docs.add(retry.first);
            }
          } catch (_) {
            // ignore follow-up retry error
          }
        }
      }

      final hasRootAmenityFolder = docs.any((doc) {
        if (doc is! Map) return false;
        final type = (doc['type'] ?? '').toString().toLowerCase();
        final name = (doc['name'] ?? '').toString().trim().toLowerCase();
        final parentId = doc['parent_id'];
        final isRoot = parentId == null || parentId.toString().trim().isEmpty;
        return type == 'folder' &&
            name == _defaultAmenityFolderName.toLowerCase() &&
            isRoot;
      });

      if (!hasRootAmenityFolder) {
        try {
          final inserted = await _supabase
              .from('documents')
              .insert({
                'project_id': widget.projectId!,
                'name': _defaultAmenityFolderName,
                'type': 'folder',
                'parent_id': null,
              })
              .select()
              .single();
          docs.add(inserted);
        } catch (e) {
          debugPrint('Error ensuring default Amenity Area folder: $e');
          try {
            final retry = await _supabase
                .from('documents')
                .select()
                .eq('project_id', widget.projectId!)
                .eq('type', 'folder')
                .eq('name', _defaultAmenityFolderName)
                .limit(1);
            if (retry is List && retry.isNotEmpty) {
              docs.add(retry.first);
            }
          } catch (_) {
            // ignore follow-up retry error
          }
        }
      }

      setState(() {
        _documents.clear();
        for (var doc in docs) {
          final resolvedExtension =
              _resolveDocumentExtension(Map<String, dynamic>.from(doc));
          _documents.add({
            'id': doc['id'],
            'name': doc['name'],
            'type': doc['type'],
            'extension': resolvedExtension,
            'parentId': doc['parent_id'],
            'createdDate': doc['created_at'],
            'uploadedLabel': doc['created_at'] != null
                ? (doc['type'] == 'file'
                    ? 'Uploaded: ${_formatDate(DateTime.parse(doc['created_at']))}'
                    : 'Created: ${_formatDate(DateTime.parse(doc['created_at']))}')
                : '',
            'updatedLabel': doc['updated_at'] != null &&
                    doc['updated_at'] != doc['created_at']
                ? 'Updated: ${_formatDate(DateTime.parse(doc['updated_at']))}'
                : '',
            'fileCount': doc['type'] == 'folder'
                ? _documents
                    .where((item) => item['parentId'] == doc['id'])
                    .length
                : 0,
            'url': doc['file_url'],
            'file_size': doc['file_size'] ?? 0,
          });
        }
      });
    } catch (e) {
      debugPrint('Error loading documents: $e');
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  void _addFolder(String name) async {
    final trimmed = name.trim();
    final effectiveName = trimmed.isEmpty ? 'Untitled folder' : trimmed;

    try {
      if (widget.projectId == null) {
        debugPrint('No project ID available');
        return;
      }

      // Insert folder into Supabase
      final response = await _supabase
          .from('documents')
          .insert({
            'project_id': widget.projectId!,
            'name': effectiveName,
            'type': 'folder',
            'parent_id': _currentFolderId,
          })
          .select()
          .single();

      final newId = response['id'] as String;
      final createdLabel = 'Created: ${_formatDate(DateTime.now())}';
      final now = DateTime.now();

      setState(() {
        _documents.add({
          'id': newId,
          'name': effectiveName,
          'type': 'folder',
          'fileCount': 0,
          'createdDate': now.toIso8601String(),
          'uploadedLabel': createdLabel,
          'parentId': _currentFolderId,
        });
        _showAddFolderDialog = false;
        _newlyCreatedFolderId = newId;
      });

      // Clear the flag after a short delay
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          setState(() => _newlyCreatedFolderId = null);
        }
      });
    } catch (e) {
      debugPrint('Error creating folder: $e');
    }
  }

  void _uploadDocuments() async {
    try {
      if (widget.projectId == null) {
        debugPrint('No project ID available');
        return;
      }

      final html.FileUploadInputElement uploadInput =
          html.FileUploadInputElement();
      uploadInput.multiple = true;
      uploadInput.accept =
          '.csv,.doc,.docx,.xls,.xlsx,.heic,.jpg,.jpeg,.png,.webp,.mp4,.pdf,.dwg,.zip,.txt,.dxf';

      uploadInput.click();

      uploadInput.onChange.listen((e) async {
        final files = uploadInput.files;
        if (files != null && files.isNotEmpty) {
          final blockedFiles = <String>[];
          final validFiles = <html.File>[];

          // Separate blocked and valid files
          for (var file in files) {
            final extension = _getFileExtension(file.name);
            if (_isBlockedExtension(extension)) {
              blockedFiles.add(file.name);
            } else {
              validFiles.add(file);
            }
          }

          // Show error for blocked files
          if (blockedFiles.isNotEmpty && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Security Error: Cannot upload files with extensions: ${blockedFiles.join(', ')}',
                  style: const TextStyle(color: Colors.white),
                ),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 4),
              ),
            );
          }

          // Initialize upload progress for valid files
          for (var file in validFiles) {
            final fileName = file.name;
            final extension = _getFileExtension(fileName);
            final uploadId =
                '${DateTime.now().millisecondsSinceEpoch}_${fileName}';

            setState(() {
              _activeUploads[uploadId] = _UploadProgress(
                id: uploadId,
                fileName: fileName,
                extension: extension,
                parentId: _currentFolderId,
                file: file,
              );
            });
          }

          // Process valid files
          for (var entry in _activeUploads.entries.toList()) {
            final uploadId = entry.key;
            final uploadProgress = entry.value;

            if (uploadProgress.isCanceled ||
                uploadProgress.isCompleted ||
                uploadProgress.isFailed) {
              continue;
            }

            try {
              final file = uploadProgress.file!;
              final fileName = uploadProgress.fileName;
              final extension = uploadProgress.extension;
              final timestamp = DateTime.now().millisecondsSinceEpoch;
              final storagePath =
                  '${widget.projectId}/${_currentFolderId ?? 'root'}/$timestamp-$fileName';

              debugPrint('Uploading file: $fileName');
              debugPrint('Storage path: $storagePath');

              // Update progress to 10%
              setState(() {
                uploadProgress.progress = 10.0;
              });

              // Upload file to Supabase Storage
              // Read file using FileReader
              final reader = html.FileReader();
              reader.readAsArrayBuffer(file);
              await reader.onLoadEnd.first;
              final bytes = reader.result as Uint8List;

              // Update progress to 50%
              if (!uploadProgress.isCanceled && mounted) {
                setState(() {
                  uploadProgress.progress = 50.0;
                });
              }

              if (uploadProgress.isCanceled) continue;

              final uploadResponse = await _supabase.storage
                  .from('documents')
                  .uploadBinary(
                    storagePath,
                    bytes,
                    fileOptions: FileOptions(
                      contentType: file.type.isEmpty
                          ? _getContentType(extension)
                          : file.type,
                      cacheControl: '3600',
                      upsert: false,
                    ),
                  )
                  .timeout(const Duration(seconds: 30));

              debugPrint('Upload response: $uploadResponse');

              if (uploadProgress.isCanceled) continue;

              // Update progress to 90%
              if (mounted) {
                setState(() {
                  uploadProgress.progress = 90.0;
                });
              }

              // Save metadata to database with storage path
              final response = await _supabase
                  .from('documents')
                  .insert({
                    'project_id': widget.projectId!,
                    'name': fileName,
                    'type': 'file',
                    'extension': extension,
                    'parent_id': _currentFolderId,
                    'file_url': storagePath, // Save storage path, not full URL
                    'file_size': file.size,
                  })
                  .select()
                  .single();

              final uploadedLabel = 'Uploaded: ${_formatDate(DateTime.now())}';
              final now = DateTime.now();

              if (mounted) {
                setState(() {
                  uploadProgress.progress = 100.0;
                  uploadProgress.isCompleted = true;

                  final uploadedFile = {
                    'id': response['id'],
                    'name': fileName,
                    'type': 'file',
                    'extension': extension,
                    'createdDate': now.toIso8601String(),
                    'uploadedLabel': uploadedLabel,
                    'parentId': _currentFolderId,
                    'url': storagePath,
                    'file_size': file.size,
                  };

                  _documents.add(uploadedFile);

                  // Add to completed uploads
                  _completedUploads.add(uploadedFile);

                  // Remove from active uploads after a short delay
                  Future.delayed(const Duration(milliseconds: 500), () {
                    if (mounted) {
                      setState(() {
                        _activeUploads.remove(uploadId);
                      });
                    }
                  });
                });
              }
            } catch (e) {
              debugPrint('Error uploading file ${uploadProgress.fileName}: $e');
              if (mounted) {
                setState(() {
                  uploadProgress.isFailed = true;
                });
              }
            }
          }
        }
      });
    } catch (e) {
      debugPrint('Error picking files: $e');
    }
  }

  void _cancelUpload(String uploadId) {
    setState(() {
      final upload = _activeUploads[uploadId];
      if (upload != null) {
        upload.isCanceled = true;
        _activeUploads.remove(uploadId);
      }
    });
  }

  void _closeUploadPopup() {
    setState(() {
      _showUploadingPopup = false;
    });
  }

  void _closeUploadedPopup() {
    setState(() {
      _showUploadedPopup = false;
    });
  }

  void _clearCompletedUploads() {
    setState(() {
      _completedUploads.clear();
    });
  }

  String _getFileExtension(String fileName) {
    final parts = fileName.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : 'file';
  }

  String _resolveDocumentExtension(Map<String, dynamic> doc) {
    final extension = (doc['extension'] ?? '').toString().trim().toLowerCase();
    if (extension.isNotEmpty) return extension;
    final name = (doc['name'] ?? '').toString().trim();
    if (name.isEmpty) return 'file';
    return _getFileExtension(name);
  }

  bool _isBlockedExtension(String extension) {
    const blockedExtensions = [
      'exe',
      'apk',
      'bat',
      'sh',
      'js',
      'html',
      'php',
      'py',
      'rb',
      'jar',
      'msi'
    ];
    return blockedExtensions.contains(extension.toLowerCase());
  }

  String _getFileIconPath(String extension) {
    final iconMap = {
      'csv': 'assets/images/csv.svg',
      'doc': 'assets/images/doc.svg',
      'docx': 'assets/images/docx.svg',
      'xls': 'assets/images/excel.svg',
      'xlsx': 'assets/images/excel.svg',
      'heic': 'assets/images/heic.svg',
      'jpg': 'assets/images/jpg.svg',
      'jpeg': 'assets/images/jpge.svg',
      'png': 'assets/images/png.svg',
      'webp': 'assets/images/webp.svg',
      'mp4': 'assets/images/mp4.svg',
      'pdf': 'assets/images/pdf.svg',
      'dwg': 'assets/images/dwg.svg',
      'zip': 'assets/images/zip.svg',
      'txt': 'assets/images/txt.svg',
      'dxf': 'assets/images/dxf.svg',
    };
    return iconMap[extension.toLowerCase()] ?? 'assets/images/no_format.svg';
  }

  String _getContentType(String extension) {
    final contentTypeMap = {
      'csv': 'text/csv',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'heic': 'image/heic',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'mp4': 'video/mp4',
      'pdf': 'application/pdf',
      'dwg': 'application/acad',
      'zip': 'application/zip',
      'txt': 'text/plain',
      'dxf': 'application/dxf',
    };
    return contentTypeMap[extension.toLowerCase()] ??
        'application/octet-stream';
  }

  String _getFilePathInZip(Map<String, dynamic> file) {
    // Build the full path for this file including all parent folders
    final pathParts = <String>[];
    String? currentParentId = file['parentId'] as String?;

    // Traverse up the folder hierarchy
    while (currentParentId != null) {
      final parentFolder = _documents.firstWhere(
        (doc) => doc['id'] == currentParentId,
        orElse: () => <String, dynamic>{},
      );

      if (parentFolder.isEmpty) break;

      final folderName = parentFolder['name'] as String?;
      if (folderName != null && folderName.isNotEmpty) {
        pathParts.insert(0, folderName);
      }

      currentParentId = parentFolder['parentId'] as String?;
    }

    // Add the filename at the end
    pathParts.add(file['name'] as String);

    return pathParts.join('/');
  }

  bool _isImageExtension(String extension) {
    final e = extension.trim().toLowerCase();
    return e == 'png' ||
        e == 'jpg' ||
        e == 'jpeg' ||
        e == 'webp' ||
        e == 'gif' ||
        e == 'svg';
  }

  String _resolveDocumentStoragePath(String urlOrPath) {
    final raw = urlOrPath.trim();
    if (raw.isEmpty) return '';
    if (!raw.startsWith('http')) return raw;
    final parts = raw.split('/documents/');
    if (parts.length > 1) {
      return parts.sublist(1).join('/documents/').trim();
    }
    return raw;
  }

  String _resolveDocumentPublicUrl(String urlOrPath) {
    final path = _resolveDocumentStoragePath(urlOrPath);
    if (path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    return _supabase.storage.from('documents').getPublicUrl(path);
  }

  void _openDocumentFile(Map<String, dynamic> doc) {
    final urlOrPath = (doc['url'] ?? '').toString().trim();
    if (urlOrPath.isEmpty) return;
    final extension = _resolveDocumentExtension(doc);
    if (_isImageExtension(extension)) {
      _openLayoutImageViewerForDocument(doc);
      return;
    }
    final finalUrl = _resolveDocumentPublicUrl(urlOrPath);
    if (finalUrl.isNotEmpty) {
      html.window.open(finalUrl, '_blank');
    }
  }

  String _activeLayoutImageDownloadName() {
    final name = _activeLayoutImageName.trim();
    if (name.isNotEmpty) return name;
    final extension = _activeLayoutImageExtension.trim().toLowerCase();
    if (extension.isNotEmpty) {
      return 'layout_image.$extension';
    }
    return 'layout_image.png';
  }

  Future<void> _printActiveLayoutImage() async {
    if (_hasPendingLayoutViewerEdits) {
      try {
        await _saveLayoutViewerEditsIfNeeded();
      } catch (_) {}
    }
    final resolvedUrl =
        _resolveDocumentPublicUrl(_activeLayoutImageStoragePath);
    final imageUrl =
        resolvedUrl.isNotEmpty ? resolvedUrl : _activeLayoutImageUrl.trim();
    if (imageUrl.isEmpty) return;
    html.IFrameElement? printFrame;
    String? objectUrl;
    try {
      final response = await http.get(Uri.parse(imageUrl));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final mimeType = response.headers['content-type'] ?? 'image/png';
      final blob = html.Blob([response.bodyBytes], mimeType);
      objectUrl = html.Url.createObjectUrlFromBlob(blob);

      printFrame = html.IFrameElement()
        ..style.position = 'fixed'
        ..style.right = '0'
        ..style.bottom = '0'
        ..style.width = '0'
        ..style.height = '0'
        ..style.border = '0'
        ..style.visibility = 'hidden';
      html.document.body?.append(printFrame);
      final escapedTitle = htmlEscape.convert(_activeLayoutImageDownloadName());
      final escapedObjectUrl = htmlEscape.convert(objectUrl);
      final frameDoc = '''
<!DOCTYPE html>
<html>
  <head>
    <title>$escapedTitle</title>
    <style>
      html, body {
        margin: 0;
        padding: 0;
        background: #ffffff;
        width: 100%;
        height: 100%;
      }
      body {
        display: flex;
        align-items: center;
        justify-content: center;
      }
      img {
        max-width: 100vw;
        max-height: 100vh;
        object-fit: contain;
      }
    </style>
  </head>
  <body>
    <img src="$escapedObjectUrl" alt="$escapedTitle" onload="setTimeout(function(){ window.focus(); window.print(); }, 50);" />
  </body>
</html>
''';
      printFrame.srcdoc = frameDoc;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to print image: $e')),
        );
      }
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        printFrame?.remove();
        if (objectUrl != null && objectUrl!.isNotEmpty) {
          html.Url.revokeObjectUrl(objectUrl!);
        }
      });
    }
  }

  Future<void> _downloadActiveLayoutImage() async {
    if (_hasPendingLayoutViewerEdits) {
      try {
        await _saveLayoutViewerEditsIfNeeded();
      } catch (_) {}
    }
    final resolvedUrl =
        _resolveDocumentPublicUrl(_activeLayoutImageStoragePath);
    final downloadUrl =
        resolvedUrl.isNotEmpty ? resolvedUrl : _activeLayoutImageUrl.trim();
    if (downloadUrl.isEmpty) return;
    try {
      final response = await http.get(Uri.parse(downloadUrl));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final mimeType =
          response.headers['content-type'] ?? 'application/octet-stream';
      final blob = html.Blob([response.bodyBytes], mimeType);
      final objectUrl = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: objectUrl)
        ..download = _activeLayoutImageDownloadName()
        ..style.display = 'none';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(objectUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to download image: $e')),
        );
      }
    }
  }

  Future<void> _deleteActiveLayoutImage() async {
    if (_isDeletingLayoutViewerImage) return;
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) return;

    _isDeletingLayoutViewerImage = true;
    _layoutViewerAutosaveTimer?.cancel();

    try {
      String storagePath =
          _resolveDocumentStoragePath(_activeLayoutImageStoragePath);
      String docId = _activeLayoutImageDocId.trim();

      if (storagePath.isEmpty && docId.isNotEmpty) {
        final byId = await _supabase
            .from('documents')
            .select('file_url')
            .eq('id', docId)
            .maybeSingle();
        storagePath = _resolveDocumentStoragePath(
          (byId?['file_url'] ?? '').toString(),
        );
      }

      if (docId.isEmpty && storagePath.isNotEmpty) {
        final byPath = await _supabase
            .from('documents')
            .select('id')
            .eq('project_id', projectId)
            .eq('file_url', storagePath)
            .maybeSingle();
        docId = (byPath?['id'] ?? '').toString().trim();
      }

      if (storagePath.isNotEmpty) {
        try {
          await _supabase.storage.from('documents').remove([storagePath]);
        } catch (_) {}
      }

      if (docId.isNotEmpty) {
        await _supabase.from('documents').delete().eq('id', docId);
      } else if (storagePath.isNotEmpty) {
        await _supabase
            .from('documents')
            .delete()
            .eq('project_id', projectId)
            .eq('file_url', storagePath);
      }

      if (docId.isNotEmpty) {
        try {
          await _supabase
              .from('layouts')
              .update({
                'layout_image_name': '',
                'layout_image_path': '',
                'layout_image_doc_id': '',
                'layout_image_extension': '',
              })
              .eq('project_id', projectId)
              .eq('layout_image_doc_id', docId);
        } catch (_) {}
      }
      if (storagePath.isNotEmpty) {
        try {
          await _supabase
              .from('layouts')
              .update({
                'layout_image_name': '',
                'layout_image_path': '',
                'layout_image_doc_id': '',
                'layout_image_extension': '',
              })
              .eq('project_id', projectId)
              .eq('layout_image_path', storagePath);
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _documents.removeWhere((item) {
            final itemId = (item['id'] ?? '').toString().trim();
            final itemPath = _resolveDocumentStoragePath(
              (item['url'] ?? '').toString(),
            );
            return (docId.isNotEmpty && itemId == docId) ||
                (storagePath.isNotEmpty && itemPath == storagePath);
          });
          _isLayoutImageViewerOpen = false;
          _activeLayoutImageUrl = '';
          _activeLayoutImageStoragePath = '';
          _activeLayoutImageDocId = '';
          _activeLayoutImageName = '';
          _activeLayoutImageExtension = '';
          _isLayoutPenModeActive = true;
          _isLayoutEraserModeActive = false;
          _isLayoutPanModeActive = false;
          _isLayoutThicknessPickerVisible = false;
          _isLayoutThicknessPickerForEraser = false;
          _isLayoutColorPickerVisible = false;
          _layoutViewerStrokes.clear();
          _activeLayoutStrokeIndex = null;
          _activeLayoutStrokePointerId = null;
          _layoutViewerLastCanvasSize = Size.zero;
          _hasPendingLayoutViewerEdits = false;
        });
      }
      _removeLayoutImageViewerOverlayEntry();
      _layoutImageViewerController.value = Matrix4.identity();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Layout image deleted.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete layout image: $e')),
        );
      }
    } finally {
      _isDeletingLayoutViewerImage = false;
    }
  }

  void _openLayoutImageViewerForDocument(Map<String, dynamic> doc) {
    final urlOrPath = (doc['url'] ?? '').toString().trim();
    if (urlOrPath.isEmpty) return;
    final storagePath = _resolveDocumentStoragePath(urlOrPath);
    final finalUrl = _resolveDocumentPublicUrl(storagePath);
    if (finalUrl.isEmpty) return;

    setState(() {
      _activeLayoutImageUrl = finalUrl;
      _activeLayoutImageStoragePath = storagePath;
      _activeLayoutImageDocId = (doc['id'] ?? '').toString().trim();
      _activeLayoutImageName = (doc['name'] ?? '').toString().trim();
      _activeLayoutImageExtension =
          _resolveDocumentExtension(Map<String, dynamic>.from(doc));
      _isLayoutImageViewerOpen = true;
      _isLayoutPenModeActive = true;
      _isLayoutEraserModeActive = false;
      _isLayoutPanModeActive = false;
      _isLayoutThicknessPickerVisible = false;
      _isLayoutThicknessPickerForEraser = false;
      _isLayoutColorPickerVisible = false;
      _layoutViewerStrokes.clear();
      _activeLayoutStrokeIndex = null;
      _activeLayoutStrokePointerId = null;
      _layoutViewerLastCanvasSize = Size.zero;
      _hasPendingLayoutViewerEdits = false;
    });
    _removeLayoutImageViewerOverlayEntry();
    final rootOverlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (_) => _buildLayoutImageViewerOverlay(),
    );
    _layoutImageViewerOverlayEntry = entry;
    rootOverlay.insert(entry);
    _layoutViewerAutosaveTimer?.cancel();
    _layoutImageViewerController.value = Matrix4.identity();
  }

  void _closeLayoutImageViewer() {
    unawaited(_closeLayoutImageViewerAndPersistEdits());
  }

  Future<void> _closeLayoutImageViewerAndPersistEdits() async {
    if (_isSavingLayoutViewerEdits) return;
    _layoutViewerAutosaveTimer?.cancel();
    _isSavingLayoutViewerEdits = true;
    try {
      await _saveLayoutViewerEditsIfNeeded();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save layout edits: $e')),
        );
      }
    } finally {
      _isSavingLayoutViewerEdits = false;
    }
    _removeLayoutImageViewerOverlayEntry();
    if (!mounted) return;
    setState(() {
      _isLayoutImageViewerOpen = false;
      _activeLayoutImageUrl = '';
      _activeLayoutImageStoragePath = '';
      _activeLayoutImageDocId = '';
      _activeLayoutImageName = '';
      _activeLayoutImageExtension = '';
      _isLayoutPenModeActive = true;
      _isLayoutEraserModeActive = false;
      _isLayoutPanModeActive = false;
      _isLayoutThicknessPickerVisible = false;
      _isLayoutThicknessPickerForEraser = false;
      _isLayoutColorPickerVisible = false;
      _layoutViewerStrokes.clear();
      _activeLayoutStrokeIndex = null;
      _activeLayoutStrokePointerId = null;
      _layoutViewerLastCanvasSize = Size.zero;
      _hasPendingLayoutViewerEdits = false;
    });
    _layoutImageViewerController.value = Matrix4.identity();
  }

  Future<void> _saveLayoutViewerEditsIfNeeded() async {
    if (!_hasPendingLayoutViewerEdits || _layoutViewerStrokes.isEmpty) return;
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) {
      throw Exception('Please save project first.');
    }
    String storagePath =
        _resolveDocumentStoragePath(_activeLayoutImageStoragePath);
    String docId = _activeLayoutImageDocId.trim();
    if (storagePath.isEmpty && docId.isNotEmpty) {
      final byId = await _supabase
          .from('documents')
          .select('file_url')
          .eq('id', docId)
          .maybeSingle();
      storagePath = _resolveDocumentStoragePath(
        (byId?['file_url'] ?? '').toString(),
      );
    }
    if (storagePath.isEmpty) throw Exception('No storage path found.');
    final baseUrl = _resolveDocumentPublicUrl(storagePath);
    if (baseUrl.isEmpty) throw Exception('Could not resolve source image.');

    final editedBytes = await _renderLayoutViewerCompositePng(
      imageUrl: baseUrl,
      strokes: _layoutViewerStrokes,
      drawingCanvasSize: _layoutViewerLastCanvasSize,
    );
    final nextStoragePath = _buildEditedLayoutImageStoragePath(
      basePath: storagePath,
      imageName: _activeLayoutImageName,
    );
    final nextName = nextStoragePath.split('/').last;

    await _supabase.storage.from('documents').uploadBinary(
          nextStoragePath,
          editedBytes,
          fileOptions: const FileOptions(
            contentType: 'image/png',
            cacheControl: '3600',
            upsert: true,
          ),
        );

    if (docId.isEmpty) {
      final byPath = await _supabase
          .from('documents')
          .select('id')
          .eq('project_id', projectId)
          .eq('file_url', storagePath)
          .limit(1)
          .maybeSingle();
      docId = (byPath?['id'] ?? '').toString().trim();
    }
    if (docId.isEmpty) throw Exception('Linked document row not found.');

    await _supabase.from('documents').update({
      'name': nextName,
      'extension': 'png',
      'file_url': nextStoragePath,
      'file_size': editedBytes.length,
    }).eq('id', docId);

    // Keep layouts page in sync even when edit is done from Documents page.
    try {
      await _supabase
          .from('layouts')
          .update({
            'layout_image_name': nextName,
            'layout_image_path': nextStoragePath,
            'layout_image_extension': 'png',
          })
          .eq('project_id', projectId)
          .eq('layout_image_doc_id', docId);
    } catch (_) {
      // layout image columns may not exist in older DB schema
    }

    if (mounted) {
      setState(() {
        final idx = _documents
            .indexWhere((item) => (item['id'] ?? '').toString() == docId);
        if (idx >= 0) {
          _documents[idx]['name'] = nextName;
          _documents[idx]['extension'] = 'png';
          _documents[idx]['url'] = nextStoragePath;
          _documents[idx]['file_size'] = editedBytes.length;
          _documents[idx]['updatedLabel'] =
              'Updated: ${_formatDate(DateTime.now())}';
        }
      });
    }

    _activeLayoutImageStoragePath = nextStoragePath;
    _activeLayoutImageDocId = docId;
    _activeLayoutImageName = nextName;
    _activeLayoutImageExtension = 'png';
    _hasPendingLayoutViewerEdits = false;
  }

  String _buildEditedLayoutImageStoragePath({
    required String basePath,
    required String imageName,
  }) {
    final normalized = _resolveDocumentStoragePath(basePath);
    final slashIndex = normalized.lastIndexOf('/');
    final folderPath =
        slashIndex >= 0 ? normalized.substring(0, slashIndex) : '';
    final safeName = imageName.trim().isEmpty
        ? 'layout_image'
        : imageName.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final dotIndex = safeName.lastIndexOf('.');
    final baseName = dotIndex > 0 ? safeName.substring(0, dotIndex) : safeName;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fileName = '${baseName}_edited_$ts.png';
    return folderPath.isEmpty ? fileName : '$folderPath/$fileName';
  }

  Future<Uint8List> _renderLayoutViewerCompositePng({
    required String imageUrl,
    required List<_DocumentLayoutViewerStroke> strokes,
    required Size drawingCanvasSize,
  }) async {
    final response = await http.get(Uri.parse(imageUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Could not load source image (${response.statusCode})');
    }
    final contentType = response.headers['content-type'] ?? 'image/png';
    final sourceImage = await _loadImageElementFromBytes(
      response.bodyBytes,
      contentType,
    );

    final width = max(1, sourceImage.naturalWidth ?? sourceImage.width ?? 0);
    final height = max(1, sourceImage.naturalHeight ?? sourceImage.height ?? 0);
    final effectiveCanvasWidth = drawingCanvasSize.width > 0
        ? drawingCanvasSize.width
        : width.toDouble();
    final effectiveCanvasHeight = drawingCanvasSize.height > 0
        ? drawingCanvasSize.height
        : height.toDouble();
    final fitScale = max(
      0.0001,
      min(
        effectiveCanvasWidth / width.toDouble(),
        effectiveCanvasHeight / height.toDouble(),
      ),
    );
    final drawnImageWidth = width * fitScale;
    final drawnImageHeight = height * fitScale;
    final imageOffsetX = (effectiveCanvasWidth - drawnImageWidth) / 2;
    final imageOffsetY = (effectiveCanvasHeight - drawnImageHeight) / 2;
    final strokeScale = 1 / fitScale;

    Offset mapNormalizedPointToSource(Offset normalizedPoint) {
      final canvasX = normalizedPoint.dx * effectiveCanvasWidth;
      final canvasY = normalizedPoint.dy * effectiveCanvasHeight;
      final sourceX =
          ((canvasX - imageOffsetX) / fitScale).clamp(0.0, width.toDouble());
      final sourceY =
          ((canvasY - imageOffsetY) / fitScale).clamp(0.0, height.toDouble());
      return Offset(sourceX, sourceY);
    }

    final canvas = html.CanvasElement(width: width, height: height);
    final ctx = canvas.context2D;
    ctx.drawImageScaled(sourceImage, 0, 0, width.toDouble(), height.toDouble());

    for (final stroke in strokes) {
      if (stroke.normalizedPoints.isEmpty) continue;
      final lineWidth = max(1.0, stroke.thickness * 2.0 * strokeScale);
      final strokeStyle = _cssColorFromColor(stroke.color);
      if (stroke.normalizedPoints.length == 1) {
        final p = mapNormalizedPointToSource(stroke.normalizedPoints.first);
        ctx
          ..fillStyle = strokeStyle
          ..beginPath()
          ..arc(p.dx, p.dy, lineWidth / 2, 0, pi * 2)
          ..fill();
        continue;
      }
      final first = mapNormalizedPointToSource(stroke.normalizedPoints.first);
      ctx
        ..beginPath()
        ..strokeStyle = strokeStyle
        ..lineWidth = lineWidth
        ..lineCap = 'round'
        ..lineJoin = 'round'
        ..moveTo(first.dx, first.dy);
      for (int i = 1; i < stroke.normalizedPoints.length; i++) {
        final p = mapNormalizedPointToSource(stroke.normalizedPoints[i]);
        ctx.lineTo(p.dx, p.dy);
      }
      ctx.stroke();
    }
    final dataUrl = canvas.toDataUrl('image/png');
    final commaIndex = dataUrl.indexOf(',');
    if (commaIndex < 0 || commaIndex + 1 >= dataUrl.length) {
      throw Exception('Could not encode edited image');
    }
    return base64Decode(dataUrl.substring(commaIndex + 1));
  }

  Future<html.ImageElement> _loadImageElementFromBytes(
    Uint8List bytes,
    String contentType,
  ) async {
    final blob = html.Blob([bytes], contentType);
    final objectUrl = html.Url.createObjectUrlFromBlob(blob);
    final image = html.ImageElement();
    final completer = Completer<html.ImageElement>();
    late StreamSubscription loadSub;
    late StreamSubscription errorSub;
    loadSub = image.onLoad.listen((_) {
      loadSub.cancel();
      errorSub.cancel();
      completer.complete(image);
    });
    errorSub = image.onError.listen((_) {
      loadSub.cancel();
      errorSub.cancel();
      completer.completeError(Exception('Could not decode source image'));
    });
    image.src = objectUrl;
    return completer.future.whenComplete(() {
      html.Url.revokeObjectUrl(objectUrl);
    });
  }

  String _cssColorFromColor(Color color) {
    final alpha = (color.alpha / 255).toStringAsFixed(3);
    return 'rgba(${color.red},${color.green},${color.blue},$alpha)';
  }

  void _removeLayoutImageViewerOverlayEntry() {
    _layoutImageViewerOverlayEntry?.remove();
    _layoutImageViewerOverlayEntry = null;
  }

  void _markLayoutImageViewerOverlayNeedsBuild() {
    _layoutImageViewerOverlayEntry?.markNeedsBuild();
  }

  void _notifyLayoutViewerPaint() {
    _layoutViewerPaintVersion.value++;
  }

  void _markLayoutViewerEditsDirty() {
    _hasPendingLayoutViewerEdits = true;
    _scheduleLayoutViewerAutosave();
  }

  void _scheduleLayoutViewerAutosave() {
    _layoutViewerAutosaveTimer?.cancel();
    if (!_isLayoutImageViewerOpen) return;
    _layoutViewerAutosaveTimer = Timer(const Duration(seconds: 2), () async {
      if (!_isLayoutImageViewerOpen ||
          _isSavingLayoutViewerEdits ||
          !_hasPendingLayoutViewerEdits) {
        return;
      }
      _isSavingLayoutViewerEdits = true;
      try {
        await _saveLayoutViewerEditsIfNeeded();
      } catch (_) {
        // keep pending edits to retry on close
      } finally {
        _isSavingLayoutViewerEdits = false;
      }
    });
  }

  void _setLayoutThicknessPickerVisible(
    bool visible, {
    bool forEraser = false,
  }) {
    setState(() {
      _isLayoutThicknessPickerVisible = visible;
      if (visible) {
        _isLayoutThicknessPickerForEraser = forEraser;
        _isLayoutColorPickerVisible = false;
      } else {
        _isLayoutThicknessPickerForEraser = false;
      }
    });
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _setLayoutColorPickerVisible(bool visible) {
    setState(() {
      _isLayoutColorPickerVisible = visible;
      if (visible) {
        _isLayoutThicknessPickerVisible = false;
        _isLayoutThicknessPickerForEraser = false;
      }
    });
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _closeLayoutToolPickers() {
    setState(() {
      _isLayoutThicknessPickerVisible = false;
      _isLayoutThicknessPickerForEraser = false;
      _isLayoutColorPickerVisible = false;
    });
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _selectLayoutColorOption(int index) {
    if (index < 0 || index >= _layoutColorOptions.length) return;
    setState(() => _selectedLayoutColorIndex = index);
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _selectLayoutThicknessOption(int index) {
    if (index < 0 || index >= _layoutThicknessOptions.length) return;
    setState(() => _selectedLayoutThicknessIndex = index);
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _selectLayoutEraserThicknessOption(int index) {
    if (index < 0 || index >= _layoutThicknessOptions.length) return;
    setState(() => _selectedLayoutEraserThicknessIndex = index);
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _toggleLayoutPenMode() {
    setState(() {
      _isLayoutPenModeActive = !_isLayoutPenModeActive;
      if (_isLayoutPenModeActive) {
        _isLayoutEraserModeActive = false;
        _isLayoutPanModeActive = false;
      }
      if (!_isLayoutPenModeActive) {
        _activeLayoutStrokeIndex = null;
        _activeLayoutStrokePointerId = null;
      }
    });
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _activateLayoutPanMode() {
    setState(() {
      _isLayoutPanModeActive = true;
      _isLayoutPenModeActive = false;
      _isLayoutEraserModeActive = false;
      _activeLayoutStrokeIndex = null;
      _activeLayoutStrokePointerId = null;
    });
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _activateLayoutEraserMode() {
    setState(() {
      _isLayoutEraserModeActive = true;
      _isLayoutPenModeActive = false;
      _isLayoutPanModeActive = false;
      _activeLayoutStrokeIndex = null;
      _activeLayoutStrokePointerId = null;
    });
    _markLayoutImageViewerOverlayNeedsBuild();
  }

  void _zoomLayoutImageViewerByStep(double step) {
    final matrix = _layoutImageViewerController.value.clone();
    final currentScale = matrix.getMaxScaleOnAxis();
    final targetScale = (currentScale + step).clamp(0.5, 4.0);
    final scaleFactor = targetScale / currentScale;
    matrix.scale(scaleFactor);
    _layoutImageViewerController.value = matrix;
  }

  Offset? _layoutScenePositionFromLocal({
    required Offset localPosition,
    required Size canvasSize,
    bool clampToBounds = false,
  }) {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) return null;
    Offset scenePosition = _layoutImageViewerController.toScene(localPosition);
    if (clampToBounds) {
      return Offset(
        scenePosition.dx.clamp(0.0, canvasSize.width),
        scenePosition.dy.clamp(0.0, canvasSize.height),
      );
    }
    if (scenePosition.dx < 0 ||
        scenePosition.dy < 0 ||
        scenePosition.dx > canvasSize.width ||
        scenePosition.dy > canvasSize.height) {
      return null;
    }
    return scenePosition;
  }

  void _beginLayoutViewerStroke({
    required Offset localPosition,
    required Size canvasSize,
  }) {
    if (!_isLayoutPenModeActive) return;
    final scenePosition = _layoutScenePositionFromLocal(
      localPosition: localPosition,
      canvasSize: canvasSize,
    );
    if (scenePosition == null) return;
    final selectedColor =
        _layoutColorOptions[_selectedLayoutColorIndex].withValues(alpha: 0.5);
    final selectedThickness =
        _layoutThicknessOptions[_selectedLayoutThicknessIndex];
    final normalizedPoint = Offset(
      scenePosition.dx / canvasSize.width,
      scenePosition.dy / canvasSize.height,
    );
    _layoutViewerStrokes.add(
      _DocumentLayoutViewerStroke(
        normalizedPoints: <Offset>[normalizedPoint],
        color: selectedColor,
        thickness: selectedThickness,
      ),
    );
    _activeLayoutStrokeIndex = _layoutViewerStrokes.length - 1;
    _markLayoutViewerEditsDirty();
    _notifyLayoutViewerPaint();
  }

  void _appendLayoutViewerStrokePoint({
    required Offset localPosition,
    required Size canvasSize,
  }) {
    if (!_isLayoutPenModeActive) return;
    if (_activeLayoutStrokeIndex == null ||
        _activeLayoutStrokeIndex! < 0 ||
        _activeLayoutStrokeIndex! >= _layoutViewerStrokes.length) {
      _beginLayoutViewerStroke(
        localPosition: localPosition,
        canvasSize: canvasSize,
      );
      return;
    }
    final scenePosition = _layoutScenePositionFromLocal(
      localPosition: localPosition,
      canvasSize: canvasSize,
      clampToBounds: true,
    );
    if (scenePosition == null) return;
    final normalizedPoint = Offset(
      scenePosition.dx / canvasSize.width,
      scenePosition.dy / canvasSize.height,
    );
    final points =
        _layoutViewerStrokes[_activeLayoutStrokeIndex!].normalizedPoints;
    if (points.isNotEmpty) {
      final last = points.last;
      final dx = (normalizedPoint.dx - last.dx) * canvasSize.width;
      final dy = (normalizedPoint.dy - last.dy) * canvasSize.height;
      if ((dx * dx) + (dy * dy) < 0.25) return;
    }
    points.add(normalizedPoint);
    _markLayoutViewerEditsDirty();
    _notifyLayoutViewerPaint();
  }

  void _endLayoutViewerStroke() {
    if (_activeLayoutStrokeIndex == null) return;
    _activeLayoutStrokeIndex = null;
  }

  void _eraseLayoutViewerAt({
    required Offset localPosition,
    required Size canvasSize,
  }) {
    if (!_isLayoutEraserModeActive) return;
    final scenePosition = _layoutScenePositionFromLocal(
      localPosition: localPosition,
      canvasSize: canvasSize,
      clampToBounds: true,
    );
    if (scenePosition == null || _layoutViewerStrokes.isEmpty) return;
    final eraserThickness =
        _layoutThicknessOptions[_selectedLayoutEraserThicknessIndex];
    final eraserRadiusPx = max(8.0, eraserThickness * 8.0);
    final eraserRadiusSq = eraserRadiusPx * eraserRadiusPx;
    final List<_DocumentLayoutViewerStroke> updated =
        <_DocumentLayoutViewerStroke>[];
    bool changed = false;

    for (final stroke in _layoutViewerStrokes) {
      if (stroke.normalizedPoints.isEmpty) continue;
      final List<List<Offset>> segments = <List<Offset>>[];
      List<Offset> current = <Offset>[];
      bool strokeChanged = false;
      for (final point in stroke.normalizedPoints) {
        final dx = (point.dx * canvasSize.width) - scenePosition.dx;
        final dy = (point.dy * canvasSize.height) - scenePosition.dy;
        final shouldErase = (dx * dx) + (dy * dy) <= eraserRadiusSq;
        if (shouldErase) {
          strokeChanged = true;
          if (current.isNotEmpty) {
            segments.add(current);
            current = <Offset>[];
          }
          continue;
        }
        current.add(point);
      }
      if (current.isNotEmpty) segments.add(current);
      if (!strokeChanged) {
        updated.add(stroke);
        continue;
      }
      changed = true;
      for (final segment in segments) {
        if (segment.isEmpty) continue;
        updated.add(
          _DocumentLayoutViewerStroke(
            normalizedPoints: List<Offset>.from(segment),
            color: stroke.color,
            thickness: stroke.thickness,
          ),
        );
      }
    }
    if (!changed) return;
    _layoutViewerStrokes
      ..clear()
      ..addAll(updated);
    _markLayoutViewerEditsDirty();
    _notifyLayoutViewerPaint();
  }

  void _handleLayoutViewerPointerDown({
    required PointerDownEvent details,
    required Size canvasSize,
  }) {
    _layoutViewerLastCanvasSize = canvasSize;
    _activeLayoutStrokePointerId = details.pointer;
    if (_isLayoutPenModeActive) {
      _beginLayoutViewerStroke(
        localPosition: details.localPosition,
        canvasSize: canvasSize,
      );
      return;
    }
    if (_isLayoutEraserModeActive) {
      _eraseLayoutViewerAt(
        localPosition: details.localPosition,
        canvasSize: canvasSize,
      );
    }
  }

  void _handleLayoutViewerPointerMove({
    required PointerMoveEvent details,
    required Size canvasSize,
  }) {
    _layoutViewerLastCanvasSize = canvasSize;
    if (_activeLayoutStrokePointerId != details.pointer) return;
    if (_isLayoutPenModeActive) {
      _appendLayoutViewerStrokePoint(
        localPosition: details.localPosition,
        canvasSize: canvasSize,
      );
      return;
    }
    if (_isLayoutEraserModeActive) {
      _eraseLayoutViewerAt(
        localPosition: details.localPosition,
        canvasSize: canvasSize,
      );
    }
  }

  void _handleLayoutViewerPointerUpOrCancel({
    required int pointerId,
  }) {
    if (_activeLayoutStrokePointerId != pointerId) return;
    _activeLayoutStrokePointerId = null;
    _endLayoutViewerStroke();
  }

  Widget _buildLayoutImageViewerToolButton({
    required String iconAssetPath,
    required VoidCallback onTap,
    double width = 75,
    double height = 73,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        height: height,
        child: SvgPicture.asset(iconAssetPath, fit: BoxFit.fill),
      ),
    );
  }

  Widget _buildLayoutThicknessPicker({
    required double panelWidth,
    required Color optionColor,
    required int selectedIndex,
    required ValueChanged<int> onOptionTap,
  }) {
    const double rowHeight = 24;
    const double rowGap = 16;
    const double lineLength = 50;
    return Container(
      width: panelWidth,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 4,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_layoutThicknessOptions.length, (index) {
          final isSelected = index == selectedIndex;
          final strokeHeight = _layoutThicknessOptions[index];
          return Padding(
            padding: EdgeInsets.only(
              bottom: index == _layoutThicknessOptions.length - 1 ? 0 : rowGap,
            ),
            child: GestureDetector(
              onTapDown: (_) => onOptionTap(index),
              onTap: () => onOptionTap(index),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: double.infinity,
                height: rowHeight,
                color:
                    isSelected ? const Color(0xFFDDDEDE) : Colors.transparent,
                alignment: Alignment.center,
                child: Container(
                  width: lineLength,
                  height: strokeHeight,
                  decoration: BoxDecoration(
                    color: optionColor,
                    borderRadius: BorderRadius.circular(strokeHeight / 2),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildLayoutColorPicker({
    required double panelWidth,
  }) {
    const double rowHeight = 24;
    const double rowGap = 16;
    const double circleSize = 16;
    return Container(
      width: panelWidth,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 4,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_layoutColorOptions.length, (index) {
          final isSelected = index == _selectedLayoutColorIndex;
          final color = _layoutColorOptions[index];
          return Padding(
            padding: EdgeInsets.only(
              bottom: index == _layoutColorOptions.length - 1 ? 0 : rowGap,
            ),
            child: GestureDetector(
              onTapDown: (_) => _selectLayoutColorOption(index),
              onTap: () => _selectLayoutColorOption(index),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: double.infinity,
                height: rowHeight,
                color:
                    isSelected ? const Color(0xFFDDDEDE) : Colors.transparent,
                alignment: Alignment.center,
                child: Container(
                  width: circleSize,
                  height: circleSize,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildLayoutImageViewerOverlay() {
    if (!_isLayoutImageViewerOpen || _activeLayoutImageUrl.isEmpty) {
      return const SizedBox.shrink();
    }

    const double baseImageBoxWidth = 1080;
    const double baseImageBoxHeight = 768;
    const double baseOptionWidth = 75;
    const double baseOptionHeight = 73;
    const double baseOptionGap = 12;
    const double baseCloseIconSize = 42;
    const double baseCloseIconGapToPen = 63;
    const double railGapFromImage = 20;
    const double viewportPadding = 24;
    const double thicknessPanelWidth = 91;
    const double thicknessPanelTopOffset = 0;
    const double thicknessPanelRightShift = 4;
    const double thicknessIconExtraWidth = 8;
    const double baseBottomActionIconGap = 35;
    const double baseBottomActionTopGap = 24;
    const int toolCount = 8;

    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_isLayoutThicknessPickerVisible ||
                  _isLayoutColorPickerVisible) {
                _closeLayoutToolPickers();
                return;
              }
              _closeLayoutImageViewer();
            },
            child: Container(
              color: Colors.black.withValues(alpha: 0.3),
            ),
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final availableWidth =
                    (constraints.maxWidth - (viewportPadding * 2)).clamp(
                  200.0,
                  double.infinity,
                );
                final availableHeight =
                    (constraints.maxHeight - (viewportPadding * 2)).clamp(
                  200.0,
                  double.infinity,
                );
                final mainAreaAvailableHeight = max(
                  200.0,
                  availableHeight -
                      (baseCloseIconSize + baseCloseIconGapToPen) -
                      baseBottomActionTopGap -
                      baseOptionHeight,
                );
                final maxImageWidth = max(
                  200.0,
                  availableWidth - railGapFromImage - baseOptionWidth,
                );
                final scale = min(
                  1.0,
                  min(
                    maxImageWidth / baseImageBoxWidth,
                    mainAreaAvailableHeight / baseImageBoxHeight,
                  ),
                );
                final imageBoxWidth = baseImageBoxWidth * scale;
                final imageBoxHeight = baseImageBoxHeight * scale;
                final baseSideRailHeight = baseCloseIconSize +
                    baseCloseIconGapToPen +
                    (baseOptionHeight * toolCount) +
                    (baseOptionGap * (toolCount - 1));
                final sideToolScale =
                    min(1.0, imageBoxHeight / baseSideRailHeight);
                final optionWidth = baseOptionWidth * sideToolScale;
                final optionHeight = baseOptionHeight * sideToolScale;
                final optionGap = baseOptionGap * sideToolScale;
                final closeIconSize = baseCloseIconSize * sideToolScale;
                final closeIconGapToPen = baseCloseIconGapToPen * sideToolScale;
                final bottomActionIconWidth = optionWidth;
                final bottomActionIconHeight = optionHeight;
                final bottomActionIconGap =
                    baseBottomActionIconGap * sideToolScale;
                final bottomActionTopGap =
                    baseBottomActionTopGap * sideToolScale;
                final thicknessIconExpandedWidth =
                    optionWidth + (thicknessIconExtraWidth * sideToolScale);
                final railBaseHeight =
                    (optionHeight * toolCount) + (optionGap * (toolCount - 1));
                final closeTopInset = closeIconSize + closeIconGapToPen;
                final viewerMainHeight = max(imageBoxHeight, railBaseHeight);
                final viewerHeight = closeTopInset +
                    viewerMainHeight +
                    bottomActionTopGap +
                    bottomActionIconHeight;
                final railTopInset = (viewerMainHeight - railBaseHeight) / 2;
                final imageTopInset =
                    max(0.0, (viewerMainHeight - imageBoxHeight) / 2);
                double toolTop(int toolIndex) =>
                    closeTopInset +
                    railTopInset +
                    ((optionHeight + optionGap) * toolIndex);
                final closeIconRightInset = (optionWidth - closeIconSize) / 2;

                return Center(
                  child: GestureDetector(
                    onTap: () {},
                    child: SizedBox(
                      width: imageBoxWidth + railGapFromImage + optionWidth,
                      height: viewerHeight,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            top: closeTopInset,
                            left: 0,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _closeLayoutToolPickers,
                                  child: Container(
                                    width: imageBoxWidth,
                                    height: imageBoxHeight,
                                    clipBehavior: Clip.hardEdge,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Listener(
                                      behavior: HitTestBehavior.opaque,
                                      onPointerDown: (details) {
                                        _closeLayoutToolPickers();
                                        _handleLayoutViewerPointerDown(
                                          details: details,
                                          canvasSize: Size(
                                              imageBoxWidth, imageBoxHeight),
                                        );
                                      },
                                      onPointerMove: (details) {
                                        _handleLayoutViewerPointerMove(
                                          details: details,
                                          canvasSize: Size(
                                              imageBoxWidth, imageBoxHeight),
                                        );
                                      },
                                      onPointerUp: (details) {
                                        _handleLayoutViewerPointerUpOrCancel(
                                          pointerId: details.pointer,
                                        );
                                      },
                                      onPointerCancel: (details) {
                                        _handleLayoutViewerPointerUpOrCancel(
                                          pointerId: details.pointer,
                                        );
                                      },
                                      child: InteractiveViewer(
                                        transformationController:
                                            _layoutImageViewerController,
                                        minScale: 0.5,
                                        maxScale: 4.0,
                                        panEnabled: !_isLayoutPenModeActive &&
                                            !_isLayoutEraserModeActive,
                                        scaleEnabled: !_isLayoutPenModeActive &&
                                            !_isLayoutEraserModeActive,
                                        clipBehavior: Clip.hardEdge,
                                        child: SizedBox(
                                          width: imageBoxWidth,
                                          height: imageBoxHeight,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              Image.network(
                                                _activeLayoutImageUrl,
                                                fit: BoxFit.contain,
                                                alignment: Alignment.center,
                                                loadingBuilder: (context, child,
                                                    loadingProgress) {
                                                  if (loadingProgress == null) {
                                                    return child;
                                                  }
                                                  return const Center(
                                                    child: SizedBox(
                                                      width: 28,
                                                      height: 28,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2.5,
                                                        color:
                                                            Color(0xFF0C8CE9),
                                                      ),
                                                    ),
                                                  );
                                                },
                                                errorBuilder: (
                                                  context,
                                                  error,
                                                  stackTrace,
                                                ) {
                                                  return Center(
                                                    child: Text(
                                                      'Unable to load layout image.',
                                                      style: GoogleFonts.inter(
                                                        color: Colors.black,
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                              IgnorePointer(
                                                child: CustomPaint(
                                                  painter:
                                                      _DocumentLayoutViewerStrokesPainter(
                                                    strokes:
                                                        _layoutViewerStrokes,
                                                    repaint:
                                                        _layoutViewerPaintVersion,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: railGapFromImage),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildLayoutImageViewerToolButton(
                                      iconAssetPath: _isLayoutPenModeActive
                                          ? 'assets/images/Pen_active.svg'
                                          : 'assets/images/Pen.svg',
                                      onTap: () {
                                        _closeLayoutToolPickers();
                                        _toggleLayoutPenMode();
                                      },
                                      width: optionWidth,
                                      height: optionHeight,
                                    ),
                                    SizedBox(height: optionGap),
                                    Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        SizedBox(
                                          width: optionWidth,
                                          height: optionHeight,
                                          child: Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Positioned(
                                                right: 0,
                                                top: 0,
                                                child: _isLayoutThicknessPickerVisible &&
                                                        !_isLayoutThicknessPickerForEraser
                                                    ? GestureDetector(
                                                        onTap: () {
                                                          final shouldClose =
                                                              _isLayoutThicknessPickerVisible &&
                                                                  !_isLayoutThicknessPickerForEraser;
                                                          _setLayoutThicknessPickerVisible(
                                                            !shouldClose,
                                                          );
                                                        },
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        child: SizedBox(
                                                          width:
                                                              thicknessIconExpandedWidth,
                                                          height: optionHeight,
                                                          child: ClipRRect(
                                                            borderRadius:
                                                                const BorderRadius
                                                                    .only(
                                                              topRight: Radius
                                                                  .circular(16),
                                                              bottomRight:
                                                                  Radius
                                                                      .circular(
                                                                          16),
                                                            ),
                                                            child: SvgPicture
                                                                .asset(
                                                              'assets/images/Thickness_open.svg',
                                                              fit: BoxFit.fill,
                                                            ),
                                                          ),
                                                        ),
                                                      )
                                                    : _buildLayoutImageViewerToolButton(
                                                        iconAssetPath:
                                                            'assets/images/Thickness.svg',
                                                        onTap: () {
                                                          final shouldClose =
                                                              _isLayoutThicknessPickerVisible &&
                                                                  !_isLayoutThicknessPickerForEraser;
                                                          _setLayoutThicknessPickerVisible(
                                                            !shouldClose,
                                                          );
                                                        },
                                                        width: optionWidth,
                                                        height: optionHeight,
                                                      ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: optionGap),
                                    Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        SizedBox(
                                          width: optionWidth,
                                          height: optionHeight,
                                          child: Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Positioned(
                                                right: 0,
                                                top: 0,
                                                child: _isLayoutColorPickerVisible
                                                    ? GestureDetector(
                                                        onTap: () {
                                                          final shouldClose =
                                                              _isLayoutColorPickerVisible;
                                                          _setLayoutColorPickerVisible(
                                                            !shouldClose,
                                                          );
                                                        },
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        child: SizedBox(
                                                          width:
                                                              thicknessIconExpandedWidth,
                                                          height: optionHeight,
                                                          child: ClipRRect(
                                                            borderRadius:
                                                                const BorderRadius
                                                                    .only(
                                                              topRight: Radius
                                                                  .circular(16),
                                                              bottomRight:
                                                                  Radius
                                                                      .circular(
                                                                          16),
                                                            ),
                                                            child: SvgPicture
                                                                .asset(
                                                              'assets/images/Color_open.svg',
                                                              fit: BoxFit.fill,
                                                            ),
                                                          ),
                                                        ),
                                                      )
                                                    : _buildLayoutImageViewerToolButton(
                                                        iconAssetPath:
                                                            'assets/images/Color.svg',
                                                        onTap: () {
                                                          final shouldClose =
                                                              _isLayoutColorPickerVisible;
                                                          _setLayoutColorPickerVisible(
                                                            !shouldClose,
                                                          );
                                                        },
                                                        width: optionWidth,
                                                        height: optionHeight,
                                                      ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: optionGap),
                                    Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        SizedBox(
                                          width: optionWidth,
                                          height: optionHeight,
                                          child: Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Positioned(
                                                right: 0,
                                                top: 0,
                                                child: (_isLayoutThicknessPickerVisible &&
                                                        _isLayoutThicknessPickerForEraser)
                                                    ? GestureDetector(
                                                        onTap: () {
                                                          _activateLayoutEraserMode();
                                                          final shouldClose =
                                                              _isLayoutThicknessPickerVisible &&
                                                                  _isLayoutThicknessPickerForEraser;
                                                          _setLayoutThicknessPickerVisible(
                                                            !shouldClose,
                                                            forEraser: true,
                                                          );
                                                        },
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        child: SizedBox(
                                                          width:
                                                              thicknessIconExpandedWidth,
                                                          height: optionHeight,
                                                          child: ClipRRect(
                                                            borderRadius:
                                                                const BorderRadius
                                                                    .only(
                                                              topRight: Radius
                                                                  .circular(16),
                                                              bottomRight:
                                                                  Radius
                                                                      .circular(
                                                                          16),
                                                            ),
                                                            child: SvgPicture
                                                                .asset(
                                                              'assets/images/Eraser_open.svg',
                                                              fit: BoxFit.fill,
                                                            ),
                                                          ),
                                                        ),
                                                      )
                                                    : _buildLayoutImageViewerToolButton(
                                                        iconAssetPath:
                                                            'assets/images/Eraser.svg',
                                                        onTap: () {
                                                          _activateLayoutEraserMode();
                                                          final shouldClose =
                                                              _isLayoutThicknessPickerVisible &&
                                                                  _isLayoutThicknessPickerForEraser;
                                                          _setLayoutThicknessPickerVisible(
                                                            !shouldClose,
                                                            forEraser: true,
                                                          );
                                                        },
                                                        width: optionWidth,
                                                        height: optionHeight,
                                                      ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: optionGap),
                                    _buildLayoutImageViewerToolButton(
                                      iconAssetPath:
                                          'assets/images/Zoom in.svg',
                                      onTap: () {
                                        _closeLayoutToolPickers();
                                        _zoomLayoutImageViewerByStep(0.1);
                                      },
                                      width: optionWidth,
                                      height: optionHeight,
                                    ),
                                    SizedBox(height: optionGap),
                                    _buildLayoutImageViewerToolButton(
                                      iconAssetPath:
                                          'assets/images/Zoom out.svg',
                                      onTap: () {
                                        _closeLayoutToolPickers();
                                        _zoomLayoutImageViewerByStep(-0.1);
                                      },
                                      width: optionWidth,
                                      height: optionHeight,
                                    ),
                                    SizedBox(height: optionGap),
                                    _buildLayoutImageViewerToolButton(
                                      iconAssetPath: _isLayoutPanModeActive
                                          ? 'assets/images/Pan_active.svg'
                                          : 'assets/images/Pan.svg',
                                      onTap: () {
                                        _closeLayoutToolPickers();
                                        _activateLayoutPanMode();
                                      },
                                      width: optionWidth,
                                      height: optionHeight,
                                    ),
                                    SizedBox(height: optionGap),
                                    _buildLayoutImageViewerToolButton(
                                      iconAssetPath:
                                          'assets/images/Delete_image.svg',
                                      onTap: () {
                                        _closeLayoutToolPickers();
                                        unawaited(_deleteActiveLayoutImage());
                                      },
                                      width: optionWidth,
                                      height: optionHeight,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            top: toolTop(0) - closeIconGapToPen - closeIconSize,
                            right: closeIconRightInset,
                            child: _buildLayoutImageViewerToolButton(
                              iconAssetPath: 'assets/images/Layout_close.svg',
                              onTap: _closeLayoutImageViewer,
                              width: closeIconSize,
                              height: closeIconSize,
                            ),
                          ),
                          if (_isLayoutThicknessPickerVisible &&
                              !_isLayoutThicknessPickerForEraser)
                            Positioned(
                              right: thicknessIconExpandedWidth -
                                  thicknessPanelRightShift,
                              top: toolTop(1) + thicknessPanelTopOffset,
                              child: _buildLayoutThicknessPicker(
                                panelWidth: thicknessPanelWidth,
                                optionColor: Colors.black,
                                selectedIndex: _selectedLayoutThicknessIndex,
                                onOptionTap: _selectLayoutThicknessOption,
                              ),
                            ),
                          if (_isLayoutColorPickerVisible)
                            Positioned(
                              right: thicknessIconExpandedWidth -
                                  thicknessPanelRightShift,
                              top: toolTop(2) + thicknessPanelTopOffset,
                              child: _buildLayoutColorPicker(
                                panelWidth: thicknessPanelWidth,
                              ),
                            ),
                          if (_isLayoutThicknessPickerVisible &&
                              _isLayoutThicknessPickerForEraser)
                            Positioned(
                              right: thicknessIconExpandedWidth -
                                  thicknessPanelRightShift,
                              top: toolTop(3) + thicknessPanelTopOffset,
                              child: _buildLayoutThicknessPicker(
                                panelWidth: thicknessPanelWidth,
                                optionColor:
                                    Colors.black.withValues(alpha: 0.5),
                                selectedIndex:
                                    _selectedLayoutEraserThicknessIndex,
                                onOptionTap: _selectLayoutEraserThicknessOption,
                              ),
                            ),
                          Positioned(
                            right: railGapFromImage + optionWidth,
                            top: closeTopInset +
                                imageTopInset +
                                imageBoxHeight +
                                bottomActionTopGap,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildLayoutImageViewerToolButton(
                                  iconAssetPath:
                                      'assets/images/Download_doc.svg',
                                  onTap: _downloadActiveLayoutImage,
                                  width: bottomActionIconWidth,
                                  height: bottomActionIconHeight,
                                ),
                                SizedBox(width: bottomActionIconGap),
                                _buildLayoutImageViewerToolButton(
                                  iconAssetPath: 'assets/images/Print doc.svg',
                                  onTap: _printActiveLayoutImage,
                                  width: bottomActionIconWidth,
                                  height: bottomActionIconHeight,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _downloadDocuments() async {
    try {
      if (widget.projectId == null) {
        debugPrint('No project ID available');
        return;
      }

      // Get project name from database
      final projectResponse = await _supabase
          .from('projects')
          .select('project_name')
          .eq('id', widget.projectId!)
          .single();

      final projectName =
          projectResponse['project_name'] as String? ?? 'project';

      // Get ALL files in the project (not just current folder)
      final allFiles =
          _documents.where((doc) => doc['type'] == 'file').toList();

      if (allFiles.isEmpty) {
        debugPrint('No files to download');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No files to download')),
        );
        return;
      }

      // Calculate total size
      int totalSize = 0;
      for (var file in allFiles) {
        totalSize += (file['file_size'] as int? ?? 0);
      }

      debugPrint('Downloading ${allFiles.length} files...');

      // Show confirmation dialog
      final shouldDownload = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (context) => _DownloadAllDialog(
          projectName: projectName,
          totalSize: totalSize,
        ),
      );

      if (shouldDownload != true) {
        return;
      }

      // Show loading indicator
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      // Create a zip archive
      final archive = Archive();
      int successCount = 0;

      for (var file in allFiles) {
        try {
          final urlOrPath = file['url'] as String?;
          if (urlOrPath == null || urlOrPath.isEmpty) continue;

          String storagePath;
          if (urlOrPath.startsWith('http')) {
            // Extract path from full URL
            final parts = urlOrPath.split('/documents/');
            if (parts.length > 1) {
              storagePath = parts[1];
            } else {
              continue;
            }
          } else {
            storagePath = urlOrPath;
          }

          // Download file data from storage
          final fileData =
              await _supabase.storage.from('documents').download(storagePath);

          // Get the full path including folder hierarchy
          final filePathInZip = _getFilePathInZip(file);

          // Add file to archive with full folder path
          archive
              .addFile(ArchiveFile(filePathInZip, fileData.length, fileData));

          successCount++;
          debugPrint(
              'Added $filePathInZip to archive ($successCount/${allFiles.length})');
        } catch (e) {
          debugPrint('Error downloading file ${file['name']}: $e');
        }
      }

      // Close loading dialog
      if (mounted) Navigator.of(context).pop();

      if (successCount == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to download files')),
          );
        }
        return;
      }

      // Encode archive to zip
      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) {
        debugPrint('Failed to create zip file');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to create zip file')),
          );
        }
        return;
      }

      // Create blob and trigger download
      final blob = html.Blob([zipData], 'application/zip');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url)
        ..download = '$projectName.zip'
        ..click();

      html.Url.revokeObjectUrl(url);

      debugPrint(
          'Download initiated: $projectName.zip with $successCount files');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Downloaded $successCount files as $projectName.zip')),
        );
      }
    } catch (e) {
      debugPrint('Error downloading documents: $e');
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog if open
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _createFolder() {
    _addFolder('Untitled folder');
  }

  void _filterDocuments() {
    if (!mounted) return;

    final currentContext = _filterButtonKey.currentContext;
    if (currentContext == null) {
      debugPrint('Filter button context not available yet');
      return;
    }

    final renderBox = currentContext.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      debugPrint('Filter button render box not available');
      return;
    }

    final position = renderBox.localToGlobal(Offset.zero);
    final buttonHeight = renderBox.size.height;

    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (context) => _FilterDialog(
        currentSort: _sortOrder,
        buttonPosition: position,
        buttonHeight: buttonHeight,
        onSortChanged: (sortOrder) {
          setState(() {
            _sortOrder = sortOrder;
          });
        },
      ),
    );
  }

  List<Map<String, dynamic>> get _filteredDocuments {
    final query = _searchQuery.trim().toLowerCase();
    final currentContents = _getContentsOfFolder(_currentFolderId);

    // Apply sorting
    final sorted = List<Map<String, dynamic>>.from(currentContents);
    if (_sortOrder == 'created') {
      sorted.sort((a, b) {
        final aDate = a['uploadedLabel'] as String? ?? '';
        final bDate = b['uploadedLabel'] as String? ?? '';
        return bDate.compareTo(aDate); // Newest first
      });
    } else if (_sortOrder == 'updated') {
      sorted.sort((a, b) {
        final aDate =
            a['updatedLabel'] as String? ?? a['uploadedLabel'] as String? ?? '';
        final bDate =
            b['updatedLabel'] as String? ?? b['uploadedLabel'] as String? ?? '';
        return bDate.compareTo(aDate); // Newest first
      });
    }

    if (query.isEmpty) return sorted;

    return currentContents
        .where((doc) =>
            (doc['name']?.toString().toLowerCase() ?? '').contains(query))
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  void _openFolder(String folderId) {
    if (folderId.isEmpty) return;
    setState(() {
      _currentFolderId = folderId;
      _showAddFolderDialog = false;
    });
  }

  void _goBack() {
    setState(() {
      if (_currentFolderId != null) {
        final currentFolder = _documents.firstWhere(
          (doc) => doc['id'] == _currentFolderId,
          orElse: () => {},
        );
        _currentFolderId = currentFolder['parentId'];
      }
    });
  }

  List<Map<String, dynamic>> _getFolderPath(String? folderId) {
    final path = <Map<String, dynamic>>[];
    var currentId = folderId;

    while (currentId != null && currentId.isNotEmpty) {
      final folder = _documents.firstWhere(
        (doc) => doc['id'] == currentId,
        orElse: () => <String, dynamic>{},
      );
      if (folder.isEmpty) break;
      path.insert(0, folder);
      currentId = folder['parentId']?.toString();
    }

    return path;
  }

  void _openBreadcrumbFolder(String? folderId) {
    setState(() {
      _currentFolderId = folderId;
      _showAddFolderDialog = false;
    });
  }

  List<Map<String, dynamic>> _getContentsOfFolder(String? folderId) {
    return _documents.where((doc) => doc['parentId'] == folderId).toList();
  }

  bool _isPinnedRootFolder(Map<String, dynamic> doc) {
    if ((doc['type'] ?? '').toString().toLowerCase() != 'folder') return false;
    final normalizedName = (doc['name'] ?? '').toString().trim().toLowerCase();
    return _pinnedRootFolderOrder
        .any((name) => name.toLowerCase() == normalizedName);
  }

  List<Map<String, dynamic>> _arrangeDocumentsForDisplay(
      List<Map<String, dynamic>> source) {
    if (_currentFolderId != null) return source;

    final docs = List<Map<String, dynamic>>.from(source);
    final pinnedByName = <String, Map<String, dynamic>>{};
    final others = <Map<String, dynamic>>[];

    for (final doc in docs) {
      if (_isPinnedRootFolder(doc)) {
        final key = (doc['name'] ?? '').toString().trim().toLowerCase();
        pinnedByName.putIfAbsent(key, () => doc);
      } else {
        others.add(doc);
      }
    }

    final pinnedOrdered = <Map<String, dynamic>>[];
    for (final folderName in _pinnedRootFolderOrder) {
      final found = pinnedByName[folderName.toLowerCase()];
      if (found != null) pinnedOrdered.add(found);
    }

    return <Map<String, dynamic>>[...pinnedOrdered, ...others];
  }

  int _leadingPinnedRootFolderCount(List<Map<String, dynamic>> docs) {
    if (_currentFolderId != null) return 0;
    var count = 0;
    for (final doc in docs) {
      if (_isPinnedRootFolder(doc)) {
        count++;
      } else {
        break;
      }
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final uploadingDocuments = _activeUploads.values
        .where((u) =>
            !u.isCanceled &&
            !u.isCompleted &&
            !u.isFailed &&
            u.parentId == _currentFolderId &&
            (_searchQuery.isEmpty ||
                u.fileName.toLowerCase().contains(_searchQuery.toLowerCase())))
        .map((u) => <String, dynamic>{
              'id': 'upload-${u.id}',
              'name': u.fileName,
              'type': 'file',
              'extension': u.extension,
              'uploadedLabel': 'Uploading...',
              'updatedLabel': '',
              'url': '',
              'isUploading': true,
            })
        .toList();

    final documents = _arrangeDocumentsForDisplay(
      [..._filteredDocuments, ...uploadingDocuments],
    );
    final selectableDocuments = documents
        .where(
          (doc) => !(_currentFolderId == null && _isPinnedRootFolder(doc)),
        )
        .toList();
    final leadingPinnedRootFolderCount =
        _leadingPinnedRootFolderCount(documents);
    final forcePinnedFoldersToFirstRow = _currentFolderId == null &&
        leadingPinnedRootFolderCount > 0 &&
        documents.length > leadingPinnedRootFolderCount;
    final folderPath = _getFolderPath(_currentFolderId);
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleMetrics = AppScaleMetrics.of(context);
    final tabLineWidth = (scaleMetrics?.designViewportWidth ?? screenWidth) +
        (scaleMetrics?.rightOverflowWidth ?? 0.0);
    final extraTabLineWidth =
        tabLineWidth > screenWidth ? tabLineWidth - screenWidth : 0.0;

    // Calculate storage usage
    final totalStorage = 1 * 1024 * 1024 * 1024; // 1 GB in bytes
    int usedStorage = 0;
    for (var doc in _documents) {
      if (doc['type'] == 'file') {
        usedStorage += (doc['file_size'] as int? ?? 0);
      }
    }
    final storagePercentage =
        (usedStorage / totalStorage * 100).clamp(0.0, 100.0);

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 24, left: 24, right: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Documents',
                          style: GoogleFonts.inter(
                            fontSize: 32,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                            height: 40 / 32,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Upload and manage all project-related documents in one place.',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w400,
                            color: Colors.black.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Transform.translate(
                    offset: Offset(extraTabLineWidth, 0),
                    child: _StorageIndicator(
                      usedStorage: usedStorage,
                      totalStorage: totalStorage,
                      percentage: storagePercentage,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (!_isLoading) ...[
              _buildDocumentsActionRow(documents, extraTabLineWidth),
              _buildDocumentsTabLine(extraTabLineWidth),
            ],
            Expanded(
              child: _isLoading
                  ? _buildDocumentsLoadingSkeleton()
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 24),
                          if (_currentFolderId != null) ...[
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              child: Row(
                                children: [
                                  InkWell(
                                    onTap: _goBack,
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.arrow_back,
                                          size: 16,
                                          color: Colors.black,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Back',
                                          style: GoogleFonts.inter(
                                            fontSize: 20,
                                            fontWeight: FontWeight.normal,
                                            color: Colors.black,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    InkWell(
                                      onTap: () => _openBreadcrumbFolder(null),
                                      child: Text(
                                        _isSelectMode
                                            ? 'Selected(${_selectedDocumentIds.length})'
                                            : 'All Documents',
                                        style: GoogleFonts.inter(
                                          fontSize: _currentFolderId == null
                                              ? 20
                                              : 14,
                                          fontWeight: _currentFolderId == null
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                          color: _currentFolderId == null
                                              ? Colors.black
                                              : Colors.black.withOpacity(0.5),
                                        ),
                                      ),
                                    ),
                                    for (int i = 0;
                                        i < folderPath.length;
                                        i++) ...[
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4),
                                        child: Icon(
                                          Icons.chevron_right,
                                          size: 14,
                                          color: Colors.black.withOpacity(0.5),
                                        ),
                                      ),
                                      InkWell(
                                        onTap: () => _openBreadcrumbFolder(
                                            folderPath[i]['id']?.toString()),
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                              maxWidth: 120),
                                          child: Text(
                                            (folderPath[i]['name'] ?? '')
                                                .toString(),
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.inter(
                                              fontSize: 14,
                                              fontWeight: FontWeight.normal,
                                              color: i == folderPath.length - 1
                                                  ? Colors.black
                                                  : Colors.black
                                                      .withOpacity(0.5),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (_isSelectMode) ...[
                                      const Spacer(),
                                      _SecondaryActionButton(
                                        label: _selectedDocumentIds.length ==
                                                    selectableDocuments
                                                        .length &&
                                                selectableDocuments.isNotEmpty
                                            ? 'Selected All'
                                            : 'Select All',
                                        trailing: SvgPicture.asset(
                                          'assets/images/select.svg',
                                          width: 16,
                                          height: 16,
                                          colorFilter: ColorFilter.mode(
                                            _selectedDocumentIds.length ==
                                                        selectableDocuments
                                                            .length &&
                                                    selectableDocuments
                                                        .isNotEmpty
                                                ? const Color(0xFF000000)
                                                : const Color(0xFF0C8CE9),
                                            BlendMode.srcIn,
                                          ),
                                        ),
                                        // Removed backgroundColor to inherit hover effect
                                        onTap: () {
                                          setState(() {
                                            if (_selectedDocumentIds.length ==
                                                selectableDocuments.length) {
                                              _selectedDocumentIds.clear();
                                            } else {
                                              _selectedDocumentIds.clear();
                                              for (var doc
                                                  in selectableDocuments) {
                                                _selectedDocumentIds.add(
                                                    (doc['id'] ?? '')
                                                        .toString());
                                              }
                                            }
                                          });
                                        },
                                      ),
                                      const SizedBox(width: 12),
                                      Opacity(
                                        opacity: _selectedDocumentIds.isEmpty
                                            ? 0.5
                                            : 1.0,
                                        child: IgnorePointer(
                                          ignoring:
                                              _selectedDocumentIds.isEmpty,
                                          child: _SecondaryActionButton(
                                            label: 'Delete',
                                            trailing: SvgPicture.asset(
                                              'assets/images/Delete_layout.svg',
                                              width: 16,
                                              height: 16,
                                              colorFilter:
                                                  const ColorFilter.mode(
                                                      Color(0xFFFF0000),
                                                      BlendMode.srcIn),
                                            ),
                                            onTap: _deleteSelectedFiles,
                                            textColor: const Color(
                                                0xFFFF0000), // Keep Delete text red
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 24),
                                if (documents.isEmpty) ...[
                                  if (_showAddFolderDialog)
                                    Wrap(
                                      spacing: 24,
                                      runSpacing: 24,
                                      children: [
                                        AddFolderDialog(
                                          onClose: () => setState(() =>
                                              _showAddFolderDialog = false),
                                          onCreate: _addFolder,
                                        ),
                                      ],
                                    )
                                  else
                                    _DocumentsEmptyState(
                                      onUpload: _uploadDocuments,
                                      onAddFolder: _createFolder,
                                    ),
                                ] else ...[
                                  Wrap(
                                    spacing: 24,
                                    runSpacing: 24,
                                    children: [
                                      for (int index = 0;
                                          index < documents.length;
                                          index++) ...[
                                        () {
                                          final doc = documents[index];
                                          final docExtension =
                                              _resolveDocumentExtension(
                                            Map<String, dynamic>.from(doc),
                                          );
                                          final isUploadingDoc =
                                              doc['isUploading'] == true;
                                          final isProtectedRootFolder =
                                              _currentFolderId == null &&
                                                  _isPinnedRootFolder(doc);
                                          final docId =
                                              (doc['id'] ?? '').toString();
                                          final isSelected =
                                              _selectedDocumentIds
                                                  .contains(docId);
                                          final backgroundColor = isSelected
                                              ? const Color(0xFFFF0000)
                                                  .withOpacity(0.1)
                                              : Colors.transparent;
                                          final folderFileCount =
                                              (doc['type'] ?? 'folder')
                                                          .toString() ==
                                                      'folder'
                                                  ? _documents
                                                      .where((item) =>
                                                          item['parentId'] ==
                                                          docId)
                                                      .length
                                                  : 0;

                                          // Unified tap logic for both folder and file
                                          return GestureDetector(
                                            behavior:
                                                HitTestBehavior.deferToChild,
                                            onTap: () {
                                              if (isUploadingDoc) return;
                                              if (_isSelectMode &&
                                                  isProtectedRootFolder) {
                                                return;
                                              }
                                              if (_isSelectMode) {
                                                setState(() {
                                                  if (isSelected) {
                                                    _selectedDocumentIds
                                                        .remove(docId);
                                                  } else {
                                                    _selectedDocumentIds
                                                        .add(docId);
                                                  }
                                                });
                                              } else {
                                                // Not in select mode: open folder or file
                                                if ((doc['type'] ?? 'folder')
                                                        .toString() ==
                                                    'folder') {
                                                  _openFolder(docId);
                                                } else {
                                                  _openDocumentFile(
                                                    Map<String, dynamic>.from(
                                                        doc),
                                                  );
                                                }
                                              }
                                            },
                                            child: Container(
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                color: backgroundColor,
                                              ),
                                              child: Stack(
                                                children: [
                                                  IgnorePointer(
                                                    ignoring: _isSelectMode ||
                                                        isUploadingDoc,
                                                    child: (doc['type'] ??
                                                                    'folder')
                                                                .toString() ==
                                                            'folder'
                                                        ? DocumentCard(
                                                            key: ValueKey(
                                                                'doc-$docId'),
                                                            isSelected:
                                                                isSelected,
                                                            isSelectMode:
                                                                _isSelectMode,
                                                            name:
                                                                (doc['name'] ??
                                                                        '')
                                                                    .toString(),
                                                            type: (doc['type'] ??
                                                                    'folder')
                                                                .toString(),
                                                            fileCount:
                                                                folderFileCount,
                                                            uploadedLabel: _sortOrder ==
                                                                    'created'
                                                                ? (doc['uploadedLabel'] ??
                                                                        '')
                                                                    .toString()
                                                                : '',
                                                            updatedLabel: _sortOrder ==
                                                                    'updated'
                                                                ? (doc['updatedLabel'] ??
                                                                        '')
                                                                    .toString()
                                                                : '',
                                                            folderId: docId,
                                                            autoRename:
                                                                _newlyCreatedFolderId ==
                                                                    docId,
                                                            onRename:
                                                                (newName) async {
                                                              try {
                                                                await _supabase
                                                                    .from(
                                                                        'documents')
                                                                    .update({
                                                                  'name':
                                                                      newName
                                                                }).eq('id',
                                                                        docId);
                                                                setState(() {
                                                                  final docIndex =
                                                                      _documents.indexWhere((item) =>
                                                                          item[
                                                                              'id'] ==
                                                                          docId);
                                                                  if (docIndex !=
                                                                      -1) {
                                                                    _documents[docIndex]
                                                                            [
                                                                            'name'] =
                                                                        newName;
                                                                    _documents[docIndex]
                                                                            [
                                                                            'updatedLabel'] =
                                                                        'Updated: ${_formatDate(DateTime.now())}';
                                                                  }
                                                                });
                                                              } catch (e) {
                                                                debugPrint(
                                                                    'Error renaming folder: $e');
                                                              }
                                                            },
                                                            onDelete: () async {
                                                              if (isProtectedRootFolder) {
                                                                return;
                                                              }
                                                              try {
                                                                await _supabase
                                                                    .from(
                                                                        'documents')
                                                                    .delete()
                                                                    .eq('id',
                                                                        docId);
                                                                setState(() {
                                                                  _documents.removeWhere(
                                                                      (item) =>
                                                                          item[
                                                                              'id'] ==
                                                                          docId);
                                                                  _documents.removeWhere(
                                                                      (item) =>
                                                                          item[
                                                                              'parentId'] ==
                                                                          docId);
                                                                });
                                                              } catch (e) {
                                                                debugPrint(
                                                                    'Error deleting folder: $e');
                                                              }
                                                            },
                                                            onDownload:
                                                                () async {
                                                              final folderName =
                                                                  doc['name'] ??
                                                                      'folder';
                                                              final folderId =
                                                                  doc['id'];
                                                              debugPrint(
                                                                  'Download folder: $folderName');
                                                              final files = _documents
                                                                  .where((item) =>
                                                                      item['parentId'] ==
                                                                          folderId &&
                                                                      item['type'] ==
                                                                          'file')
                                                                  .toList();
                                                              if (files
                                                                  .isEmpty) {
                                                                debugPrint(
                                                                    'No files found in folder $folderName');
                                                                return;
                                                              }
                                                              final archive =
                                                                  Archive();
                                                              for (final file
                                                                  in files) {
                                                                final fileUrl =
                                                                    file['url']
                                                                        as String?;
                                                                final fileName =
                                                                    file['name']
                                                                            as String? ??
                                                                        'file';
                                                                if (fileUrl !=
                                                                        null &&
                                                                    fileUrl
                                                                        .isNotEmpty) {
                                                                  try {
                                                                    final response = await html.HttpRequest.request(
                                                                        fileUrl,
                                                                        responseType:
                                                                            'arraybuffer');
                                                                    final bytes =
                                                                        response.response
                                                                            as ByteBuffer;
                                                                    archive.addFile(ArchiveFile(
                                                                        fileName,
                                                                        bytes
                                                                            .lengthInBytes,
                                                                        bytes
                                                                            .asUint8List()));
                                                                  } catch (e) {
                                                                    debugPrint(
                                                                        'Failed to fetch file $fileName: $e');
                                                                  }
                                                                }
                                                              }
                                                              final zipData =
                                                                  ZipEncoder()
                                                                      .encode(
                                                                          archive);
                                                              if (zipData !=
                                                                  null) {
                                                                final blob =
                                                                    html.Blob([
                                                                  zipData
                                                                ], 'application/zip');
                                                                final url = html
                                                                        .Url
                                                                    .createObjectUrlFromBlob(
                                                                        blob);
                                                                final anchor = html
                                                                    .AnchorElement(
                                                                        href:
                                                                            url)
                                                                  ..download =
                                                                      '$folderName.zip'
                                                                  ..target =
                                                                      'blank';
                                                                html.document
                                                                    .body!
                                                                    .append(
                                                                        anchor);
                                                                anchor.click();
                                                                anchor.remove();
                                                                html.Url
                                                                    .revokeObjectUrl(
                                                                        url);
                                                              }
                                                            },
                                                            onOpenFolder: () =>
                                                                _openFolder(
                                                                    docId),
                                                          )
                                                        : FileCard(
                                                            key: ValueKey(
                                                                'file-$docId'),
                                                            isUploading:
                                                                isUploadingDoc,
                                                            isSelected:
                                                                isSelected,
                                                            isSelectMode:
                                                                _isSelectMode,
                                                            name:
                                                                (doc['name'] ??
                                                                        '')
                                                                    .toString(),
                                                            extension:
                                                                docExtension,
                                                            iconPath:
                                                                _getFileIconPath(
                                                              docExtension,
                                                            ),
                                                            uploadedLabel:
                                                                (doc['uploadedLabel'] ??
                                                                        '')
                                                                    .toString(),
                                                            updatedLabel:
                                                                (doc['updatedLabel'] ??
                                                                        '')
                                                                    .toString(),
                                                            onRename:
                                                                (newName) async {
                                                              try {
                                                                await _supabase
                                                                    .from(
                                                                        'documents')
                                                                    .update({
                                                                  'name':
                                                                      newName
                                                                }).eq('id',
                                                                        docId);
                                                                setState(() {
                                                                  final docIndex =
                                                                      _documents.indexWhere((item) =>
                                                                          item[
                                                                              'id'] ==
                                                                          docId);
                                                                  if (docIndex !=
                                                                      -1) {
                                                                    _documents[docIndex]
                                                                            [
                                                                            'name'] =
                                                                        newName;
                                                                    _documents[docIndex]
                                                                            [
                                                                            'updatedLabel'] =
                                                                        'Updated: ${_formatDate(DateTime.now())}';
                                                                  }
                                                                });
                                                              } catch (e) {
                                                                debugPrint(
                                                                    'Error renaming file: $e');
                                                              }
                                                            },
                                                            onDelete: () async {
                                                              try {
                                                                final fileUrl =
                                                                    doc['url']
                                                                        as String?;
                                                                if (fileUrl !=
                                                                        null &&
                                                                    fileUrl
                                                                        .isNotEmpty) {
                                                                  final path = Uri
                                                                          .parse(
                                                                              fileUrl)
                                                                      .path
                                                                      .split(
                                                                          '/documents/')
                                                                      .last;
                                                                  await _supabase
                                                                      .storage
                                                                      .from(
                                                                          'documents')
                                                                      .remove([
                                                                    path
                                                                  ]);
                                                                }
                                                                await _supabase
                                                                    .from(
                                                                        'documents')
                                                                    .delete()
                                                                    .eq('id',
                                                                        docId);
                                                                setState(() {
                                                                  _documents.removeWhere(
                                                                      (item) =>
                                                                          item[
                                                                              'id'] ==
                                                                          docId);
                                                                });
                                                              } catch (e) {
                                                                debugPrint(
                                                                    'Error deleting file: $e');
                                                              }
                                                            },
                                                            onDownload:
                                                                () async {
                                                              final fileName =
                                                                  doc['name'] ??
                                                                      'file';
                                                              final fileUrl =
                                                                  doc['url']
                                                                      as String?;
                                                              if (fileUrl !=
                                                                      null &&
                                                                  fileUrl
                                                                      .isNotEmpty) {
                                                                debugPrint(
                                                                    'Download file: $fileName from $fileUrl');
                                                                final anchor = html
                                                                    .AnchorElement(
                                                                        href:
                                                                            fileUrl)
                                                                  ..download =
                                                                      fileName
                                                                  ..target =
                                                                      'blank';
                                                                html.document
                                                                    .body!
                                                                    .append(
                                                                        anchor);
                                                                anchor.click();
                                                                anchor.remove();
                                                              } else {
                                                                debugPrint(
                                                                    'File URL not found for $fileName');
                                                              }
                                                            },
                                                            onOpen: () {
                                                              _openDocumentFile(
                                                                Map<String,
                                                                        dynamic>.from(
                                                                    doc),
                                                              );
                                                            },
                                                          ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        }(),
                                        if (forcePinnedFoldersToFirstRow &&
                                            index ==
                                                leadingPinnedRootFolderCount -
                                                    1)
                                          const SizedBox(
                                            width: double.infinity,
                                            height: 0,
                                          ),
                                      ],
                                      if (_showAddFolderDialog)
                                        AddFolderDialog(
                                          onClose: () => setState(() =>
                                              _showAddFolderDialog = false),
                                          onCreate: _addFolder,
                                        ),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
        // Upload popup overlay (only show when clicked)
        if (_showUploadingPopup && _activeUploads.isNotEmpty)
          _UploadPopup(
            uploads: _activeUploads,
            onCancelUpload: _cancelUpload,
            onClose: _closeUploadPopup,
          ),
        // Uploaded popup overlay (only show when clicked)
        if (_showUploadedPopup && _completedUploads.isNotEmpty)
          _UploadedPopup(
            uploads: _completedUploads,
            onClose: _closeUploadedPopup,
          ),
      ],
    );
  }
}

class _DocumentLayoutViewerStroke {
  final List<Offset> normalizedPoints;
  final Color color;
  final double thickness;

  _DocumentLayoutViewerStroke({
    required this.normalizedPoints,
    required this.color,
    required this.thickness,
  });
}

class _DocumentLayoutViewerStrokesPainter extends CustomPainter {
  final List<_DocumentLayoutViewerStroke> strokes;

  const _DocumentLayoutViewerStrokesPainter({
    required this.strokes,
    Listenable? repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.normalizedPoints.isEmpty) continue;

      final strokePaint = Paint()
        ..color = stroke.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.0, stroke.thickness * 2)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      Offset denormalize(Offset point) => Offset(
            point.dx * size.width,
            point.dy * size.height,
          );

      if (stroke.normalizedPoints.length == 1) {
        final center = denormalize(stroke.normalizedPoints.first);
        final dotPaint = Paint()
          ..color = stroke.color
          ..style = PaintingStyle.fill;
        canvas.drawCircle(center, strokePaint.strokeWidth / 2, dotPaint);
        continue;
      }

      final path = Path()
        ..moveTo(
          stroke.normalizedPoints.first.dx * size.width,
          stroke.normalizedPoints.first.dy * size.height,
        );
      for (int i = 1; i < stroke.normalizedPoints.length; i++) {
        final point = denormalize(stroke.normalizedPoints[i]);
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(
      covariant _DocumentLayoutViewerStrokesPainter oldDelegate) {
    return true;
  }
}

class _DocumentsEmptyState extends StatelessWidget {
  final VoidCallback onUpload;
  final VoidCallback onAddFolder;

  const _DocumentsEmptyState({
    required this.onUpload,
    required this.onAddFolder,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          SvgPicture.asset(
            'assets/images/Document_active.svg',
            width: 65,
            height: 80,
            fit: BoxFit.contain,
            colorFilter:
                const ColorFilter.mode(Color(0xFF63B5F1), BlendMode.srcIn),
          ),
          const SizedBox(height: 24),
          Text(
            'No documents yet',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Upload files or create a new folder.',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _SecondaryActionButton(
                label: 'Upload',
                trailing: SvgPicture.asset(
                  'assets/images/upload_middle.svg',
                  width: 16,
                  height: 16,
                  colorFilter: const ColorFilter.mode(
                      Color(0xFF0C8CE9), BlendMode.srcIn),
                ),
                onTap: onUpload,
              ),
              const SizedBox(width: 24),
              _SecondaryActionButton(
                label: 'Add Folder',
                trailing: SvgPicture.asset(
                  'assets/images/add_middle.svg',
                  width: 16,
                  height: 16,
                  colorFilter: const ColorFilter.mode(
                      Color(0xFF0C8CE9), BlendMode.srcIn),
                ),
                onTap: onAddFolder,
              ),
            ],
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class DocumentCard extends StatefulWidget {
  final String name;
  final String type;
  final int fileCount;
  final String uploadedLabel;
  final String updatedLabel;
  final String folderId;
  final bool autoRename;
  final bool isSelected;
  final bool isSelectMode;
  final ValueChanged<String> onRename;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onOpenFolder;

  const DocumentCard({
    super.key,
    required this.name,
    required this.type,
    required this.fileCount,
    required this.uploadedLabel,
    required this.updatedLabel,
    required this.folderId,
    this.autoRename = false,
    this.isSelected = false,
    this.isSelectMode = false,
    required this.onRename,
    required this.onDownload,
    required this.onDelete,
    required this.onOpenFolder,
  });

  @override
  State<DocumentCard> createState() => _DocumentCardState();
}

enum _DocumentCardAction { rename, download, delete }

class _DocumentCardState extends State<DocumentCard> {
  bool _isHovered = false;
  bool _isDoubleClicked = false;
  bool _isRenaming = false;
  late final TextEditingController _nameController;
  final FocusNode _nameFocusNode = FocusNode();
  int? _lastTapTimestampMs;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
    if (widget.autoRename) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _beginRename();
      });
    }
  }

  @override
  void didUpdateWidget(covariant DocumentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isRenaming && widget.name != oldWidget.name) {
      _nameController.text = widget.name;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  void _beginRename() {
    setState(() => _isRenaming = true);
    _nameController
      ..text = widget.name
      ..selection =
          TextSelection(baseOffset: 0, extentOffset: widget.name.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocusNode.requestFocus();
    });
  }

  void _commitRename() {
    final newName = _nameController.text.trim();
    if (newName.isNotEmpty) {
      widget.onRename(newName);
    }
    setState(() => _isRenaming = false);
  }

  void _cancelRename() {
    setState(() {
      _isRenaming = false;
      _nameController.text = widget.name;
    });
  }

  void _handleTap() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastTapMs = _lastTapTimestampMs;
    _lastTapTimestampMs = nowMs;

    if (lastTapMs != null && nowMs - lastTapMs <= 300) {
      widget.onOpenFolder();
      _lastTapTimestampMs = null;
    }
  }

  Widget _threeDotsIcon() {
    return SizedBox(
      width: 14,
      height: 24,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: const [
          _Dot(),
          _Dot(),
          _Dot(),
        ],
      ),
    );
  }

  double _popupShiftX(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0;
    final screenWidth = MediaQuery.of(context).size.width;
    final cardCenterX =
        box.localToGlobal(Offset.zero).dx + (box.size.width / 2);
    final opensLeft = cardCenterX > (screenWidth * 0.40);
    return opensLeft ? 31.0 : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final metaLabel = widget.updatedLabel.isNotEmpty
        ? widget.updatedLabel
        : widget.uploadedLabel;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: _handleTap,
        onDoubleTap: () {
          setState(() => _isDoubleClicked = true);
          widget.onOpenFolder();
        },
        onDoubleTapCancel: () => setState(() => _isDoubleClicked = false),
        child: Container(
          width: 170,
          height: 180,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? const Color(0x1AFF0000)
                : _isDoubleClicked
                    ? const Color(0xFFD6D6D6) // double-click gray
                    : _isHovered
                        ? Colors.grey[100] // pure white
                        : Colors.white,
            // boxShadow removed for lighter appearance
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE0E0E0), width: 1),
            // boxShadow removed for lighter appearance
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: SizedBox(
                      width: 64,
                      height: 52,
                      child: Center(
                        child: SvgPicture.asset(
                          'assets/images/add_folderr.svg',
                          width: 44,
                          height: 52,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: double.infinity,
                      height: 40,
                      child: Center(
                        child: _isRenaming
                            ? Theme(
                                data: Theme.of(context).copyWith(
                                  textSelectionTheme:
                                      const TextSelectionThemeData(
                                    selectionColor: Color(0x4D0C8CE9),
                                    selectionHandleColor: Color(0xFF0C8CE9),
                                  ),
                                ),
                                child: TextField(
                                  controller: _nameController,
                                  focusNode: _nameFocusNode,
                                  textAlign: TextAlign.center,
                                  textAlignVertical: TextAlignVertical.center,
                                  minLines: 1,
                                  maxLines: 2,
                                  keyboardType: TextInputType.text,
                                  textInputAction: TextInputAction.done,
                                  cursorColor: Colors.black,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.deny(
                                        RegExp(r'\n'))
                                  ],
                                  selectionHeightStyle: BoxHeightStyle.tight,
                                  selectionWidthStyle: BoxWidthStyle.tight,
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: Colors.black,
                                    height: 1.0,
                                  ),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    disabledBorder: InputBorder.none,
                                    isDense: true,
                                    isCollapsed: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                  onSubmitted: (_) => _commitRename(),
                                  onEditingComplete: _commitRename,
                                ),
                              )
                            : Text(
                                widget.name,
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                  color: Colors.black,
                                  height: 1.0,
                                ),
                                maxLines: 2,
                                softWrap: true,
                                overflow: TextOverflow.clip,
                                textAlign: TextAlign.center,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 20,
                    child: Center(
                      child: Text(
                        '(${widget.fileCount}) Files',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.normal,
                          color: const Color(0xFF5C5C5C),
                          height: 1.67,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  SizedBox(
                    height: 20,
                    child: Center(
                      child: Text(
                        metaLabel,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.normal,
                          color: const Color(0xFF5C5C5C),
                          height: 1.67,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 0,
                right: -14,
                child: Material(
                  color: Colors.transparent,
                  child: widget.isSelectMode
                      ? Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          child: _threeDotsIcon(),
                        )
                      : Theme(
                          data: Theme.of(context).copyWith(
                            splashFactory: NoSplash.splashFactory,
                            highlightColor: Colors.transparent,
                            splashColor: Colors.transparent,
                          ),
                          child: PopupMenuButton<_DocumentCardAction>(
                            tooltip: '',
                            padding: EdgeInsets.zero,
                            position: PopupMenuPosition.under,
                            child: Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: _threeDotsIcon(),
                              ),
                            ),
                            offset: Offset(_popupShiftX(context), 0),
                            color: Colors.transparent,
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            enableFeedback: false,
                            onSelected: (action) {
                              switch (action) {
                                case _DocumentCardAction.rename:
                                  _beginRename();
                                  break;
                                case _DocumentCardAction.download:
                                  widget.onDownload();
                                  break;
                                case _DocumentCardAction.delete:
                                  widget.onDelete();
                                  break;
                              }
                            },
                            itemBuilder: (context) =>
                                <PopupMenuEntry<_DocumentCardAction>>[
                              PopupMenuItem(
                                enabled: false,
                                padding: EdgeInsets.zero,
                                child: Container(
                                  width: 197,
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8F9FA),
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x80000000),
                                        blurRadius: 2,
                                        offset: Offset(0, 0),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          _beginRename();
                                        },
                                        child: Container(
                                          height: 36,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x40000000),
                                                blurRadius: 2,
                                                offset: Offset(0, 0),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Rename',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.normal,
                                                  color: Colors.black,
                                                ),
                                              ),
                                              SvgPicture.asset(
                                                'assets/images/rename.svg',
                                                width: 20,
                                                height: 20,
                                                fit: BoxFit.contain,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          widget.onDownload();
                                        },
                                        child: Container(
                                          height: 36,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x40000000),
                                                blurRadius: 2,
                                                offset: Offset(0, 0),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Download',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.normal,
                                                  color: Colors.black,
                                                ),
                                              ),
                                              SvgPicture.asset(
                                                'assets/images/Download_all.svg',
                                                width: 16,
                                                height: 16,
                                                fit: BoxFit.contain,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          widget.onDelete();
                                        },
                                        child: Container(
                                          height: 36,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x40000000),
                                                blurRadius: 2,
                                                offset: Offset(0, 0),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Delete Folder',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.normal,
                                                  color: Colors.red,
                                                ),
                                              ),
                                              SvgPicture.asset(
                                                'assets/images/delete_folder.svg',
                                                width: 13,
                                                height: 16,
                                                fit: BoxFit.contain,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
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
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 5,
      height: 5,
      decoration: const BoxDecoration(
        color: Color(0xFF5C5C5C),
        shape: BoxShape.circle,
      ),
    );
  }
}

class FileCard extends StatefulWidget {
  final String name;
  final String extension;
  final String iconPath;
  final String uploadedLabel;
  final String updatedLabel;
  final bool isUploading;
  final bool isSelected;
  final bool isSelectMode;
  final ValueChanged<String> onRename;
  final VoidCallback onDelete;
  final VoidCallback onDownload;
  final VoidCallback onOpen;

  const FileCard({
    super.key,
    required this.name,
    required this.extension,
    required this.iconPath,
    required this.uploadedLabel,
    required this.updatedLabel,
    this.isUploading = false,
    this.isSelected = false,
    this.isSelectMode = false,
    required this.onRename,
    required this.onDelete,
    required this.onDownload,
    required this.onOpen,
  });

  @override
  State<FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<FileCard> {
  late TextEditingController _nameController;
  final FocusNode _nameFocusNode = FocusNode();
  bool _isRenaming = false;
  int? _lastTapTimestampMs;
  bool _isHovered = false;
  bool _isDoubleClicked = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
  }

  @override
  void didUpdateWidget(covariant FileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isRenaming && widget.name != oldWidget.name) {
      _nameController.text = widget.name;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  void _beginRename() {
    setState(() => _isRenaming = true);
    _nameController
      ..text = widget.name
      ..selection =
          TextSelection(baseOffset: 0, extentOffset: widget.name.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocusNode.requestFocus();
    });
  }

  void _commitRename() {
    final newName = _nameController.text.trim();
    if (newName.isNotEmpty) {
      widget.onRename(newName);
    }
    setState(() => _isRenaming = false);
  }

  void _cancelRename() {
    setState(() {
      _isRenaming = false;
      _nameController.text = widget.name;
    });
  }

  void _handleTap() {
    if (widget.isUploading) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTapTimestampMs != null && (now - _lastTapTimestampMs!) < 500) {
      setState(() => _isDoubleClicked = true);
      widget.onOpen();
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) setState(() => _isDoubleClicked = false);
      });
      _lastTapTimestampMs = null;
    } else {
      _lastTapTimestampMs = now;
    }
  }

  Widget _threeDotsIcon() {
    return SizedBox(
      width: 14,
      height: 24,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: const [
          _Dot(),
          _Dot(),
          _Dot(),
        ],
      ),
    );
  }

  double _popupShiftX(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0;
    final screenWidth = MediaQuery.of(context).size.width;
    final cardCenterX =
        box.localToGlobal(Offset.zero).dx + (box.size.width / 2);
    final opensLeft = cardCenterX > (screenWidth * 0.40);
    return opensLeft ? 31.0 : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: _handleTap,
        child: Opacity(
          opacity: widget.isUploading ? 0.5 : 1.0,
          child: Container(
            width: 170,
            height: 180,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? const Color(0x1AFF0000)
                  : _isDoubleClicked
                      ? const Color(0xFFD6D6D6) // double-click gray
                      : _isHovered
                          ? Colors.grey[100] // bright gray
                          : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE0E0E0), width: 1),
              // boxShadow removed for lighter appearance
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: SizedBox(
                        width: 64,
                        height: 52,
                        child: Center(
                          child: SvgPicture.asset(
                            widget.iconPath,
                            width: 44,
                            height: 52,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: double.infinity,
                        height: 40,
                        child: Container(
                          alignment: Alignment.center,
                          decoration: _isRenaming
                              ? const BoxDecoration(color: Color(0x290C8CE9))
                              : null,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: _isRenaming
                              ? Theme(
                                  data: Theme.of(context).copyWith(
                                    textSelectionTheme:
                                        const TextSelectionThemeData(
                                      selectionColor: Color(0x4D0C8CE9),
                                      selectionHandleColor: Color(0xFF0C8CE9),
                                    ),
                                  ),
                                  child: TextField(
                                    controller: _nameController,
                                    focusNode: _nameFocusNode,
                                    textAlign: TextAlign.center,
                                    textAlignVertical: TextAlignVertical.center,
                                    minLines: 1,
                                    maxLines: 2,
                                    keyboardType: TextInputType.text,
                                    textInputAction: TextInputAction.done,
                                    cursorColor: Colors.black,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.deny(
                                          RegExp(r'\n'))
                                    ],
                                    selectionHeightStyle: BoxHeightStyle.tight,
                                    selectionWidthStyle: BoxWidthStyle.tight,
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.black,
                                      height: 1.0,
                                    ),
                                    decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      disabledBorder: InputBorder.none,
                                      isDense: true,
                                      isCollapsed: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                    onSubmitted: (_) => _commitRename(),
                                    onEditingComplete: _commitRename,
                                  ),
                                )
                              : Text(
                                  widget.name,
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: Colors.black,
                                    height: 1.0,
                                  ),
                                  maxLines: 2,
                                  softWrap: true,
                                  overflow: TextOverflow.clip,
                                  textAlign: TextAlign.center,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 20,
                      child: Center(
                        child: Text(
                          widget.updatedLabel.isNotEmpty
                              ? widget.updatedLabel
                              : widget.uploadedLabel,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.normal,
                            color: const Color(0xFF5C5C5C),
                            height: 1.67,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
                Positioned(
                  top: 0,
                  right: -14,
                  child: Material(
                    color: Colors.transparent,
                    child: widget.isSelectMode || widget.isUploading
                        ? Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            child: _threeDotsIcon(),
                          )
                        : PopupMenuButton<String>(
                            tooltip: '',
                            padding: EdgeInsets.zero,
                            position: PopupMenuPosition.under,
                            child: Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: _threeDotsIcon(),
                              ),
                            ),
                            offset: Offset(_popupShiftX(context), 0),
                            color: Colors.transparent,
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            onSelected: (action) {
                              switch (action) {
                                case 'rename':
                                  _beginRename();
                                  break;
                                case 'download':
                                  widget.onDownload();
                                  break;
                                case 'delete':
                                  widget.onDelete();
                                  break;
                              }
                            },
                            itemBuilder: (context) => <PopupMenuEntry<String>>[
                              PopupMenuItem(
                                enabled: false,
                                padding: EdgeInsets.zero,
                                child: Container(
                                  width: 197,
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8F9FA),
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x80000000),
                                        blurRadius: 2,
                                        offset: Offset(0, 0),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          _beginRename();
                                        },
                                        child: Container(
                                          height: 36,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x40000000),
                                                blurRadius: 2,
                                                offset: Offset(0, 0),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Rename',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.normal,
                                                  color: Colors.black,
                                                ),
                                              ),
                                              SvgPicture.asset(
                                                'assets/images/rename.svg',
                                                width: 20,
                                                height: 20,
                                                fit: BoxFit.contain,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          widget.onDownload();
                                        },
                                        child: Container(
                                          height: 36,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x40000000),
                                                blurRadius: 2,
                                                offset: Offset(0, 0),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Download',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.normal,
                                                  color: Colors.black,
                                                ),
                                              ),
                                              SvgPicture.asset(
                                                'assets/images/Download_all.svg',
                                                width: 16,
                                                height: 16,
                                                fit: BoxFit.contain,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          widget.onDelete();
                                        },
                                        child: Container(
                                          height: 36,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x40000000),
                                                blurRadius: 2,
                                                offset: Offset(0, 0),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Delete File',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.normal,
                                                  color: Colors.red,
                                                ),
                                              ),
                                              SvgPicture.asset(
                                                'assets/images/delete_folder.svg',
                                                width: 13,
                                                height: 16,
                                                fit: BoxFit.contain,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AddFolderDialog extends StatefulWidget {
  final VoidCallback onClose;
  final ValueChanged<String> onCreate;

  const AddFolderDialog({
    super.key,
    required this.onClose,
    required this.onCreate,
  });

  @override
  State<AddFolderDialog> createState() => _AddFolderDialogState();
}

class _AddFolderDialogState extends State<AddFolderDialog> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _create() {
    widget.onCreate(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 197,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E0E0), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 2,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: InkWell(
              onTap: widget.onClose,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 16),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: Center(
                child: SvgPicture.asset(
                  'assets/images/add_folderr.svg',
                  width: 52,
                  height: 64,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: Container(
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: Color(0x290C8CE9)),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                textAlign: TextAlign.center,
                textAlignVertical: TextAlignVertical.center,
                minLines: 1,
                maxLines: 2,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                cursorColor: Colors.black,
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'\n'))
                ],
                selectionHeightStyle: BoxHeightStyle.tight,
                selectionWidthStyle: BoxWidthStyle.tight,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                  height: 1.0,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Folder name',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black.withOpacity(0.5),
                  ),
                  isDense: true,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onSubmitted: (_) => _create(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 36,
            child: ElevatedButton(
              onPressed: _create,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0C8CE9),
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                'Create',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryActionButton extends StatelessWidget {
  final String label;
  final String? iconAssetPath;
  final Widget? iconWidget;
  final VoidCallback onTap;

  const _PrimaryActionButton({
    required this.label,
    this.iconAssetPath,
    this.iconWidget,
    required this.onTap,
  }) : assert(iconAssetPath != null || iconWidget != null,
            'Either iconAssetPath or iconWidget must be provided');

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF0C8CE9),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 1.75,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            iconWidget ??
                SvgPicture.asset(
                  iconAssetPath!,
                  width: 16,
                  height: 16,
                  colorFilter:
                      const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                ),
          ],
        ),
      ),
    );
  }
}

class _SecondaryActionButton extends StatefulWidget {
  final String label;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback onTap;
  final Color? backgroundColor;
  final Color? textColor;

  const _SecondaryActionButton({
    super.key,
    required this.label,
    required this.onTap,
    this.leading,
    this.trailing,
    this.backgroundColor,
    this.textColor,
  });

  @override
  State<_SecondaryActionButton> createState() => _SecondaryActionButtonState();
}

class _SecondaryActionButtonState extends State<_SecondaryActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final Color effectiveBg = _isHovered
        ? (widget.backgroundColor ?? Colors.grey[100]!)
        : (widget.backgroundColor ?? Colors.white);
    final Color effectiveText = widget.textColor ?? Colors.black;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: effectiveBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE0E0E0), width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 8),
              ],
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: effectiveText,
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterDialog extends StatelessWidget {
  final String currentSort;
  final Function(String) onSortChanged;
  final Offset buttonPosition;
  final double buttonHeight;

  const _FilterDialog({
    required this.currentSort,
    required this.onSortChanged,
    required this.buttonPosition,
    required this.buttonHeight,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Transparent barrier to close dialog
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(color: Colors.transparent),
          ),
        ),
        // Dropdown positioned below filter button
        Positioned(
          left: buttonPosition.dx,
          top: buttonPosition.dy + buttonHeight + 8,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 165,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 2,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _FilterOption(
                    label: 'Default',
                    isSelected: currentSort == 'default',
                    onTap: () {
                      onSortChanged('default');
                      Navigator.pop(context);
                    },
                  ),
                  const SizedBox(height: 10),
                  _FilterOption(
                    label: 'Created / Uploaded',
                    isSelected: currentSort == 'created',
                    onTap: () {
                      onSortChanged('created');
                      Navigator.pop(context);
                    },
                  ),
                  const SizedBox(height: 10),
                  _FilterOption(
                    label: 'Updated',
                    isSelected: currentSort == 'updated',
                    onTap: () {
                      onSortChanged('updated');
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FilterOption extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _FilterOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 149,
      height: 36,
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFE3F2FD) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: isSelected
                ? const Color(0xFF0C8CE9)
                : Colors.black.withOpacity(0.25),
            blurRadius: 2,
            spreadRadius: 0,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StorageIndicator extends StatelessWidget {
  final int usedStorage;
  final int totalStorage;
  final double percentage;

  const _StorageIndicator({
    required this.usedStorage,
    required this.totalStorage,
    required this.percentage,
  });

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Color _getBarColor() {
    return const Color(0x450C8CE9);
  }

  Color _getPercentageColor() {
    if (percentage >= 100) return Colors.black;
    return const Color(0xFF5C5C5C);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 304,
      height: 76,
      padding: const EdgeInsets.all(8),
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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Storage:',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              RichText(
                text: TextSpan(
                  children: [
                    if (percentage < 100)
                      TextSpan(
                        text: ' ',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.normal,
                          color: const Color(0xFF5C5C5C),
                        ),
                      ),
                    TextSpan(
                      text: percentage.toStringAsFixed(0),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: _getPercentageColor(),
                      ),
                    ),
                    TextSpan(
                      text: '%',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _getPercentageColor(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 287,
                height: 8,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFE0E0E0),
                      Color(0xFFF0F0F0),
                    ],
                    stops: [0.0, 0.5],
                  ),
                  borderRadius: BorderRadius.circular(100),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1A000000),
                      blurRadius: 2,
                      spreadRadius: 0,
                      offset: Offset(0, 1),
                      blurStyle: BlurStyle.inner,
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    if (percentage > 0)
                      Container(
                        width: (287 * percentage / 100).clamp(0.0, 287.0),
                        height: 8,
                        decoration: BoxDecoration(
                          color: _getBarColor(),
                          borderRadius: BorderRadius.circular(100),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x1A000000),
                              blurRadius: 2,
                              spreadRadius: 0,
                              offset: Offset(0, 1),
                              blurStyle: BlurStyle.inner,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '(${_formatSize(usedStorage)} of ${_formatSize(totalStorage)})',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                  if (percentage >= 100)
                    Text(
                      'Storage is full',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF5C5C5C),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DownloadAllDialog extends StatelessWidget {
  final String projectName;
  final int totalSize;

  const _DownloadAllDialog({
    required this.projectName,
    required this.totalSize,
  });

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Transparent barrier that closes dialog on tap
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.of(context).pop(false),
            child: Container(),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 80),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 538,
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
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Download All',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(false),
                          child: SvgPicture.asset(
                            'assets/images/cross.svg',
                            width: 16,
                            height: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Size: ',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.black.withOpacity(0.8),
                            ),
                          ),
                          TextSpan(
                            text: _formatSize(totalSize),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.normal,
                              color: Colors.black.withOpacity(0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'All files in this folder will be downloaded as a single ZIP file.',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(false),
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x40000000),
                                  blurRadius: 2,
                                  offset: Offset(0, 0),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                'Cancel',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                  color: const Color(0xFF0C8CE9),
                                ),
                              ),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.of(context).pop(true),
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x40000000),
                                  blurRadius: 2,
                                  offset: Offset(0, 0),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Download All',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: const Color(0xFF0C8CE9),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SvgPicture.asset(
                                  'assets/images/Download_all.svg',
                                  width: 16,
                                  height: 16,
                                  colorFilter: const ColorFilter.mode(
                                      Color(0xFF0C8CE9), BlendMode.srcIn),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Upload Popup Widget
class _UploadPopup extends StatelessWidget {
  final Map<String, _UploadProgress> uploads;
  final Function(String) onCancelUpload;
  final VoidCallback onClose;

  const _UploadPopup({
    required this.uploads,
    required this.onCancelUpload,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    if (uploads.isEmpty) return const SizedBox.shrink();

    return Stack(
      children: [
        // Click outside to close popup (but keep uploads)
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: Container(
              color: Colors.transparent,
            ),
          ),
        ),
        // Popup at right end
        Positioned(
          right: 24,
          top: 210,
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTap: () {}, // Prevent clicks from propagating to background
              child: Container(
                width: 523,
                constraints: const BoxConstraints(maxHeight: 600),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FA),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 2,
                      offset: Offset(0, 0),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 16),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(8),
                          topRight: Radius.circular(8),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x40000000),
                            blurRadius: 2,
                            offset: Offset(0, 0),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Uploading (${uploads.length})',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.black,
                            ),
                          ),
                          GestureDetector(
                            onTap: onClose,
                            child: Container(
                              width: 22.627,
                              height: 22.627,
                              alignment: Alignment.center,
                              child: Transform.rotate(
                                angle: -0.785398, // -45 degrees
                                child: Icon(
                                  Icons.add,
                                  size: 16,
                                  color: const Color(0xFF0C8CE9),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Upload items
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(16),
                        children: uploads.values.map((upload) {
                          return _UploadItem(
                            upload: upload,
                            onCancel: () => onCancelUpload(upload.id),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Individual upload item widget
class _UploadItem extends StatefulWidget {
  final _UploadProgress upload;
  final VoidCallback onCancel;

  const _UploadItem({
    required this.upload,
    required this.onCancel,
  });

  @override
  State<_UploadItem> createState() => _UploadItemState();
}

class _UploadItemState extends State<_UploadItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    if (widget.upload.progress < 100 &&
        !widget.upload.isCanceled &&
        !widget.upload.isFailed) {
      _rotationController.repeat();
    }
  }

  @override
  void didUpdateWidget(_UploadItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.upload.progress >= 100 ||
        widget.upload.isCanceled ||
        widget.upload.isFailed) {
      _rotationController.stop();
    } else if (oldWidget.upload.progress >= 100 &&
        widget.upload.progress < 100) {
      _rotationController.repeat();
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  Widget _getFileIcon(String extension) {
    // For loading state, show a rotating icon
    if (widget.upload.progress < 100 &&
        !widget.upload.isCanceled &&
        !widget.upload.isFailed) {
      return SizedBox(
        width: 24,
        height: 24,
        child: Lottie.asset(
          'assets/images/Animation - 1770546911567.json',
          width: 24,
          height: 24,
          fit: BoxFit.contain,
          repeat: true,
        ),
      );
    }

    // For completed or other files, show file type icon
    final iconPath = _getFileIconPath(extension);
    return SvgPicture.asset(
      iconPath,
      width: 24,
      height: 24,
    );
  }

  String _getFileIconPath(String extension) {
    final iconMap = {
      'csv': 'assets/images/csv.svg',
      'doc': 'assets/images/doc.svg',
      'docx': 'assets/images/docx.svg',
      'xls': 'assets/images/excel.svg',
      'xlsx': 'assets/images/excel.svg',
      'heic': 'assets/images/heic.svg',
      'jpg': 'assets/images/jpg.svg',
      'jpeg': 'assets/images/jpge.svg',
      'png': 'assets/images/png.svg',
      'webp': 'assets/images/webp.svg',
      'mp4': 'assets/images/mp4.svg',
      'pdf': 'assets/images/pdf.svg',
      'dwg': 'assets/images/dwg.svg',
      'zip': 'assets/images/zip.svg',
      'txt': 'assets/images/txt.svg',
      'dxf': 'assets/images/dxf.svg',
    };
    return iconMap[extension.toLowerCase()] ?? 'assets/images/no_format.svg';
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 1.0,
      child: Container(
        width: 491,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _getFileIcon(widget.upload.extension),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              widget.upload.fileName,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: Colors.black,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          GestureDetector(
                            onTap: widget.onCancel,
                            child: Text(
                              widget.upload.isFailed ? 'Dismiss' : 'Cancel',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: widget.upload.isFailed
                                    ? const Color(0xFF5C5C5C)
                                    : Colors.red,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(25.436),
                              child: LinearProgressIndicator(
                                value: widget.upload.isFailed
                                    ? 1.0
                                    : widget.upload.progress / 100,
                                minHeight: 6,
                                backgroundColor: const Color(0xFFE0E0E0),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  widget.upload.isFailed
                                      ? Colors.red
                                      : (widget.upload.isCanceled
                                          ? Colors.grey
                                          : const Color(0xFF0C8CE9)),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: widget.upload.isFailed ? 44 : 26,
                            child: Text(
                              widget.upload.isFailed
                                  ? 'Failed'
                                  : '${widget.upload.progress.toInt()}%',
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.normal,
                                color: widget.upload.isFailed
                                    ? Colors.red
                                    : Colors.black,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Uploaded Popup Widget (shows completed uploads)
class _UploadedPopup extends StatelessWidget {
  final List<Map<String, dynamic>> uploads;
  final VoidCallback onClose;

  const _UploadedPopup({
    required this.uploads,
    required this.onClose,
  });

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _getFileIconPath(String extension) {
    final iconMap = {
      'csv': 'assets/images/csv.svg',
      'doc': 'assets/images/doc.svg',
      'docx': 'assets/images/docx.svg',
      'xls': 'assets/images/excel.svg',
      'xlsx': 'assets/images/excel.svg',
      'heic': 'assets/images/heic.svg',
      'jpg': 'assets/images/jpg.svg',
      'jpeg': 'assets/images/jpge.svg',
      'png': 'assets/images/png.svg',
      'webp': 'assets/images/webp.svg',
      'mp4': 'assets/images/mp4.svg',
      'pdf': 'assets/images/pdf.svg',
      'dwg': 'assets/images/dwg.svg',
      'zip': 'assets/images/zip.svg',
      'txt': 'assets/images/txt.svg',
      'dxf': 'assets/images/dxf.svg',
    };
    return iconMap[extension.toLowerCase()] ?? 'assets/images/no_format.svg';
  }

  @override
  Widget build(BuildContext context) {
    if (uploads.isEmpty) return const SizedBox.shrink();

    return Stack(
      children: [
        // Click outside to close popup (but keep uploads)
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: Container(
              color: Colors.transparent,
            ),
          ),
        ),
        // Popup at right end
        Positioned(
          right: 24,
          top: 150,
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTap: () {}, // Prevent clicks from propagating to background
              child: Container(
                width: 523,
                constraints: const BoxConstraints(maxHeight: 600),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FA),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 2,
                      offset: Offset(0, 0),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 16),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(8),
                          topRight: Radius.circular(8),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x40000000),
                            blurRadius: 2,
                            offset: Offset(0, 0),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Uploaded (${uploads.length})',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.black,
                            ),
                          ),
                          GestureDetector(
                            onTap: onClose,
                            child: Container(
                              width: 22.627,
                              height: 22.627,
                              alignment: Alignment.center,
                              child: Transform.rotate(
                                angle: -0.785398, // -45 degrees
                                child: Icon(
                                  Icons.add,
                                  size: 16,
                                  color: const Color(0xFF0C8CE9),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Uploaded items
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(16),
                        children: uploads.map((upload) {
                          return _UploadedItem(
                            name: upload['name'] ?? '',
                            extension: upload['extension'] ?? '',
                            fileSize: upload['file_size'] ?? 0,
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Individual uploaded item widget
class _UploadedItem extends StatelessWidget {
  final String name;
  final String extension;
  final int fileSize;

  const _UploadedItem({
    required this.name,
    required this.extension,
    required this.fileSize,
  });

  String _getFileIconPath(String extension) {
    final iconMap = {
      'csv': 'assets/images/csv.svg',
      'doc': 'assets/images/doc.svg',
      'docx': 'assets/images/docx.svg',
      'xls': 'assets/images/excel.svg',
      'xlsx': 'assets/images/excel.svg',
      'heic': 'assets/images/heic.svg',
      'jpg': 'assets/images/jpg.svg',
      'jpeg': 'assets/images/jpge.svg',
      'png': 'assets/images/png.svg',
      'webp': 'assets/images/webp.svg',
      'mp4': 'assets/images/mp4.svg',
      'pdf': 'assets/images/pdf.svg',
      'dwg': 'assets/images/dwg.svg',
      'zip': 'assets/images/zip.svg',
      'txt': 'assets/images/txt.svg',
      'dxf': 'assets/images/dxf.svg',
    };
    return iconMap[extension.toLowerCase()] ?? 'assets/images/no_format.svg';
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 491,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 2,
            offset: Offset(0, 0),
          ),
        ],
      ),
      child: Row(
        children: [
          SvgPicture.asset(
            _getFileIconPath(extension),
            width: 24,
            height: 24,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                Text(
                  _formatFileSize(fileSize),
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Rotating upload icon
class _RotatingUploadIcon extends StatefulWidget {
  final double size;

  const _RotatingUploadIcon({required this.size});

  @override
  State<_RotatingUploadIcon> createState() => _RotatingUploadIconState();
}

class _RotatingUploadIconState extends State<_RotatingUploadIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.rotate(
            angle: _controller.value * 2 * 3.14159,
            child: CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _RotatingUploadPainter(),
            ),
          );
        },
      ),
    );
  }
}

class _RotatingUploadPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0C8CE9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.5;

    // Draw main circular arc (top right quadrant) matching SVG design
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(
      rect,
      -1.5708, // Start at top (-90 degrees)
      3.14159, // 180 degrees (half circle)
      false,
      paint,
    );

    // Draw secondary arc (bottom left)
    canvas.drawArc(
      rect,
      1.5708, // Start at bottom (90 degrees)
      1.5708, // 90 degrees (quarter circle)
      false,
      paint,
    );

    // Draw arrow pointing up in center
    final arrowLength = 4.0;
    canvas.drawLine(
      Offset(center.dx, center.dy - radius + 2),
      Offset(center.dx, center.dy - radius + 2 + arrowLength),
      paint,
    );

    // Arrow head - left
    canvas.drawLine(
      Offset(center.dx, center.dy - radius + 2),
      Offset(center.dx - 2.5, center.dy - radius + 4.5),
      paint,
    );

    // Arrow head - right
    canvas.drawLine(
      Offset(center.dx, center.dy - radius + 2),
      Offset(center.dx + 2.5, center.dy - radius + 4.5),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
