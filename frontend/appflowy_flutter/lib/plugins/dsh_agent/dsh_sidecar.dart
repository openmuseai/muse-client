import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy/plugins/dsh_agent/dsh_agent_controller.dart';
import 'package:appflowy/plugins/dsh_agent/dsh_desktop_error.dart';
import 'package:appflowy/plugins/dsh_agent/dsh_runtime.dart';
import 'package:appflowy/plugins/dsh_agent/dsh_web_auth.dart';
import 'package:flutter/foundation.dart';

/// Starts the local DSH web sidecar with the Muse AppFlowy Cordis patch.
class DshSidecar {
  DshSidecar(this.controller);

  final DshAgentController controller;
  Process? _process;
  bool _starting = false;
  bool _stopping = false;
  final List<String> _logTail = <String>[];
  String _logRemainder = '';
  String? _sessionUrl;
  String? _launchToken;

  static DshRuntimeLayout get layout => DshRuntimeLayout.resolve();

  static String get museRoot => layout.museRoot;

  static String get dshHome => layout.dshHome;

  Future<void> ensureStarted() async {
    if (_starting) {
      while (_starting) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (await _isReady()) {
        final sessionUrl = _sessionUrl;
        if (sessionUrl != null) controller.setUrl(sessionUrl);
        controller.setError(null);
        controller.setReady(true);
        controller.setLaunching(false);
      }
      return;
    }
    if (await _isReady()) {
      final sessionUrl = _sessionUrl;
      if (sessionUrl != null) controller.setUrl(sessionUrl);
      controller.setError(null);
      controller.setReady(true);
      controller.setLaunching(false);
      return;
    }
    _starting = true;
    controller.setLaunching(true);
    controller.setError(null);
    try {
      final key = await _apiKey();
      if (key == null || key.isEmpty) {
        throw StateError(
          'DEEPSEEK_API_KEY is missing. Enter it in the DeepSeek panel.',
        );
      }
      Directory(dshHome).createSync(recursive: true);
      if (layout.closureEntry != null) {
        seedClosurePlugins(layout);
      } else {
        _seedMuseModules(layout);
        _seedDshMarket(layout);
      }
      clearLeakedHostPackages(layout);
      _logTail.clear();
      _logRemainder = '';
      _sessionUrl = null;
      _launchToken = null;
      await _reclaimListenPort();
      _stopping = false;
      _process = await _spawn(key);
      var exited = false;
      unawaited(
        _process!.exitCode.then((code) {
          exited = true;
          _launchToken = null;
          _sessionUrl = null;
          if (_stopping || !controller.ready) return;
          controller.setReady(false);
          controller.setError(
            DshWebAuth.summarizeExit(code, _logTail),
            code: DshDesktopError.sidecarExit,
          );
        }),
      );
      unawaited(
        _process!.stdout.transform(utf8.decoder).forEach((chunk) {
          _rememberLog(chunk, key);
          debugPrint('[dsh-sidecar] $chunk');
        }),
      );
      unawaited(
        _process!.stderr.transform(utf8.decoder).forEach((chunk) {
          _rememberLog(chunk, key);
          debugPrint('[dsh-sidecar:err] $chunk');
        }),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline)) {
        if (await _isReady() && await _stayedReady()) {
          final sessionUrl = _sessionUrl;
          if (sessionUrl != null) controller.setUrl(sessionUrl);
          controller.setError(null);
          controller.setReady(true);
          return;
        }
        if (exited) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final code = await _process!.exitCode;
          throw StateError(DshWebAuth.summarizeExit(code, _logTail));
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      throw StateError('DSH sidecar did not become ready on ${controller.url}');
    } catch (error) {
      controller.setReady(false);
      final message = error.toString();
      controller.setError(
        message,
        code: DshDesktopError.codeFromMessage(message),
      );
      rethrow;
    } finally {
      _starting = false;
      controller.setLaunching(false);
    }
  }

  Future<Process> _spawn(String apiKey) async {
    final resolved = layout;
    final environment = <String, String>{
      ...Platform.environment,
      'DEEPSEEK_API_KEY': apiKey,
      'MUSE_ROOT': resolved.museRoot,
      'DSH_HOME': resolved.dshHome,
      'DSH_WEB_HOST': DshWebAuth.listenHost,
      'DSH_WEB_PORT': '${DshWebAuth.listenPort}',
      // ESM package imports resolve from the file's realpath. Muse plugins
      // must therefore live under the harness node_modules tree, not the
      // sibling Resources/muse/packages copies.
      'NODE_PATH': '${resolved.harnessDir}/node_modules',
    };
    environment['MUSE_PLUGIN_DIAGNOSTICS'] ??= '1';
    if (resolved.bundled) {
      environment['MUSE_BUNDLE_ROOT'] = resolved.museRoot;
      final node = resolved.nodeBin;
      if (node == null) {
        throw StateError('Packed Muse runtime is missing node/bin/node');
      }
      // Finder-launched .app PATH is /usr/bin:/bin. dshmarket shells out to
      // node/corepack/pnpm when installing community plugins.
      final nodeDir = File(node).parent.path;
      final shims = ensureDesktopBinShims(resolved);
      environment['PATH'] = _prependPath(environment['PATH'], shims);
      environment['PATH'] = _prependPath(environment['PATH'], nodeDir);
      // DSH Desktop measured these: forcing copy/clone made Windows installs
      // physically copy the profile's 150+ packages; hardlink is what makes
      // one-click installs seconds instead of minutes.
      environment['npm_config_side_effects_cache'] = 'false';
      environment['PNPM_CONFIG_SIDE_EFFECTS_CACHE'] = 'false';
      final closureEntry = resolved.closureEntry;
      if (closureEntry != null) {
        // Symlink-free closure layout: run the packaged lib/bin.js directly
        // (no tsx, no source tree). Profile plugins were seeded in
        // ensureStarted so @muse + dshmarket resolve on first boot.
        return _startClosureDshCli(node, closureEntry, resolved, environment);
      }
      return _startDshCli(node, resolved, environment);
    }
    return _spawnFromSource(resolved, environment);
  }

  /// Closure packages owned by the DSH install. Copying a subset into the
  /// profile creates `node_modules/@deepseek-ai` with only Muse peers; Node
  /// then fails ESM lookup for the rest of the web bundle
  /// (`ERR_MODULE_NOT_FOUND` / "Did you mean …/lib/index.js"). Those packages
  /// must come from `$DSH_HOME/profiles/node_modules` junctions that
  /// `healProfilesModuleFallback` writes.
  static bool isHostOwnedSeedPackage(String spec) {
    return spec.startsWith('@deepseek-ai/');
  }

  /// Identity of the bundled closure this profile seed was copied from.
  /// Changes when the install path or `@muse/dsh-appflowy` overlay changes, so
  /// an upgrade from portable → setup.exe re-copies Muse plugins.
  static String closureSeedGeneration(DshRuntimeLayout resolved) {
    final dsh = File(
      '${resolved.museRoot}/closure/node_modules/@deepseek-ai/dsh/package.json',
    );
    var version = '';
    if (dsh.existsSync()) {
      try {
        final data = jsonDecode(dsh.readAsStringSync());
        if (data is Map && data['version'] is String) {
          version = data['version'] as String;
        }
      } catch (_) {}
    }
    final connector = File(
      '${resolved.museRoot}/closure/node_modules/@muse/dsh-appflowy/dist/src/connector.js',
    );
    final stamp = connector.existsSync()
        ? connector.lastModifiedSync().millisecondsSinceEpoch
        : 0;
    return '3\t${resolved.museRoot}\t$version\t$stamp';
  }

  /// Drop host packages that leaked into a profile's own `node_modules`.
  ///
  /// Node resolves a bare `@deepseek-ai/*` specifier from the profile directory
  /// before the installation fallback, so a leftover copy there shadows the
  /// bundled closure. When only a subset was copied — an older pack, or another
  /// build sharing this DSH home — the Loader fails for exactly those packages
  /// with `ERR_MODULE_NOT_FOUND` and "Did you mean …/lib/index.js?", the
  /// sidecar exits 1, and the UI only shows `Bad state: DSH sidecar exited with
  /// 1` plus a Node stack.
  ///
  /// [seedClosurePlugins] already removes that scope, but only when it re-seeds,
  /// and its generation marker stays valid across boots — so a leak created
  /// afterwards (by an older install, or a rebranded build using the same home)
  /// survives every later start. Cleaning has to happen on every start.
  static void clearLeakedHostPackages(DshRuntimeLayout resolved) {
    // Host packages must never live in a profile: the install fallback in
    // `$DSH_HOME/profiles/node_modules` supplies them (that is the invariant
    // seedClosurePlugins enforces when it re-seeds).
    final profileScope = Directory(
      '${resolved.dshHome}/profiles/web/node_modules/@deepseek-ai',
    );
    if (profileScope.existsSync()) {
      try {
        profileScope.deleteSync(recursive: true);
      } catch (_) {}
    }
    // The fallback itself is dsh's: keep its links and its proxy packages and
    // drop only entries dsh does not manage, which are the same leaks seen from
    // the shared directory.
    final fallbackScope = Directory(
      '${resolved.dshHome}/profiles/node_modules/@deepseek-ai',
    );
    if (!fallbackScope.existsSync()) return;
    for (final entity in fallbackScope.listSync()) {
      if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
          FileSystemEntityType.link) {
        continue;
      }
      if (entity is Directory && _isDshModuleProxy(entity)) continue;
      try {
        entity.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Whether [package] is one of dsh's own module-fallback proxies, which it
  /// records as `dsh.moduleFallback` in the package manifest.
  static bool _isDshModuleProxy(Directory package) {
    final manifest = File('${package.path}/package.json');
    if (!manifest.existsSync()) return false;
    try {
      final data = jsonDecode(manifest.readAsStringSync());
      if (data is! Map) return false;
      final dsh = data['dsh'];
      return dsh is Map && dsh['moduleFallback'] is Map;
    } catch (_) {
      return false;
    }
  }

  /// Closure (npm) layout: seed real copies of the @muse + dshmarket plugin
  /// graph into `$DSH_HOME/profiles/web/node_modules`. The Loader anchors
  /// bare-name resolution at the profile dir, and on Windows Node ESM refuses
  /// symlinked node_modules entries, so plugins must be real directories.
  /// Host `@deepseek-ai/*` packages stay out of the profile: the install
  /// fallback supplies them. Re-seed when [closureSeedGeneration] changes.
  static void seedClosurePlugins(DshRuntimeLayout resolved) {
    final marker = File('${resolved.dshHome}/profiles/web/.muse-seeded');
    final generation = closureSeedGeneration(resolved);
    if (marker.existsSync() && marker.readAsStringSync() == generation) {
      return;
    }
    final closureNm = Directory('${resolved.museRoot}/closure/node_modules');
    if (!closureNm.existsSync()) return;
    final destRoots = [
      Directory('${resolved.dshHome}/profiles/web/node_modules'),
    ];
    for (final destRoot in destRoots) {
      final leakedHost = Directory('${destRoot.path}/@deepseek-ai');
      if (leakedHost.existsSync()) {
        leakedHost.deleteSync(recursive: true);
      }
    }
    // Bare names patch.yml mounts that are not part of the @muse scope. The
    // Loader resolves `name: dsh-model-capabilities` from the profile
    // node_modules, so this vendored plugin has to be seeded like dshmarket.
    final roots = <String>['dshmarket', 'dsh-model-capabilities'];
    final museScope = Directory('${closureNm.path}/@muse');
    if (museScope.existsSync()) {
      for (final entity in museScope.listSync()) {
        if (entity is! Directory) continue;
        final name = entity.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last;
        roots.add('@muse/$name');
      }
    }
    final seen = <String>{};
    final queue = List<String>.from(roots);
    while (queue.isNotEmpty) {
      final spec = queue.removeLast();
      if (!seen.add(spec)) continue;
      if (isHostOwnedSeedPackage(spec)) continue;
      final source = Directory('${closureNm.path}/$spec');
      final manifest = File('${source.path}/package.json');
      if (!manifest.existsSync()) continue;
      for (final destRoot in destRoots) {
        _copyPackageTree(source, Directory('${destRoot.path}/$spec'));
      }
      try {
        final data =
            jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
        for (final kind in [
          'dependencies',
          'peerDependencies',
          'optionalDependencies',
        ]) {
          final deps = data[kind];
          if (deps is Map) {
            for (final name in deps.keys) {
              final specName = name as String;
              if (isHostOwnedSeedPackage(specName)) continue;
              if (File('${closureNm.path}/$specName/package.json')
                  .existsSync()) {
                queue.add(specName);
              }
            }
          }
        }
      } catch (_) {
        // A manifest that fails to parse cannot contribute further roots.
      }
    }
    try {
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync(generation);
    } catch (_) {}
  }

  /// Real-directory copy. Dart 3.6 (Flutter 3.27) has no Directory.copySync,
  /// and Windows Node ESM rejects symlinked node_modules entries.
  static void _copyPackageTree(Directory source, Directory dest) {
    final existing = FileSystemEntity.typeSync(dest.path, followLinks: false);
    if (existing == FileSystemEntityType.link) {
      Link(dest.path).deleteSync();
    } else if (existing == FileSystemEntityType.directory) {
      dest.deleteSync(recursive: true);
    } else if (existing == FileSystemEntityType.file) {
      File(dest.path).deleteSync();
    }
    dest.createSync(recursive: true);
    for (final entity in source.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      final next = '${dest.path}/$name';
      if (entity is Directory) {
        _copyPackageTree(entity, Directory(next));
      } else if (entity is File) {
        entity.copySync(next);
      }
    }
  }

  Future<Process> _startClosureDshCli(
    String node,
    String closureEntry,
    DshRuntimeLayout resolved,
    Map<String, String> environment,
  ) {
    return Process.start(
      node,
      [
        closureEntry,
        'web',
        '--patch',
        resolved.patchFile,
        '--host',
        DshWebAuth.listenHost,
        '--port',
        '${DshWebAuth.listenPort}',
      ],
      workingDirectory: resolved.museRoot,
      environment: environment,
    );
  }

  /// DSH Desktop's `.desktop-bin` pattern: write `pnpm`/`node` shims that
  /// resolve every `pnpm` by-name invocation (`dsh plugin`, dshmarket) to the
  /// bundled node + pnpm runner, so one-click plugin installs need no
  /// user-side Node/pnpm. Returns the shim directory (empty when the bundled
  /// plugin-tools are missing, which only happens on hand-modified bundles).
  static String ensureDesktopBinShims(DshRuntimeLayout resolved) {
    final node = resolved.nodeBin;
    final tools = Directory('${resolved.museRoot}/plugin-tools');
    final runner = File('${tools.path}/pnpm-runner.mjs').absolute;
    final pnpmEntry = File('${tools.path}/pnpm/bin/pnpm.cjs').absolute;
    final dir = Directory('${resolved.dshHome}/.desktop-bin').absolute;
    dir.createSync(recursive: true);
    if (node == null || !runner.existsSync() || !pnpmEntry.existsSync()) {
      return dir.path;
    }
    // Absolute paths only: the shims run from arbitrary cwds (the profile
    // directory) where relative bundle paths would not resolve.
    final command = '"${runner.path}" "${pnpmEntry.path}"';
    final nodeQuoted = '"${File(node).absolute.path}"';
    if (Platform.isWindows) {
      File('${dir.path}/pnpm.cmd').writeAsStringSync(
        '@chcp 65001 >nul\r\n@echo off\r\n$nodeQuoted $command %*\r\n',
      );
      File('${dir.path}/node.cmd').writeAsStringSync(
        '@chcp 65001 >nul\r\n@echo off\r\n$nodeQuoted %*\r\n',
      );
    } else {
      File('${dir.path}/pnpm').writeAsStringSync(
        '#!/bin/sh\nexec $nodeQuoted $command "\$@"\n',
      );
      File('${dir.path}/node').writeAsStringSync(
        '#!/bin/sh\nexec $nodeQuoted "\$@"\n',
      );
    }
    return dir.path;
  }

  Future<Process> _spawnFromSource(
    DshRuntimeLayout resolved,
    Map<String, String> environment,
  ) async {
    final harness = Directory(resolved.harnessDir);
    if (!harness.existsSync()) {
      throw StateError(
        'Missing DSH harness at ${resolved.harnessDir}. '
        'Place vendors/deepseek-harness in the Muse checkout, or set MUSE_HARNESS_DIR.',
      );
    }
    if (!File(resolved.patchFile).existsSync()) {
      throw StateError('Missing DSH patch ${resolved.patchFile}');
    }
    if (!Directory('${resolved.harnessDir}/node_modules').existsSync()) {
      throw StateError(
        'DSH harness dependencies are missing at ${resolved.harnessDir}/node_modules. '
        'Run: cd vendors/deepseek-harness && pnpm install',
      );
    }

    if (!Platform.isWindows) {
      final script = File(resolved.runDshScript);
      if (script.existsSync()) {
        return Process.start(
          '/bin/bash',
          [script.path],
          workingDirectory: resolved.museRoot,
          environment: environment,
        );
      }
    }

    final nodeDir = _windowsNodeDir();
    if (nodeDir != null) {
      environment['PATH'] = _prependPath(environment['PATH'], nodeDir);
    }
    final pnpm = _findOnPath('pnpm');
    if (pnpm != null) {
      return Process.start(
        pnpm,
        [
          'dsh',
          '--profile',
          'web',
          '--patch',
          resolved.patchFile,
          '--host',
          DshWebAuth.listenHost,
          '--port',
          '${DshWebAuth.listenPort}',
        ],
        workingDirectory: resolved.harnessDir,
        environment: environment,
      );
    }
    final node = _findOnPath('node');
    if (node != null) {
      return _startDshCli(node, resolved, environment);
    }
    throw StateError(
      'node and pnpm are required to start the DSH sidecar. '
      'Install Node.js, or run middlewares/scripts/run-dsh-appflowy.sh from a shell.',
    );
  }

  Future<Process> _startDshCli(
    String node,
    DshRuntimeLayout resolved,
    Map<String, String> environment,
  ) {
    return Process.start(
      node,
      [
        '--import',
        'tsx/esm',
        'apps/cli/src/bin.ts',
        '--profile',
        'web',
        '--patch',
        resolved.patchFile,
        '--host',
        DshWebAuth.listenHost,
        '--port',
        '${DshWebAuth.listenPort}',
      ],
      workingDirectory: resolved.harnessDir,
      environment: environment,
    );
  }

  static String _prependPath(String? inherited, String prefix) {
    if (inherited == null || inherited.isEmpty) return prefix;
    final sep = Platform.isWindows ? ';' : ':';
    return '$prefix$sep$inherited';
  }

  static String? _windowsNodeDir() {
    if (!Platform.isWindows) return null;
    const candidate = r'C:\Program Files\nodejs';
    if (Directory(candidate).existsSync()) return candidate;
    return null;
  }

  static String? _findOnPath(String name) {
    final pathEnv = Platform.environment['PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    final exts = Platform.isWindows
        ? (Platform.environment['PATHEXT'] ?? '.EXE;.CMD;.BAT;.COM')
            .split(';')
            .where((ext) => ext.isNotEmpty)
            .toList()
        : const <String>[''];
    final names = Platform.isWindows
        ? <String>[
            for (final ext in exts) '$name$ext',
            for (final ext in exts) '$name${ext.toLowerCase()}',
            name,
          ]
        : <String>[name];
    final dirs = <String>[
      ...pathEnv.split(sep).where((dir) => dir.isNotEmpty),
      if (Platform.isWindows) r'C:\Program Files\nodejs',
    ];
    for (final dir in dirs) {
      for (final fileName in names) {
        final candidate = File('$dir${Platform.pathSeparator}$fileName');
        if (candidate.existsSync()) return candidate.path;
      }
    }
    return null;
  }

  void _seedMuseModules(DshRuntimeLayout resolved) {
    Directory? source;
    final harness = Directory('${resolved.harnessDir}/node_modules/@muse');
    final bundled = Directory('${resolved.museRoot}/packages');
    // Prefer the copy under dsh/node_modules/@muse so Node ESM can resolve
    // sibling @muse/* and @deepseek-ai/* from that tree. Linking at
    // Resources/muse/packages makes imports like @muse/plugin-kit fail, DSH
    // fail-loud exits, and the WebView is left on "Loading plugins…".
    if (harness.existsSync()) {
      source = harness;
    } else if (bundled.existsSync()) {
      source = bundled;
    }
    if (source == null) return;
    for (final destPath in [
      '${resolved.dshHome}/profiles/node_modules/@muse',
      '${resolved.dshHome}/profiles/web/node_modules/@muse',
    ]) {
      Directory(destPath).createSync(recursive: true);
      for (final entity in source.listSync()) {
        if (entity is! Directory) continue;
        final name =
            entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
        final target = '$destPath/$name';
        _replaceWithLink(target, entity.path);
      }
    }
  }

  /// Loader baseUrl is the profile directory; ESM does not consult NODE_PATH.
  void _seedDshMarket(DshRuntimeLayout resolved) {
    final source = Directory('${resolved.harnessDir}/node_modules/dshmarket');
    if (!source.existsSync()) return;
    for (final destDir in [
      '${resolved.dshHome}/profiles/node_modules',
      '${resolved.dshHome}/profiles/web/node_modules',
    ]) {
      Directory(destDir).createSync(recursive: true);
      _replaceWithLink('$destDir/dshmarket', source.path);
    }
  }

  void _replaceWithLink(String target, String sourcePath) {
    try {
      // Always replace: a leftover directory from an older pack would
      // otherwise shadow the bundled package (WKWebView URL patch / dshmarket).
      final existing = FileSystemEntity.typeSync(target, followLinks: false);
      if (existing == FileSystemEntityType.link) {
        Link(target).deleteSync();
      } else if (existing == FileSystemEntityType.directory) {
        Directory(target).deleteSync(recursive: true);
      } else if (existing == FileSystemEntityType.file) {
        File(target).deleteSync();
      }
      Link(target).createSync(sourcePath);
    } catch (_) {}
  }

  void _rememberLog(String chunk, String apiKey) {
    final data = '$_logRemainder$chunk';
    final lines = const LineSplitter().convert(data);
    final complete = data.endsWith('\n') || data.endsWith('\r')
        ? lines
        : lines.take(lines.isEmpty ? 0 : lines.length - 1);
    _logRemainder = data.endsWith('\n') || data.endsWith('\r')
        ? ''
        : (lines.isEmpty ? data : lines.last);
    for (final rawLine in complete) {
      _captureLaunchUrl(rawLine);
      final line = rawLine.replaceAll(apiKey, '[REDACTED]').trim();
      if (line.isEmpty) continue;
      _logTail.add(line);
      if (_logTail.length > 40) _logTail.removeAt(0);
      _appendLogFile(line);
    }
  }

  void _captureLaunchUrl(String line) {
    final url = DshWebAuth.extractLaunchUrl(line);
    if (url == null) return;
    _sessionUrl = url;
    _launchToken = DshWebAuth.extractLaunchToken(line);
  }

  void _appendLogFile(String line) {
    try {
      File('${DshRuntimeLayout.userMuseHome}/dsh-sidecar.log')
          .writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// First HTTP 200 is not "booted": Muse plugins still import after listen.
  /// A failed import fail-loud-exits a second later and leaves Loading plugins.
  Future<bool> _stayedReady() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!await _isReady()) return false;
    }
    return true;
  }

  Future<bool> _isReady() async {
    try {
      final uri = DshWebAuth.probeUri(_sessionUrl);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      final request = await client.getUrl(uri);
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);
      return DshWebAuth.isStartupProbeHealthy(
        response.statusCode,
        _launchToken,
      );
    } catch (_) {
      return false;
    }
  }

  Future<String?> _apiKey() async {
    final fromEnv = Platform.environment['DEEPSEEK_API_KEY'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) return fromEnv.trim();
    for (final path in [
      layout.credentialsFile,
      '${Directory.systemTemp.path}/appflowy-muse/credentials.env',
    ]) {
      final stored = File(path);
      if (!stored.existsSync()) continue;
      for (final raw in stored.readAsLinesSync()) {
        final parsed = _parseEnvLine(raw, 'DEEPSEEK_API_KEY');
        if (parsed != null) return parsed;
      }
    }
    final sourceEnv = File('${layout.museRoot}/.env.dsh.local');
    if (!layout.bundled && sourceEnv.existsSync()) {
      for (final raw in sourceEnv.readAsLinesSync()) {
        final parsed = _parseEnvLine(raw, 'DEEPSEEK_API_KEY');
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static String? _parseEnvLine(String raw, String name) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) return null;
    final index = line.indexOf('=');
    if (index <= 0) return null;
    if (line.substring(0, index).trim() != name) return null;
    var value = line.substring(index + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    return value.isEmpty ? null : value;
  }

  Future<void> saveApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      throw StateError('API key is empty');
    }
    final file = File(layout.credentialsFile);
    await file.parent.create(recursive: true);
    await file.writeAsString('DEEPSEEK_API_KEY=$trimmed\n');
    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['600', file.path]);
    }
  }

  bool get needsApiKey {
    final error = controller.lastError;
    return error != null && error.contains('DEEPSEEK_API_KEY');
  }

  Future<void> stop() async {
    _stopping = true;
    final process = _process;
    _process = null;
    _launchToken = null;
    _sessionUrl = null;
    if (process == null) return;
    await _killPidTree(process.pid);
    try {
      process.kill();
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  /// Windows does not kill Node children when the GUI exits, so a leftover
  /// `dsh web` from the previous launch still owns 3080. Reclaim it before
  /// spawn or Host fail-louds with EADDRINUSE.
  Future<void> _reclaimListenPort() async {
    await stop();
    final occupied = await _listeningPids(DshWebAuth.listenPort);
    final self = pid;
    var killed = false;
    for (final occupiedPid in occupied) {
      if (occupiedPid == self) continue;
      await _killPidTree(occupiedPid);
      killed = true;
    }
    if (killed) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<Set<int>> _listeningPids(int port) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('netstat', ['-ano', '-p', 'tcp']);
        return DshWebAuth.listeningPidsFromNetstat(
          '${result.stdout}',
          port: port,
        );
      }
      final result = await Process.run('lsof', [
        '-t',
        '-iTCP:$port',
        '-sTCP:LISTEN',
      ]);
      return '${result.stdout}'
          .split(RegExp(r'\s+'))
          .map(int.tryParse)
          .whereType<int>()
          .where((value) => value > 0)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _killPidTree(int target) async {
    if (target <= 0) return;
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/T', '/PID', '$target']);
        return;
      }
      Process.killPid(target, ProcessSignal.sigterm);
    } catch (_) {}
  }
}
