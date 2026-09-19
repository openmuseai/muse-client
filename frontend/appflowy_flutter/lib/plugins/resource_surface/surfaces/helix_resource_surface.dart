import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy/plugins/resource_surface/helix/helix_commands.dart';
import 'package:appflowy/plugins/resource_surface/helix/helix_install.dart';
import 'package:appflowy/plugins/resource_surface/helix/helix_settings.dart';
import 'package:appflowy/plugins/resource_surface/helix/helix_warm_pool.dart';
import 'package:appflowy/plugins/resource_surface/resource_surface_session.dart';
import 'package:appflowy/startup/startup.dart';
import 'package:flutter/gestures.dart';
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
  late final HelixSettingsController _settingsController;
  Pty? _pty;
  StreamSubscription<Uint8List>? _output;
  Directory? _configRoot;
  bool _booted = false;
  /// Helix paints its first frame only after the process has started, so the
  /// pane stays covered by the loading indicator until the PTY reports output.
  bool _painted = false;
  /// When true, the next PTY output lifts the loading cover. It is armed at
  /// spawn for cold starts and after `:open` for adopted warm processes, so a
  /// warm process's dashboard is replayed without ever being shown.
  bool _revealRequested = false;
  Timer? _paintTimeout;
  /// Watches an adopted warm process until it really shows the document.
  Timer? _openWatch;
  String? _error;
  HelixSettings _applied = HelixSettings.defaults;
  int _lspRevision = -1;
  String? _bootMessage;
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  int _pointerDownButtons = 0;

  @override
  void initState() {
    super.initState();
    _settingsController = getIt<HelixSettingsController>();
    _settingsController.addListener(_onSettingsChanged);
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
    unawaited(_boot());
  }

  Future<void> _boot() async {
    await _settingsController.ensureLoaded();
    if (!mounted) return;
    _applied = _settingsController.settings;
    try {
      final install = await HelixInstall.resolve();
      final installer = _settingsController.installer;
      await installer.ensureRoot();
      final xdgRuntime = installer.grammarRuntime;
      final runtimes = installer.grammarRuntimes(install.runtime);
      var grammarCount = await copyHelixGrammars(
        destRuntime: xdgRuntime,
        extraSearchRuntimes: [install.runtime],
      );
      final needed = helixGrammarNameForFile(widget.file.path);
      final missingHighlight = grammarCount == 0 ||
          (needed != null && !helixHasGrammar(needed, runtimes));
      if (missingHighlight && installer.busyId == null) {
        if (mounted) {
          setState(() {
            _bootMessage = needed == null
                ? '正在编译语法高亮…'
                : '正在编译 $needed 语法高亮（首次需要 git 与 C 编译器）…';
          });
        }
        try {
          await installer.buildGrammars(
            hxBinary: install.binary,
            helixRuntime: install.runtime,
          );
          grammarCount = helixGrammarLibraryCount(runtimes);
        } on Object catch (error) {
          _settingsController.setGrammarStatus('$error');
        }
      }
      _settingsController.setGrammarStatus(
        grammarCount > 0
            ? '语法高亮已就绪（$grammarCount 个 tree-sitter grammars）'
            : '未找到 grammars：打开 设置 → Plugin → 安装语法高亮',
      );
      if (mounted) setState(() => _bootMessage = null);
      final configDir =
          await Directory.systemTemp.createTemp('muse-helix-config-');
      _configRoot = configDir;
      final overlay = File(
        p.join(install.runtime, 'themes', 'openmuse_host.toml'),
      );
      var themeName = 'openmuse_host';
      try {
        await overlay.writeAsString(_applied.overlayThemeToml);
      } on Object {
        themeName = _applied.theme;
      }
      final config = File(p.join(configDir.path, 'helix-host.toml'));
      await config.writeAsString(
        _applied.configToml.replaceFirst(
          'theme = "openmuse_host"',
          'theme = "$themeName"',
        ),
      );
      await installer.writeLanguagesToml();
      final project = helixProjectRoot(widget.file);
      final arguments = <String>[
        '--config',
        config.path,
        '--working-dir',
        project.path,
        if (widget.initialLine != null) '+${widget.initialLine}',
        widget.file.path,
      ];
      final environment = helixGrammarProcessEnvironment(
        helixRuntime: install.runtime,
        xdgConfigHome: installer.xdgConfigHome.path,
      );
      environment['PATH'] = installer.pathPrefix(
        environment['PATH'] ?? '/usr/bin:/bin',
      );
      // Prefer a process the pool already started: `:open` on a live Helix
      // costs a fraction of Helix's per-file process start. Everything below is
      // the unchanged cold path, used whenever the pool has nothing to offer.
      HelixWarmSpec? warmSpec;
      try {
        warmSpec = await buildHelixWarmSpec(
          installer: installer,
          install: install,
          settings: _applied,
          workingDirectory: project.path,
        );
      } on Object {
        warmSpec = null;
      }
      if (warmSpec != null) {
        final warm = await HelixWarmPool.instance.take(warmSpec);
        if (warm != null) {
          _adoptWarmProcess(warm, warmSpec);
          return;
        }
      }
      final pty = Pty.start(
        install.binary,
        arguments: arguments,
        workingDirectory: project.path,
        environment: environment,
        rows: 30,
        columns: 100,
      );
      _pty = pty;
      _output = pty.output.listen(_onPtyData, onError: _onPtyError);
      if (mounted) {
        setState(() {});
        _booted = true;
        _revealRequested = true;
        _armPaintTimeout();
        _lspRevision = _settingsController.installer.revision;
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncPtySize());
        unawaited(_enterInsertMode(pty));
      }
      if (warmSpec != null) HelixWarmPool.instance.schedule(warmSpec);
    } on Object catch (error) {
      if (mounted) setState(() => _error = 'Helix runtime unavailable: $error');
    }
  }

  void _onPtyData(Uint8List data) {
    if (_revealRequested && !_painted) {
      _paintTimeout?.cancel();
      _paintTimeout = null;
      if (mounted) {
        setState(() => _painted = true);
      } else {
        _painted = true;
      }
    }
    _terminal.write(utf8.decode(data, allowMalformed: true));
  }

  void _onPtyError(Object error) {
    if (mounted) setState(() => _error = 'Helix PTY error: $error');
  }

  /// Safety net: never leave the loading cover up if Helix stays silent.
  void _armPaintTimeout() {
    _paintTimeout?.cancel();
    _paintTimeout = Timer(const Duration(seconds: 8), () {
      _openWatch?.cancel();
      _openWatch = null;
      if (mounted && !_painted) setState(() => _painted = true);
    });
  }

  /// Turns a pre-started, file-less Helix process into this tab's editor: the
  /// output it produced while idle is replayed into the local terminal model
  /// (hidden behind the loading cover) and then `:open` shows the document.
  void _adoptWarmProcess(HelixWarmProcess warm, HelixWarmSpec spec) {
    final pty = warm.pty;
    final buffered = warm.takeBufferedOutput();
    if (buffered.isNotEmpty) {
      _terminal.write(utf8.decode(buffered, allowMalformed: true));
    }
    if (!mounted) {
      pty.kill();
      HelixWarmPool.instance.schedule(spec);
      return;
    }
    _pty = pty;
    _output = warm.output.listen(_onPtyData, onError: _onPtyError);
    setState(() {});
    _booted = true;
    // The cover is lifted by _watchWarmOpen once the document is really on
    // screen; PTY output alone would also match the echoed command line.
    _revealRequested = false;
    _armPaintTimeout();
    _lspRevision = _settingsController.installer.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPtySize());
    pty.write(
      helixOpenCommandBytes(widget.file.path, line: widget.initialLine),
    );
    // Refill the pool so the next document opens just as fast.
    HelixWarmPool.instance.schedule(spec);
    unawaited(_enterInsertMode(pty));
    _watchWarmOpen(pty);
  }

  /// Waits until Helix's status line names [widget.file], then lifts the loading
  /// cover. If the adopted process never switches buffers, the tab falls back to
  /// a cold start so the pool's scratch buffer can never be shown to the user.
  void _watchWarmOpen(Pty pty) {
    const step = Duration(milliseconds: 60);
    const deadline = Duration(milliseconds: 1000);
    var elapsed = Duration.zero;
    _openWatch?.cancel();
    _openWatch = Timer.periodic(step, (timer) {
      elapsed += step;
      if (!mounted || _pty != pty) {
        timer.cancel();
        _openWatch = null;
        return;
      }
      if (_terminalShowsOpenFile()) {
        timer.cancel();
        _openWatch = null;
        setState(() => _painted = true);
        return;
      }
      if (elapsed >= deadline) {
        timer.cancel();
        _openWatch = null;
        unawaited(_reboot());
      }
    });
  }

  /// True once the name of [widget.file] appears in one of the bottom rows of
  /// the terminal, where Helix prints the current document's status line.
  bool _terminalShowsOpenFile() {
    final name = p.basename(widget.file.path);
    if (name.isEmpty) return true;
    final lines = _terminal.buffer.lines;
    final from = lines.length - 3 < 0 ? 0 : lines.length - 3;
    for (var index = from; index < lines.length; index++) {
      if (lines[index].getText().contains(name)) return true;
    }
    return false;
  }

  void _onSettingsChanged() {
    final next = _settingsController.settings;
    final lspRevision = _settingsController.installer.revision;
    final reboot = next.theme != _applied.theme ||
        next.keymap != _applied.keymap ||
        next.enableLsp != _applied.enableLsp ||
        next.backgroundColor != _applied.backgroundColor ||
        lspRevision != _lspRevision;
    final appearanceChanged = next.fontFamily != _applied.fontFamily ||
        next.fontSize != _applied.fontSize;
    _applied = next;
    if ((appearanceChanged || reboot) && mounted) setState(() {});
    if (reboot && _booted) {
      // Idle processes were started with the previous settings; drop them so
      // the rebooted surface cannot adopt a stale configuration.
      HelixWarmPool.instance.invalidate();
      unawaited(_reboot());
    }
  }

  Future<void> _reboot() async {
    await _flushToOriginal();
    _openWatch?.cancel();
    _openWatch = null;
    _pty?.kill();
    await _output?.cancel();
    _pty = null;
    _booted = false;
    _painted = false;
    _revealRequested = false;
    if (mounted) await _boot();
  }

  Future<void> _enterInsertMode(Pty pty) async {
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (!mounted || _pty != pty) return;
    pty.write(Uint8List.fromList(utf8.encode('i')));
  }

  void _syncPtySize() {
    final pty = _pty;
    if (!mounted || pty == null) return;
    pty.resize(_terminal.viewHeight, _terminal.viewWidth);
  }

  void _runNav(HelixNavCommand command) {
    if (_pty == null) return;
    command.sendTo(_terminal);
  }

  KeyEventResult _onTerminalKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final command = helixNavCommandForKey(event.logicalKey);
    if (command == null) return KeyEventResult.ignored;
    _runNav(command);
    return KeyEventResult.handled;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerDownButtons = event.buttons;
    if (event.buttons == kSecondaryMouseButton) {
      _placeCursorAtGlobal(event.position);
      unawaited(_showEditorContextMenu(event.position));
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final wasPrimary = _pointerDownButtons == kPrimaryMouseButton;
    _pointerDownButtons = 0;
    if (!wasPrimary) return;
    if (HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed) {
      Future<void>.delayed(const Duration(milliseconds: 40), () {
        if (mounted) _runNav(HelixNavCommand.gotoDefinition);
      });
    }
  }

  void _placeCursorAtGlobal(Offset globalPosition) {
    final state = _terminalViewKey.currentState;
    if (state == null) return;
    try {
      final local = state.renderTerminal.globalToLocal(globalPosition);
      state.renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        local,
      );
      state.renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        local,
      );
    } on Object {
      // Render object may be detached during reboot.
    }
  }

  Future<void> _showEditorContextMenu(Offset globalPosition) async {
    if (!mounted) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<HelixNavCommand>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final command in const [
          HelixNavCommand.gotoDefinition,
          HelixNavCommand.findUsages,
          HelixNavCommand.gotoType,
          HelixNavCommand.gotoImplementation,
        ])
          _navMenuItem(command),
        const PopupMenuDivider(),
        _navMenuItem(HelixNavCommand.jumpBack),
        _navMenuItem(HelixNavCommand.jumpForward),
        const PopupMenuDivider(),
        _navMenuItem(HelixNavCommand.rename),
      ],
    );
    if (!mounted || selected == null) return;
    _runNav(selected);
  }

  PopupMenuItem<HelixNavCommand> _navMenuItem(HelixNavCommand command) {
    return PopupMenuItem(
      value: command,
      child: Row(
        children: [
          Expanded(child: Text(command.label)),
          const SizedBox(width: 16),
          Text(
            command.shortcutHint,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _flushToOriginal() async {
    final pty = _pty;
    if (pty == null) return;
    pty.write(Uint8List.fromList(utf8.encode('\x1b:w\r')));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    MuseResourceSurfaceSession.instance.clearDirty(widget.file);
  }

  @override
  void dispose() {
    _settingsController.removeListener(_onSettingsChanged);
    _paintTimeout?.cancel();
    _openWatch?.cancel();
    MuseResourceSurfaceSession.instance.detach(widget.file);
    unawaited(_output?.cancel());
    final pty = _pty;
    final root = _configRoot;
    unawaited(() async {
      if (pty != null) {
        pty.write(Uint8List.fromList(utf8.encode('\x1b:w\r')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        pty.kill();
      }
      if (root != null) {
        try {
          await root.delete(recursive: true);
        } on Object {
          // Config dir is best-effort.
        }
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    if (!_booted) {
      // Helix is spawned per file and needs a moment before it paints its first
      // frame; show progress instead of an empty editor pane in the meantime.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(height: 14),
              Text(
                _bootMessage ?? '正在启动 Helix 编辑器…',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final settings = _applied;
    return Stack(
      children: [
        Column(
      children: [
        GestureDetector(
          onSecondaryTapDown: (details) =>
              unawaited(_showEditorContextMenu(details.globalPosition)),
          child: Container(
            height: 32,
            color: const Color(0xFF20252E),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    settings.keymap == HelixKeymapPreset.vscode
                        ? '⌘-点击转到定义 · 右键查找用法 · F12 定义 · ⇧F12 用法 · ⌥← 后退'
                        : '右键打开导航菜单 · Ctrl+S 保存 · Esc 进入 Helix 命令模式',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _NavButton(
                  label: '定义',
                  tooltip: '转到定义 (F12)',
                  onPressed: () => _runNav(HelixNavCommand.gotoDefinition),
                ),
                _NavButton(
                  label: '用法',
                  tooltip: '查找用法 (Shift+F12)',
                  onPressed: () => _runNav(HelixNavCommand.findUsages),
                ),
                _NavButton(
                  label: '后退',
                  tooltip: '返回上一位置 (Ctrl+O / Alt+←)',
                  onPressed: () => _runNav(HelixNavCommand.jumpBack),
                ),
                _NavButton(
                  label: '前进',
                  tooltip: '前进到下一位置 (F6 / Alt+→)',
                  onPressed: () => _runNav(HelixNavCommand.jumpForward),
                ),
                Builder(
                  builder: (buttonContext) {
                    return _NavButton(
                      label: '⋯',
                      tooltip: '更多导航操作',
                      onPressed: () {
                        final box =
                            buttonContext.findRenderObject() as RenderBox?;
                        final pos = box?.localToGlobal(
                              Offset(0, box.size.height),
                            ) ??
                            Offset.zero;
                        unawaited(_showEditorContextMenu(pos));
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: settings.backgroundColor,
            child: SizedBox.expand(
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerUp: _onPointerUp,
                child: TerminalView(
                  _terminal,
                  key: _terminalViewKey,
                  padding: EdgeInsets.zero,
                  autofocus: true,
                  theme: settings.terminalTheme,
                  textStyle: settings.terminalStyle,
                  onKeyEvent: _onTerminalKey,
                ),
              ),
            ),
          ),
        ),
      ],
        ),
        // The PTY exists before Helix has drawn anything, so cover the still
        // empty terminal until the first bytes arrive instead of showing a
        // blank editor pane.
        if (!_painted)
          Positioned.fill(
            child: ColoredBox(
              color: settings.backgroundColor,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    const SizedBox(height: 14),
                    const Text('正在启动 Helix 编辑器…', textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: tooltip,
        child: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 24),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: onPressed,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}
