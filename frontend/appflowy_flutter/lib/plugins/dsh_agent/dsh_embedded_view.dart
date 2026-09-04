import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';

/// Embeds the DSH web UI: WKWebView on Apple platforms, WebView2 on Windows.
class DshEmbeddedView extends StatefulWidget {
  const DshEmbeddedView({
    super.key,
    required this.url,
    required this.onError,
  });

  final String url;
  final ValueChanged<String> onError;

  @override
  State<DshEmbeddedView> createState() => _DshEmbeddedViewState();
}

class _DshEmbeddedViewState extends State<DshEmbeddedView> {
  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return _WindowsWebView(url: widget.url, onError: widget.onError);
    }
    return _FlutterWebView(url: widget.url, onError: widget.onError);
  }
}

class _FlutterWebView extends StatefulWidget {
  const _FlutterWebView({required this.url, required this.onError});

  final String url;
  final ValueChanged<String> onError;

  @override
  State<_FlutterWebView> createState() => _FlutterWebViewState();
}

class _FlutterWebViewState extends State<_FlutterWebView> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    _create();
  }

  @override
  void didUpdateWidget(covariant _FlutterWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _controller?.loadRequest(Uri.parse(widget.url));
    }
  }

  void _create() {
    try {
      // Do not call setBackgroundColor: WKWebView on macOS throws
      // UnimplementedError ("opaque is not implemented on macOS").
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onWebResourceError: (error) {
              if (!mounted) return;
              if (error.isForMainFrame == false) return;
              final code = error.errorCode.abs();
              if (code == 1004 ||
                  error.errorType == WebResourceErrorType.connect) {
                return;
              }
              widget.onError(
                'Could not load DSH (${error.errorCode}). Use Reload after the sidecar is ready, or Open in browser.',
              );
            },
          ),
        )
        ..loadRequest(Uri.parse(widget.url));
      setState(() => _controller = controller);
    } catch (error) {
      widget.onError(
        'Embedded DSH view is unavailable on this build.\n$error',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    return WebViewWidget(controller: controller);
  }
}

class _WindowsWebView extends StatefulWidget {
  const _WindowsWebView({required this.url, required this.onError});

  final String url;
  final ValueChanged<String> onError;

  @override
  State<_WindowsWebView> createState() => _WindowsWebViewState();
}

class _WindowsWebViewState extends State<_WindowsWebView> {
  final WebviewController _controller = WebviewController();
  StreamSubscription<WebErrorStatus>? _errorSub;
  var _ready = false;
  var _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      await _controller.initialize();
      if (_disposed) {
        await _controller.dispose();
        return;
      }
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.allow);
      _errorSub = _controller.onLoadError.listen((error) {
        debugPrint('[dsh-webview] load error: $error');
      });
      await _controller.loadUrl(widget.url);
      if (mounted && !_disposed) setState(() => _ready = true);
    } catch (error) {
      if (_disposed) return;
      widget.onError(
        'Embedded DSH view needs the Microsoft Edge WebView2 runtime.\n$error',
      );
    }
  }

  @override
  void didUpdateWidget(covariant _WindowsWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url && _ready) {
      unawaited(_controller.loadUrl(widget.url));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_errorSub?.cancel());
    if (_ready) {
      unawaited(_controller.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    return Webview(_controller);
  }
}
