import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appflowy/plugins/resource_surface/helix/helix_install.dart';
import 'package:appflowy/plugins/resource_surface/helix/helix_language_servers.dart';
import 'package:appflowy/plugins/resource_surface/helix/helix_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;

/// Everything needed to pre-start a file-less Helix process.
///
/// The surface builds one of these with [buildHelixWarmSpec]; the pool keeps at
/// most one idle process per [key] so that a later file open can reuse it.
@immutable
final class HelixWarmSpec {
  const HelixWarmSpec({
    required this.key,
    required this.binary,
    required this.arguments,
    required this.workingDirectory,
    required this.environment,
    this.rows = 30,
    this.columns = 100,
  });

  /// Identity of the warm process: binary + working directory + config content.
  /// Only a spec with an identical key may reuse an idle process.
  final String key;
  final String binary;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
  final int rows;
  final int columns;
}

/// Writes the persistent Helix config used by warm processes and returns the
/// matching [HelixWarmSpec].
///
/// The config lives outside the per-surface temp directory because a warm
/// process outlives any single surface. Its file name contains a digest of the
/// effective config, so a settings change produces a different key and can
/// never reuse a process started with stale settings.
Future<HelixWarmSpec> buildHelixWarmSpec({
  required HelixLanguageServerInstaller installer,
  required HelixInstall install,
  required HelixSettings settings,
  required String workingDirectory,
}) async {
  await installer.ensureRoot();
  final warmRoot = Directory(p.join(p.dirname(installer.root.path), 'helix-warm'));
  await warmRoot.create(recursive: true);

  final overlay = File(p.join(install.runtime, 'themes', 'openmuse_host.toml'));
  var themeName = 'openmuse_host';
  try {
    await overlay.writeAsString(settings.overlayThemeToml);
  } on Object {
    themeName = settings.theme;
  }

  final configText = settings.configToml.replaceFirst(
    'theme = "openmuse_host"',
    'theme = "$themeName"',
  );
  final digest = (Object.hash(
                configText,
                settings.overlayThemeToml,
                installer.revision,
                install.runtime,
              ) &
          0x7fffffff)
      .toRadixString(16);
  final config = File(p.join(warmRoot.path, 'helix-host-$digest.toml'));
  if (!config.existsSync()) {
    await config.writeAsString(configText);
  }

  await installer.writeLanguagesToml();

  // Helix started without any file opens *its own file picker*, which swallows
  // keystrokes, so `:open` could never reach the command line. Pre-starting with
  // a throwaway file keeps Helix on a normal buffer whose command line works;
  // the surface then switches buffers with `:open`.
  final scratch = File(p.join(warmRoot.path, 'scratch.md'));
  if (!scratch.existsSync()) {
    await scratch.writeAsString('# OpenMuse warm buffer\n');
  }

  final environment = helixGrammarProcessEnvironment(
    helixRuntime: install.runtime,
    xdgConfigHome: installer.xdgConfigHome.path,
  );
  environment['PATH'] = installer.pathPrefix(
    environment['PATH'] ?? '/usr/bin:/bin',
  );

  return HelixWarmSpec(
    key: '$digest|${install.binary}|$workingDirectory',
    binary: install.binary,
    // The scratch file keeps Helix out of its file picker while it waits.
    arguments: [
      '--config',
      config.path,
      '--working-dir',
      workingDirectory,
      scratch.path,
    ],
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

/// A pre-started Helix process that has not opened a file yet.
///
/// While it is idle the pool records every byte Helix writes (its dashboard),
/// because the surface's local terminal model has to see the same escape
/// sequence stream it would have seen from a cold start.
final class HelixWarmProcess {
  HelixWarmProcess._(this.key, this.pty) {
    _subscription = pty.output.listen(
      _onData,
      onError: (Object error) {
        if (_ownedBySurface) {
          if (!_events.isClosed) _events.addError(error);
        } else {
          _dead = true;
        }
      },
      cancelOnError: false,
    );
    unawaited(() async {
      try {
        await pty.exitCode;
      } on Object {
        // The process is gone either way, which is all this flag records.
      }
      _dead = true;
    }());
  }

  static const int maxBufferedBytes = 256 * 1024;

  final String key;
  final Pty pty;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  // Single-subscription on purpose: bytes emitted between releaseToSurface()
  // and the surface's listen() are buffered by the controller instead of being
  // dropped, so the terminal model can never miss part of the stream.
  final StreamController<Uint8List> _events = StreamController<Uint8List>();
  final Completer<void> _ready = Completer<void>();

  StreamSubscription<Uint8List>? _subscription;
  Timer? _ttl;
  bool _dead = false;
  bool _ownedBySurface = false;
  int _bufferedBytes = 0;

  /// Output produced after the surface adopted this process.
  Stream<Uint8List> get output => _events.stream;

  bool get dead => _dead;

  void _onData(Uint8List data) {
    if (_ownedBySurface) {
      if (!_events.isClosed) _events.add(data);
      return;
    }
    if (!_ready.isCompleted) _ready.complete();
    _bufferedBytes += data.length;
    if (_bufferedBytes > maxBufferedBytes) {
      // Too much output to replay faithfully; never hand a desynced terminal
      // model to a surface.
      _dead = true;
      kill();
      return;
    }
    _buffer.add(data);
  }

  /// Resolves once Helix painted something, or when [timeout] elapses.
  Future<void> waitUntilReady(Duration timeout) {
    if (_ready.isCompleted) return Future<void>.value();
    return _ready.future.timeout(timeout, onTimeout: () {});
  }

  /// Bytes Helix wrote while idle, in order.
  Uint8List takeBufferedOutput() {
    _bufferedBytes = 0;
    return _buffer.takeBytes();
  }

  /// Hand ownership to a surface: stop buffering and forward output instead.
  void releaseToSurface() {
    _ownedBySurface = true;
    _ttl?.cancel();
    _ttl = null;
  }

  void armIdleTimeout(Duration ttl, void Function() onExpired) {
    _ttl?.cancel();
    _ttl = Timer(ttl, onExpired);
  }

  void kill() {
    _ttl?.cancel();
    _ttl = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (!_events.isClosed) unawaited(_events.close());
    try {
      pty.kill();
    } on Object {
      // The process may already be gone.
    }
  }
}

/// Keeps one file-less Helix process ready per working directory so that
/// opening a document does not pay Helix's ~0.4 s process start.
final class HelixWarmPool {
  HelixWarmPool._();

  static final HelixWarmPool instance = HelixWarmPool._();

  /// How long [take] waits for a still-starting process before falling back.
  static const Duration readyWait = Duration(milliseconds: 1200);

  /// Idle processes are killed after this long without being claimed.
  static const Duration idleTtl = Duration(seconds: 90);

  /// Upper bound on simultaneously pre-started processes.
  static const int maxIdleTotal = 2;

  final Map<String, HelixWarmProcess> _idle = <String, HelixWarmProcess>{};
  final Set<String> _spawning = <String>{};
  bool _disposed = false;

  @visibleForTesting
  int get idleCount => _idle.length;

  /// Claims the idle process matching [spec], or returns null when the caller
  /// has to start Helix itself.
  Future<HelixWarmProcess?> take(HelixWarmSpec spec) async {
    final entry = _idle.remove(spec.key);
    if (entry == null) return null;
    if (entry.dead) {
      entry.kill();
      return null;
    }
    await entry.waitUntilReady(readyWait);
    if (entry.dead) {
      entry.kill();
      return null;
    }
    entry.releaseToSurface();
    return entry;
  }

  /// Makes sure one idle process for [spec] exists. Never throws.
  void schedule(HelixWarmSpec spec) {
    if (_disposed) return;
    if (_idle.containsKey(spec.key) || _spawning.contains(spec.key)) return;
    while (_idle.length >= maxIdleTotal) {
      final oldest = _idle.keys.first;
      final evicted = _idle.remove(oldest);
      evicted?.kill();
    }
    _spawning.add(spec.key);
    unawaited(_spawn(spec));
  }

  Future<void> _spawn(HelixWarmSpec spec) async {
    try {
      if (_disposed) return;
      final pty = Pty.start(
        spec.binary,
        arguments: spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: spec.environment,
        rows: spec.rows,
        columns: spec.columns,
      );
      final entry = HelixWarmProcess._(spec.key, pty);
      if (_disposed) {
        entry.kill();
        return;
      }
      _idle[spec.key] = entry;
      entry.armIdleTimeout(idleTtl, () {
        if (identical(_idle[spec.key], entry)) {
          _idle.remove(spec.key);
          entry.kill();
        }
      });
    } on Object catch (error) {
      debugPrint('[helix-warm] pre-start skipped: $error');
    } finally {
      _spawning.remove(spec.key);
    }
  }

  /// Drops every idle process, e.g. after settings changed.
  void invalidate() {
    for (final entry in _idle.values) {
      entry.kill();
    }
    _idle.clear();
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }

  /// Best-effort warm-up for a workspace directory, used so the first Helix
  /// file of a session can also open without the process start cost.
  Future<void> warmUpForWorkspace(
    HelixSettingsController controller,
    String workingDirectory,
  ) async {
    if (_disposed) return;
    try {
      final dir = Directory(workingDirectory);
      if (!dir.existsSync()) return;
      await controller.ensureLoaded();
      final install = await HelixInstall.resolve();
      final spec = await buildHelixWarmSpec(
        installer: controller.installer,
        install: install,
        settings: controller.settings,
        workingDirectory: dir.path,
      );
      schedule(spec);
    } on Object catch (error) {
      debugPrint('[helix-warm] workspace warm-up skipped: $error');
    }
  }
}

/// Command that makes an adopted warm process show [path] (optionally at
/// [line]) exactly like the `hx <path>:<line>` command line would.
///
/// Helix's `:open` runs through `crate::args::parse_file`, which accepts the
/// `path:line:col` suffix. Its tokenizer interprets a backslash escape only on
/// Unix (`parse_unquoted` is `cfg!(unix)`-gated), so on Windows the path is
/// literal; double quotes keep paths with spaces in one argument on both
/// platforms, and embedded quotes are escaped by doubling them.
String helixOpenCommand(String path, {int? line}) {
  final target = line == null ? path : '$path:$line';
  final quoted = '"${target.replaceAll('"', '""')}"';
  return ':open $quoted\r';
}

/// Bytes xterm needs for the `:open` command above.
Uint8List helixOpenCommandBytes(String path, {int? line}) =>
    Uint8List.fromList(utf8.encode(helixOpenCommand(path, line: line)));
