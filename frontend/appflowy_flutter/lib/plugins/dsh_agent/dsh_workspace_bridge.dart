import 'dart:convert';
import 'dart:io';

import 'package:appflowy/plugins/dsh_agent/dsh_runtime.dart';
import 'package:appflowy/workspace_platform/domain/workspace_models.dart';
import 'package:appflowy_backend/protobuf/flowy-user/protobuf.dart';

/// Publishes the current AppFlowy workspace so the DSH Cordis plugin can
/// project it onto a DSH workspace cwd without forking DSH.
class DshWorkspaceBridge {
  static File get hintFile {
    return File(
      '${DshRuntimeLayout.defaultDshHome}/bindings/current-appflowy-workspace.json',
    );
  }

  static Future<void> publish(UserWorkspacePB workspace) async {
    final previous = await _read();
    final sameWorkspace =
        previous?['appflowyWorkspaceId'] == workspace.workspaceId;
    await _write({
      'appflowyWorkspaceId': workspace.workspaceId,
      'title': workspace.name,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      if (sameWorkspace && previous?['projectRoot'] is String)
        'projectRoot': previous!['projectRoot'],
      if (sameWorkspace && previous?['mounts'] is List)
        'mounts': previous!['mounts'],
    });
  }

  static Future<void> publishProjectWorkspace({
    required String appflowyWorkspaceId,
    required String title,
    required List<MuseWorkspaceMount> mounts,
  }) async {
    final localMounts = mounts
        .where((mount) => mount.providerId == 'muse.workspace.local.v1')
        .toList(growable: false);
    await _write({
      'appflowyWorkspaceId': appflowyWorkspaceId,
      'title': title,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      if (localMounts.isNotEmpty) 'projectRoot': localMounts.first.rootLocator,
      'mounts': [
        for (final mount in mounts)
          {
            'mountRef': mount.mountRef,
            'providerId': mount.providerId,
            'displayName': mount.displayName,
            if (mount.providerId == 'muse.workspace.local.v1')
              'root': mount.rootLocator,
            'readOnly': mount.readOnly,
          },
      ],
    });
  }

  static Future<Map<String, dynamic>?> _read() async {
    try {
      final value = jsonDecode(await hintFile.readAsString());
      return value is Map<String, dynamic> ? value : null;
    } on Object {
      return null;
    }
  }

  static Future<void> _write(Map<String, Object?> value) async {
    final file = hintFile;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
