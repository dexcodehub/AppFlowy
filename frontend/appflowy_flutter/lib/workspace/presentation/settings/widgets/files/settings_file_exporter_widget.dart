import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy/generated/flowy_svgs.g.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/plugins/document/application/document_service.dart';
import 'package:appflowy/plugins/document/presentation/editor_plugins/plugins.dart';
import 'package:appflowy/shared/feature_flags.dart';
import 'package:appflowy/startup/startup.dart';
import 'package:appflowy/util/theme_extension.dart';
import 'package:appflowy/workspace/application/export/document_exporter.dart';
import 'package:appflowy/workspace/application/settings/settings_file_exporter_cubit.dart';
import 'package:appflowy/workspace/application/user/user_workspace_bloc.dart';
import 'package:appflowy/workspace/presentation/home/toast.dart';
import 'package:appflowy/workspace/presentation/widgets/dialogs.dart';
import 'package:appflowy_backend/protobuf/flowy-database2/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-user/user_profile.pb.dart';
import 'package:appflowy_backend/dispatch/dispatch.dart';
import 'package:appflowy_backend/log.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flowy_infra/file_picker/file_picker_service.dart';
import 'package:flowy_infra/theme_extension.dart';
import 'package:flowy_infra_ui/flowy_infra_ui.dart';
import 'package:flowy_infra_ui/style_widget/button.dart';
import 'package:flowy_infra_ui/style_widget/text.dart';
import 'package:flowy_infra_ui/widget/spacing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

enum ExportStatus {
  idle,
  exporting,
  success,
  error,
}

class ExportProgress {
  final ExportStatus status;
  final int current;
  final int total;
  final String? errorMessage;

  const ExportProgress({
    required this.status,
    this.current = 0,
    this.total = 0,
    this.errorMessage,
  });
}

class FileExporterWidget extends StatefulWidget {
  const FileExporterWidget({super.key});

  @override
  State<FileExporterWidget> createState() => _FileExporterWidgetState();
}

class _FileExporterWidgetState extends State<FileExporterWidget> {
  SettingsFileExporterCubit? _cubit;
  final ValueNotifier<ExportProgress> _exportProgress = 
      ValueNotifier(const ExportProgress(status: ExportStatus.idle));

  @override
  void dispose() {
    _exportProgress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<WorkspacePB?>(
      future: FolderEventReadCurrentWorkspace().send().then(
        (result) => result.fold((s) => s, (e) => null),
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        final workspace = snapshot.data;
        if (workspace == null) {
          return Center(
            child: FlowyText.regular(
              'No workspace available',
              color: AFThemeExtension.of(context).textColor.withOpacity(0.7),
            ),
          );
        }

        _cubit ??= SettingsFileExporterCubit(views: workspace.views);

        return BlocProvider.value(
          value: _cubit!,
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(),
                const VSpace(16),
                _buildExportPreview(),
                const VSpace(16),
                Expanded(child: _buildFileList()),
                const VSpace(16),
                _buildExportProgress(),
                const VSpace(8),
                _buildActionButtons(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        FlowySvg(
          FlowySvgs.export_markdown_s,
          size: const Size.square(20),
        ),
        const HSpace(8),
        FlowyText.medium(
          'Export Files',
          fontSize: 16,
        ),
      ],
    );
  }

  Widget _buildExportPreview() {
    return BlocBuilder<SettingsFileExporterCubit, SettingsFileExportState>(
      builder: (context, state) {
        final selectedCount = state.selectedViews.length;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AFThemeExtension.of(context).greyHover,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              FlowySvg(
                FlowySvgs.file_s,
                size: const Size.square(16),
              ),
              const HSpace(8),
              FlowyText.regular(
                '$selectedCount files selected for export',
                color: AFThemeExtension.of(context).textColor,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFileList() {
    return BlocBuilder<SettingsFileExporterCubit, SettingsFileExportState>(
      builder: (context, state) {
        if (state.views.isEmpty) {
          return Center(
            child: FlowyText.regular(
              'No files available',
              color: AFThemeExtension.of(context).textColor.withOpacity(0.7),
            ),
          );
        }

        return ListView.separated(
          itemCount: state.views.length,
          separatorBuilder: (context, index) => const VSpace(8),
          itemBuilder: (context, index) {
            final view = state.views[index];
            final isExpanded = state.expanded.length > index ? state.expanded[index] : false;
            final isAppSelected = state.selectedApps.length > index ? state.selectedApps[index] : false;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // App header
                InkWell(
                  onTap: () => _cubit!.expandOrUnexpandApp(index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        FlowyIconButton(
                          icon: FlowySvg(
                            isExpanded ? FlowySvgs.workspace_drop_down_menu_show_s : FlowySvgs.workspace_drop_down_menu_hide_s,
                            size: const Size.square(16),
                          ),
                          onPressed: () => _cubit!.expandOrUnexpandApp(index),
                        ),
                        const HSpace(8),
                        Expanded(
                          child: FlowyText.medium(
                            view.name,
                            fontSize: 14,
                          ),
                        ),
                        FlowyIconButton(
                          icon: FlowySvg(
                            isAppSelected ? FlowySvgs.check_filled_s : FlowySvgs.uncheck_s,
                            size: const Size.square(14),
                          ),
                          onPressed: () {
                            // 切换当前应用的所有子项选择状态
                            final selectedItems = _cubit!.state.selectedItems;
                            final isCurrentlySelected = selectedItems[index].every((item) => item);
                            for (var j = 0; j < selectedItems[index].length; j++) {
                              selectedItems[index][j] = !isCurrentlySelected;
                            }
                            _cubit!.emit(_cubit!.state.copyWith(selectedItems: selectedItems));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                // Child views list
                if (isExpanded && view.childViews.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 32, top: 4),
                    child: Column(
                      children: view.childViews.asMap().entries.map((entry) {
                        final childIndex = entry.key;
                        final childView = entry.value;
                        final isChildSelected = state.selectedItems.length > index &&
                            state.selectedItems[index].length > childIndex
                            ? state.selectedItems[index][childIndex]
                            : false;

                        return InkWell(
                          onTap: () => _cubit!.selectOrDeselectItem(index, childIndex),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            margin: const EdgeInsets.only(bottom: 2),
                            decoration: BoxDecoration(
                              color: isChildSelected 
                                ? AFThemeExtension.of(context).lightGreyHover
                                : Colors.transparent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              children: [
                                FlowySvg(
                                  _getViewIcon(childView.layout),
                                  size: const Size.square(14),
                                ),
                                const HSpace(8),
                                Expanded(
                                  child: FlowyText.regular(
                                    childView.name,
                                    fontSize: 13,
                                  ),
                                ),
                                FlowyIconButton(
                                  icon: FlowySvg(
                                    isChildSelected ? FlowySvgs.check_filled_s : FlowySvgs.uncheck_s,
                                    size: const Size.square(14),
                                  ),
                                  onPressed: () => _cubit!.selectOrDeselectItem(index, childIndex),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildExportProgress() {
    return ValueListenableBuilder<ExportProgress>(
      valueListenable: _exportProgress,
      builder: (context, progress, child) {
        if (progress.status == ExportStatus.idle) {
          return const SizedBox.shrink();
        }

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AFThemeExtension.of(context).greyHover,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (progress.status == ExportStatus.exporting)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (progress.status == ExportStatus.success)
                    FlowySvg(FlowySvgs.check_filled_s, size: const Size.square(16))
                  else if (progress.status == ExportStatus.error)
                    FlowySvg(FlowySvgs.close_filled_s, size: const Size.square(16)),
                  const HSpace(8),
                  Expanded(
                    child: FlowyText.regular(
                      _getStatusText(progress.status),
                      color: _getStatusColor(progress.status),
                    ),
                  ),
                ],
              ),
              if (progress.status == ExportStatus.exporting && progress.current > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(
                    value: progress.total > 0 ? progress.current / progress.total : null,
                    backgroundColor: AFThemeExtension.of(context).greyHover,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AFThemeExtension.of(context).calloutBGColor,
                    ),
                  ),
                ),
              if (progress.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FlowyText.regular(
                    progress.errorMessage!,
                    fontSize: 12,
                    color: AFThemeExtension.of(context).warning ?? Colors.red,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionButtons() {
    return BlocBuilder<SettingsFileExporterCubit, SettingsFileExportState>(
      builder: (context, state) {
        final hasSelection = state.selectedViews.isNotEmpty;
        
        return Row(
          children: [
            Expanded(
              child: FlowyButton(
                text: FlowyText.regular(
                  'Select All',
                  color: AFThemeExtension.of(context).textColor,
                ),
                onTap: () => _selectAllViews(),
                leftIcon: FlowySvg(FlowySvgs.check_filled_s),
              ),
            ),
            const HSpace(8),
            Expanded(
              child: FlowyButton(
                text: FlowyText.regular(
                  'Clear All',
                  color: AFThemeExtension.of(context).textColor,
                ),
                onTap: () => _clearAllViews(),
                leftIcon: FlowySvg(FlowySvgs.uncheck_s),
              ),
            ),
            const HSpace(16),
            Expanded(
              flex: 2,
              child: ValueListenableBuilder<ExportProgress>(
                valueListenable: _exportProgress,
                builder: (context, progress, child) {
                  final isExporting = progress.status == ExportStatus.exporting;
                  
                  return FlowyButton(
                    text: FlowyText.regular(
                      isExporting ? 'Exporting...' : 'Export Files',
                      color: hasSelection && !isExporting
                        ? Colors.white
                        : AFThemeExtension.of(context).textColor.withOpacity(0.5),
                    ),
                    onTap: hasSelection && !isExporting ? _handleExport : null,
                    leftIcon: isExporting 
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : FlowySvg(FlowySvgs.export_markdown_s),
                    backgroundColor: hasSelection && !isExporting
                      ? AFThemeExtension.of(context).calloutBGColor
                      : AFThemeExtension.of(context).greyHover,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  FlowySvgData _getViewIcon(ViewLayoutPB layout) {
    switch (layout) {
      case ViewLayoutPB.Document:
        return FlowySvgs.document_s;
      case ViewLayoutPB.Grid:
        return FlowySvgs.grid_s;
      case ViewLayoutPB.Board:
        return FlowySvgs.board_s;
      case ViewLayoutPB.Calendar:
        return FlowySvgs.date_s;
      default:
        return FlowySvgs.document_s;
    }
  }

  String _getStatusText(ExportStatus status) {
    switch (status) {
      case ExportStatus.idle:
        return '';
      case ExportStatus.exporting:
        return 'Exporting files...';
      case ExportStatus.success:
        return 'Export completed successfully';
      case ExportStatus.error:
        return 'Export failed';
    }
  }

  Color _getStatusColor(ExportStatus status) {
    switch (status) {
      case ExportStatus.idle:
        return AFThemeExtension.of(context).textColor;
      case ExportStatus.exporting:
        return AFThemeExtension.of(context).textColor;
      case ExportStatus.success:
        return Colors.green;
      case ExportStatus.error:
        return Theme.of(context).colorScheme.error;
    }
  }

  void _selectAllViews() {
    final selectedItems = _cubit!.state.selectedItems;
    // 选择所有项目
    for (var i = 0; i < selectedItems.length; i++) {
      for (var j = 0; j < selectedItems[i].length; j++) {
        selectedItems[i][j] = true;
      }
    }
    _cubit!.emit(_cubit!.state.copyWith(selectedItems: selectedItems));
  }

  void _clearAllViews() {
    final selectedItems = _cubit!.state.selectedItems;
    // 清除所有选择
    for (var i = 0; i < selectedItems.length; i++) {
      for (var j = 0; j < selectedItems[i].length; j++) {
        selectedItems[i][j] = false;
      }
    }
    _cubit!.emit(_cubit!.state.copyWith(selectedItems: selectedItems));
  }

  Future<void> _handleExport() async {
    final state = _cubit!.state;
    if (state.selectedViews.isEmpty) return;

    _exportProgress.value = ExportProgress(
      status: ExportStatus.exporting,
      current: 0,
      total: state.selectedViews.length,
    );

    try {
      final result = await FilePicker.platform.getDirectoryPath();
      if (result == null) {
        _exportProgress.value = const ExportProgress(status: ExportStatus.idle);
        return;
      }

      final selectedViews = state.selectedViews;
      
      int completed = 0;
      final List<String> failedFiles = [];
      
      for (final view in selectedViews) {
        try {
          await _exportSingleView(view, result);
          completed++;
          _exportProgress.value = ExportProgress(
            status: ExportStatus.exporting,
            current: completed,
            total: selectedViews.length,
          );
        } catch (e) {
          failedFiles.add(view.name);
          Log.error('Failed to export ${view.name}: $e');
        }
      }

      if (failedFiles.isEmpty) {
        _exportProgress.value = const ExportProgress(status: ExportStatus.success);
        if (mounted) {
          showSnackBarMessage(context, 'Export completed successfully');
        }
      } else {
        _exportProgress.value = ExportProgress(
          status: ExportStatus.error,
          errorMessage: 'Failed to export: ${failedFiles.join(', ')}',
        );
      }
      
      // Reset after 3 seconds
      Timer(const Duration(seconds: 3), () {
        if (mounted) {
          _exportProgress.value = const ExportProgress(status: ExportStatus.idle);
        }
      });
      
    } catch (e) {
      _exportProgress.value = ExportProgress(
        status: ExportStatus.error,
        errorMessage: 'Export failed: $e',
      );
    }
  }

  Future<void> _exportSingleView(ViewPB view, String exportPath) async {
    String? content;
    String fileExtension;

    switch (view.layout) {
      case ViewLayoutPB.Document:
        final documentExporter = DocumentExporter(view);
        final result = await documentExporter.export(DocumentExportType.markdown);
        result.fold(
          (markdown) => content = markdown,
          (error) => throw Exception('Document export failed: $error'),
        );
        fileExtension = 'md';
        break;
        
      default:
        final payload = DatabaseViewIdPB.create()..value = view.id;
        final result = await DatabaseEventExportCSV(payload).send();
        result.fold(
          (exportData) => content = exportData.data,
          (error) => throw Exception('Database export failed: $error'),
        );
        fileExtension = 'csv';
        break;
    }

    if (content == null || content!.isEmpty) {
      throw Exception('No content to export');
    }

    final fileName = '${view.name}.$fileExtension';
    final file = File(p.join(exportPath, fileName));
    
    await file.parent.create(recursive: true);
    await file.writeAsString(content!, encoding: utf8);
    
    if (!await file.exists() || await file.length() == 0) {
      throw Exception('Failed to create export file');
    }
  }
}
