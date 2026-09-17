import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy/plugins/resource_surface/resource_surface_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:xterm/xterm.dart';

class HelixResourceSurface extends StatefulWidget {
  const HelixResourceSurface({
    super.key,
    required this.file,
    this.initialLine,
  });

  final File file;
  final int? initialLine;

  @override
  State<HelixResourceSurface> createState() => _HelixResourceSurfaceState();
}

class _HelixResourceSurfaceState extends State<HelixResourceSurface> {
  late final Terminal _terminal;
  Pty? _pty;
  StreamSubscription<Uint8List>? _output;
  Directory? _workingCopyRoot;
  File? _workingCopy;
  bool _booted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = (data) {
      _pty?.write(Uint8List.fromList(utf8.encode(data)));
      if (_booted) {
        MuseResourceSurfaceSession.instance.markDirty(widget.file);
      }
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _pty?.resize(height, width);
    };
    MuseResourceSurfaceSession.instance.attach(
      widget.file,
      flush: _flushToOriginal,
    );
    _boot();
  }

  Future<void> _boot() async {
    try {
      final install = await _HelixInstall.resolve();
      final temp = await Directory.systemTemp.createTemp('muse-helix-view-');
      _workingCopyRoot = temp;
      final copy = await widget.file
          .copy(p.join(temp.path, p.basename(widget.file.path)));
      _workingCopy = copy;
      final stat = await copy.stat();
      await copy.setLastModified(stat.modified);
      final arguments = <String>[
        if (widget.initialLine != null) '+${widget.initialLine}',
        copy.path,
      ];
      final pty = Pty.start(
        install.binary,
        arguments: arguments,
        workingDirectory: temp.path,
        environment: {
          ...Platform.environment,
          'HELIX_RUNTIME': install.runtime,
          'TERM': 'xterm-256color',
          'COLORTERM': 'truecolor',
        },
        rows: 30,
        columns: 100,
      );
      _pty = pty;
      _output = pty.output.listen(
        (data) => _terminal.write(utf8.decode(data, allowMalformed: true)),
        onError: (Object error) {
          if (mounted) setState(() => _error = 'Helix PTY error: $error');
        },
      );
      if (mounted) {
        setState(() {});
        _booted = true;
        // TerminalView may have measured the Host viewport before the PTY was
        // ready. Sync once after the first frame so Helix starts at the actual
        // available width/height instead of the bootstrap 100x30 grid.
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncPtySize());
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = 'Helix runtime unavailable: $error');
    }
  }

  void _syncPtySize() {
    final pty = _pty;
    if (!mounted || pty == null) return;
    pty.resize(_terminal.viewHeight, _terminal.viewWidth);
  }

  Future<void> _flushToOriginal() async {
    final pty = _pty;
    final copy = _workingCopy;
    if (pty == null || copy == null) return;
    pty.write(Uint8List.fromList(utf8.encode('\x1b:w\r')));
    var lastLength = -1;
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!await copy.exists()) continue;
      final length = await copy.length();
      if (length == lastLength && length >= 0) break;
      lastLength = length;
    }
    if (await copy.exists()) {
      await copy.copy(widget.file.path);
    }
    MuseResourceSurfaceSession.instance.clearDirty(widget.file);
  }

  @override
  void dispose() {
    MuseResourceSurfaceSession.instance.detach(widget.file);
    unawaited(_output?.cancel());
    final pty = _pty;
    final copy = _workingCopy;
    final original = widget.file;
    final root = _workingCopyRoot;
    unawaited(() async {
      if (pty != null && copy != null) {
        pty.write(Uint8List.fromList(utf8.encode('\x1b:w\r')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        try {
          if (await copy.exists()) await copy.copy(original.path);
        } on Object {
          // Best-effort write-back when the tab is closed.
        }
        pty.kill();
      }
      if (root != null) {
        try {
          await root.delete(recursive: true);
        } on Object {
          // Temp copy is best-effort.
        }
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    return Column(
      children: [
        Container(
          height: 32,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: const Color(0xFF20252E),
          child: const Text(
            'Helix · 工作副本会在保存/切换版本时写回原文件 · :w 保存 · :q 关闭',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF1E1E2E),
            child: SizedBox.expand(
              child: TerminalView(
                _terminal,
                padding: EdgeInsets.zero,
                autofocus: true,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _HelixInstall {
  const _HelixInstall(this.binary, this.runtime);
  final String binary;
  final String runtime;

  static Future<_HelixInstall> resolve() async {
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
        return _HelixInstall(binary.path, runtime);
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
        return _HelixInstall(bundledBin.path, bundledRuntime.path);
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
      return _HelixInstall(
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
          return _HelixInstall(binary.path, runtime.path);
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
