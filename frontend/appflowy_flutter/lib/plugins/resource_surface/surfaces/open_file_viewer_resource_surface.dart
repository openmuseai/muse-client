import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';

class OpenFileViewerResourceSurface extends StatefulWidget {
  const OpenFileViewerResourceSurface({
    super.key,
    required this.file,
    this.initialLine,
  });

  final File file;
  final int? initialLine;

  @override
  State<OpenFileViewerResourceSurface> createState() =>
      _OpenFileViewerResourceSurfaceState();
}

class _OpenFileViewerResourceSurfaceState
    extends State<OpenFileViewerResourceSurface> {
  WebViewController? _controller;
  String? _error;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _sendFile(),
          onNavigationRequest: (request) =>
              request.isMainFrame && !request.url.startsWith('file:')
                  ? NavigationDecision.prevent
                  : NavigationDecision.navigate,
        ),
      );
      await controller.addJavaScriptChannel(
        'MuseViewerBridge',
        onMessageReceived: (message) {
          final decoded = jsonDecode(message.message);
          if (decoded is! Map) return;
          if (decoded['type'] == 'viewer.ready' && mounted) {
            setState(() => _loaded = true);
          }
          if (decoded['type'] == 'viewer.error' && mounted) {
            setState(() => _error = '${decoded['message']}');
          }
        },
      );
      if (!mounted) return;
      setState(() => _controller = controller);
      await controller.loadFlutterAsset(
        'assets/engines/open-file-viewer/index.html',
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Viewer runtime unavailable: $error');
      }
    }
  }

  Future<void> _sendFile() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final length = await widget.file.length();
      if (length > 64 * 1024 * 1024) {
        throw StateError('RESOURCE_TOO_LARGE (64 MiB desktop bridge limit)');
      }
      final bytes = await widget.file.readAsBytes();
      final payload = jsonEncode({
        'name': p.basename(widget.file.path),
        'mime': lookupMimeType(widget.file.path) ?? 'application/octet-stream',
        'base64': base64Encode(bytes),
        if (widget.initialLine != null) 'line': widget.initialLine,
      });
      await controller.runJavaScript('window.MuseViewer.open($payload)');
    } on Object catch (error) {
      if (mounted) setState(() => _error = 'Unable to render resource: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          WebViewWidget(controller: controller),
          if (!_loaded) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
