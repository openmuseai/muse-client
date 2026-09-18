import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

final class HelixInstall {
  const HelixInstall(this.binary, this.runtime);

  final String binary;
  final String runtime;

  static Future<HelixInstall> resolve() async {
    final override = Platform.environment['MUSE_HELIX_BIN']?.trim();
    if (override != null && override.isNotEmpty) {
      final binary = File(override);
      if (binary.existsSync()) {
        final runtime = Platform.environment['HELIX_RUNTIME']?.trim();
        if (runtime == null ||
            runtime.isEmpty ||
            !Directory(runtime).existsSync()) {
          throw StateError('HELIX_RUNTIME_REQUIRED');
        }
        return HelixInstall(binary.path, runtime);
      }
    }

    final executable = File(Platform.resolvedExecutable).absolute;
    final bundled = Directory(
      p.normalize(
        p.join(
          executable.parent.path,
          '..',
          'Frameworks',
          'App.framework',
          'Resources',
          'flutter_assets',
          'assets',
          'engines',
          'helix',
        ),
      ),
    );
    final bundledBin = File(p.join(bundled.path, 'hx'));
    final bundledRuntime = Directory(p.join(bundled.path, 'runtime'));
    if (bundledBin.existsSync()) {
      final bundledQueries = Directory(p.join(bundledRuntime.path, 'queries'));
      if (bundledRuntime.existsSync() && bundledQueries.existsSync()) {
        return HelixInstall(bundledBin.path, bundledRuntime.path);
      }
      final runtimeArchive = await rootBundle.load(
        'assets/engines/helix/runtime.tar',
      );
      final extractionRoot = await Directory.systemTemp.createTemp(
        'openmuse-helix-runtime-',
      );
      final archive = File(p.join(extractionRoot.path, 'runtime.tar'));
      await archive.writeAsBytes(
        runtimeArchive.buffer.asUint8List(
          runtimeArchive.offsetInBytes,
          runtimeArchive.lengthInBytes,
        ),
      );
      final result = await Process.run(
        'tar',
        ['-xf', archive.path, '-C', extractionRoot.path],
      );
      if (result.exitCode != 0) {
        throw StateError('HELIX_RUNTIME_EXTRACT_FAILED: ${result.stderr}');
      }
      return HelixInstall(
        bundledBin.path,
        p.join(extractionRoot.path, 'runtime'),
      );
    }

    for (final seed in [Directory.current.absolute, executable.parent]) {
      Directory cursor = seed;
      for (var depth = 0; depth < 12; depth++) {
        final binary = File(
          p.join(cursor.path, 'vendors', 'helix', 'target', 'release', 'hx'),
        );
        final runtime =
            Directory(p.join(cursor.path, 'vendors', 'helix', 'runtime'));
        if (binary.existsSync() && runtime.existsSync()) {
          return HelixInstall(binary.path, runtime.path);
        }
        final parent = cursor.parent;
        if (parent.path == cursor.path) break;
        cursor = parent;
      }
    }
    throw StateError(
      'Run tool/build_macos_engine_assets.sh before building the app',
    );
  }
}

Map<String, String> helixGrammarProcessEnvironment({
  required String helixRuntime,
  required String xdgConfigHome,
  Map<String, String>? base,
}) {
  final env = Map<String, String>.from(base ?? Platform.environment);
  env.remove('CARGO_MANIFEST_DIR');
  env['HELIX_RUNTIME'] = helixRuntime;
  env['XDG_CONFIG_HOME'] = xdgConfigHome;
  env['COLORTERM'] = 'truecolor';
  env['TERM'] = 'xterm-256color';
  return env;
}
