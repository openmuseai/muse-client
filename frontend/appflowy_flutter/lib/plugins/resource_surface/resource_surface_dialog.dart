import 'package:appflowy/plugins/resource_surface/resource_file_plugin.dart';
import 'package:appflowy/plugins/resource_surface/resource_open_request.dart';
import 'package:appflowy/startup/startup.dart';
import 'package:appflowy/workspace/application/tabs/tabs_bloc.dart';
import 'package:flowy_infra/file_picker/file_picker_service.dart';
import 'package:flutter/material.dart';

final class MuseResourceSurfaceOpener {
  static Future<void> pickAndOpen(BuildContext context) async {
    final result = await getIt<FilePickerService>().pickFiles(
      dialogTitle: 'Open with OpenMuse',
    );
    if (!context.mounted || result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;
    await open(
      context,
      MuseResourceOpenRequest(
        path: path,
        origin: MuseResourceOpenOrigin.hostPicker,
      ),
    );
  }

  static Future<void> open(
    BuildContext context,
    MuseResourceOpenRequest request,
  ) async {
    try {
      final resource = await MuseLocalResourceRouter().resolve(request);
      if (!context.mounted) return;
      getIt<TabsBloc>().openExternalPlugin(MuseResourceFilePlugin(resource));
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open resource: $error')),
      );
    }
  }
}
