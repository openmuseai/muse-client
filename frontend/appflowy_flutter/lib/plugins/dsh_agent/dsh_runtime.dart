import 'dart:io';

/// Resolves the DSH sidecar layout for source-tree development and packed
/// apps: macOS `Contents/Resources/muse`, Windows `{exeDir}/muse`.
class DshRuntimeLayout {
  const DshRuntimeLayout({
    required this.bundled,
    required this.museRoot,
    required this.dshHome,
    required this.harnessDir,
    required this.patchFile,
    required this.nodeBin,
    required this.credentialsFile,
    this.closureEntry,
  });

  final bool bundled;
  final String museRoot;
  final String dshHome;
  final String harnessDir;
  final String patchFile;
  final String? nodeBin;
  final String credentialsFile;

  /// Symlink-free closure entry (`muse/closure/node_modules/@deepseek-ai/dsh/lib/bin.js`).
  /// Non-null in the closure layout; the legacy whole-tree bundle runs tsx
  /// source instead.
  final String? closureEntry;

  String get runDshScript =>
      '$museRoot/middlewares/scripts/run-dsh-appflowy.sh';

  static bool looksLikeMuseRoot(String path) {
    return Directory('$path/middlewares/dsh').existsSync() &&
        Directory('$path/frontend/client').existsSync();
  }

  /// Walks [searchFrom] (default: cwd + executable) looking for the split
  /// Muse repo. Honors `MUSE_ROOT` when that directory exists.
  static String? discoverMuseRoot({Iterable<String>? searchFrom}) {
    final env = Platform.environment['MUSE_ROOT']?.trim();
    if (env != null && env.isNotEmpty && Directory(env).existsSync()) {
      return env;
    }
    final starts = searchFrom ??
        <String>[
          Directory.current.path,
          File(Platform.resolvedExecutable).parent.path,
        ];
    for (final start in starts) {
      var dir = Directory(start);
      for (var i = 0; i < 16; i++) {
        if (looksLikeMuseRoot(dir.path)) return dir.path;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }

  static String get userMuseHome {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA']?.trim();
      if (appData != null && appData.isNotEmpty) {
        return '$appData/DSH Office/Muse';
      }
      final profile = Platform.environment['USERPROFILE']?.trim();
      if (profile != null && profile.isNotEmpty) {
        return '$profile/AppData/Roaming/DSH Office/Muse';
      }
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME']?.trim();
      if (home != null && home.isNotEmpty) {
        return '$home/.local/share/dsh-office/muse';
      }
    } else {
      final home = Platform.environment['HOME']?.trim();
      if (home != null && home.isNotEmpty) {
        return '$home/Library/Application Support/AppFlowy/Muse';
      }
    }
    return '${Directory.systemTemp.path}/appflowy-muse';
  }

  static String get defaultDshHome {
    final override = Platform.environment['MUSE_DSH_HOME'];
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    return '$userMuseHome/dsh';
  }

  static String get credentialsPath => '$userMuseHome/credentials.env';

  static Directory? bundleRoot() {
    final fromEnv = Platform.environment['MUSE_BUNDLE_ROOT'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      final directory = Directory(fromEnv.trim());
      if (looksLikeBundleRoot(directory.path)) return directory;
    }
    final exe = File(Platform.resolvedExecutable);
    if (Platform.isMacOS) {
      final resources = Directory('${exe.parent.parent.path}/Resources/muse');
      if (looksLikeBundleRoot(resources.path)) return resources;
    }
    if (Platform.isWindows || Platform.isLinux) {
      final beside = Directory('${exe.parent.path}/muse');
      if (looksLikeBundleRoot(beside.path)) return beside;
    }
    return null;
  }

  static bool looksLikeBundleRoot(String root) {
    return File('$root/patch.yml').existsSync() &&
        (Directory('$root/dsh').existsSync() ||
            Directory('$root/closure').existsSync());
  }

  /// Official Node tarball uses `bin/node`; the Windows zip uses `node.exe`.
  static String? bundledNodePath(String root) {
    for (final rel in [
      'node/bin/node',
      'node/bin/node.exe',
      'node/node.exe',
    ]) {
      final file = File('$root/$rel');
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  /// The symlink-free closure CLI entry, when the bundle ships one.
  static String? closureEntryPath(String root) {
    final candidate = File(
      '$root/closure/node_modules/@deepseek-ai/dsh/lib/bin.js',
    );
    return candidate.existsSync() ? candidate.path : null;
  }

  static DshRuntimeLayout resolve() {
    final bundle = bundleRoot();
    final dshHomePath = defaultDshHome;
    final credentials = credentialsPath;
    if (bundle != null) {
      final entry = closureEntryPath(bundle.path);
      return DshRuntimeLayout(
        bundled: true,
        museRoot: bundle.path,
        dshHome: dshHomePath,
        harnessDir:
            entry != null ? '${bundle.path}/closure' : '${bundle.path}/dsh',
        patchFile: '${bundle.path}/patch.yml',
        nodeBin: bundledNodePath(bundle.path),
        credentialsFile: credentials,
        closureEntry: entry,
      );
    }
    final source = discoverMuseRoot();
    if (source == null) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final beside = Directory('$exeDir/muse');
      if (beside.existsSync()) {
        throw StateError(
          'Packed Muse runtime at ${beside.path} is incomplete '
          '(need patch.yml and closure/ or dsh/). Reinstall DSH Office.',
        );
      }
      throw StateError(
        'Cannot find the Muse repo (middlewares/dsh + frontend/client). '
        'Set MUSE_ROOT to the openmuse checkout, or start the app from that tree.',
      );
    }
    final harnessOverride = Platform.environment['MUSE_HARNESS_DIR']?.trim();
    final harnessDir =
        (harnessOverride != null && harnessOverride.isNotEmpty)
            ? harnessOverride
            : '$source/vendors/deepseek-harness';
    return DshRuntimeLayout(
      bundled: false,
      museRoot: source,
      dshHome: dshHomePath,
      harnessDir: harnessDir,
      patchFile:
          '$source/middlewares/dsh/plugins/dsh-appflowy/cordis.patch.yml',
      nodeBin: null,
      credentialsFile: credentials,
    );
  }
}
