import 'dart:io';

import 'package:path/path.dart' as p;

enum MuseResourceOpenOrigin { hostPicker, dshConversation }

enum MuseLocalEngine { ioffice, helix, openFileViewer }

final class MuseResourceOpenRequest {
  const MuseResourceOpenRequest({
    required this.path,
    required this.origin,
    this.sessionCwd,
    this.line,
  });

  final String path;
  final MuseResourceOpenOrigin origin;
  final String? sessionCwd;
  final int? line;
}

final class MuseResolvedResource {
  const MuseResolvedResource({
    required this.file,
    required this.engine,
    required this.origin,
    this.line,
  });

  final File file;
  final MuseLocalEngine engine;
  final MuseResourceOpenOrigin origin;
  final int? line;
}

final class MuseLocalResourceRouter {
  static const helixExtensions = <String>{
    'c',
    'cc',
    'cpp',
    'cs',
    'css',
    'dart',
    'diff',
    'go',
    'h',
    'hpp',
    'ini',
    'java',
    'js',
    'json',
    'jsx',
    'kt',
    'log',
    'lua',
    'md',
    'mjs',
    'py',
    'rb',
    'rs',
    'scss',
    'sh',
    'sql',
    'swift',
    'toml',
    'ts',
    'tsx',
    'txt',
    'xml',
    'yaml',
    'yml',
    'zsh',
  };

  static const viewerExtensions = <String>{
    '3gp',
    'aac',
    'aiff',
    'avif',
    'avi',
    'bmp',
    'csv',
    'doc',
    'docm',
    'epub',
    'flac',
    'gif',
    'htm',
    'html',
    'ico',
    'jpeg',
    'jpg',
    'm4a',
    'm4v',
    'mkv',
    'mov',
    'mp3',
    'mp4',
    'odp',
    'ods',
    'odt',
    'ogg',
    'pdf',
    'png',
    'ppt',
    'pptx',
    'rtf',
    'svg',
    'tif',
    'tiff',
    'tsv',
    'url',
    'wav',
    'webp',
    'webm',
    'xls',
    'xlsx',
    'xps',
    'zip',
  };

  Future<MuseResolvedResource> resolve(MuseResourceOpenRequest request) async {
    if (request.path.trim().isEmpty) {
      throw const MuseResourceOpenException('EMPTY_PATH');
    }
    final candidate = p.isAbsolute(request.path)
        ? File(request.path)
        : File(
            p.join(request.sessionCwd ?? Directory.current.path, request.path),
          );
    // A path that cannot be resolved (missing file, dangling link, unreadable
    // parent) is "not a file" — the same refusal the type check below reports,
    // instead of an untyped FileSystemException callers cannot map.
    final File canonical;
    try {
      canonical = File(await candidate.resolveSymbolicLinks());
    } on FileSystemException {
      throw const MuseResourceOpenException('NOT_A_FILE');
    }
    final stat = await canonical.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw const MuseResourceOpenException('NOT_A_FILE');
    }
    if (request.origin == MuseResourceOpenOrigin.dshConversation) {
      final cwd = request.sessionCwd;
      if (cwd == null || cwd.trim().isEmpty) {
        throw const MuseResourceOpenException('DSH_CWD_REQUIRED');
      }
      final canonicalCwd = await Directory(cwd).resolveSymbolicLinks();
      if (!p.isWithin(canonicalCwd, canonical.path) &&
          !p.equals(canonicalCwd, canonical.path)) {
        throw const MuseResourceOpenException('OUTSIDE_SESSION_WORKSPACE');
      }
    }
    final extension =
        p.extension(canonical.path).toLowerCase().replaceFirst('.', '');
    final engine = extension == 'docx'
        ? MuseLocalEngine.ioffice
        : viewerExtensions.contains(extension)
            ? MuseLocalEngine.openFileViewer
            : helixExtensions.contains(extension)
                ? MuseLocalEngine.helix
                : MuseLocalEngine.openFileViewer;
    return MuseResolvedResource(
      file: canonical,
      engine: engine,
      origin: request.origin,
      line: request.line,
    );
  }
}

final class MuseResourceOpenException implements Exception {
  const MuseResourceOpenException(this.code);
  final String code;
  @override
  String toString() => 'MuseResourceOpenException($code)';
}
