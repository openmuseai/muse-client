import 'package:appflowy/generated/flowy_svgs.g.dart';
import 'package:appflowy/plugins/version_diff/application/text_version_diff_service.dart';
import 'package:appflowy/plugins/version_diff/presentation/text_diff_viewer.dart';
import 'package:appflowy/startup/plugin/plugin.dart';
import 'package:appflowy/workspace/presentation/home/home_stack.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/view.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

final class MuseTextDiffPluginConfig implements PluginConfig {
  @override
  bool get creatable => false;
}

final class MuseTextDiffPluginBuilder extends PluginBuilder {
  @override
  Plugin build(dynamic data) {
    if (data is MuseTextComparisonDocument) return MuseTextDiffPlugin(data);
    throw ArgumentError.value(
      data,
      'data',
      'MuseTextComparisonDocument required',
    );
  }

  @override
  String get menuName => 'Text comparison';

  @override
  FlowySvgData get icon => const FlowySvgData('');

  @override
  PluginType get pluginType => PluginType.diff;

  @override
  ViewLayoutPB? get layoutType => null;
}

final class MuseTextDiffPlugin extends Plugin {
  MuseTextDiffPlugin(this.document);

  final MuseTextComparisonDocument document;

  @override
  PluginId get id => 'diff:${document.diff.comparison.id}';

  @override
  PluginType get pluginType => PluginType.diff;

  @override
  PluginWidgetBuilder get widgetBuilder =>
      MuseTextDiffPluginWidgetBuilder(document);
}

final class MuseTextDiffPluginWidgetBuilder extends PluginWidgetBuilder
    with NavigationItem {
  MuseTextDiffPluginWidgetBuilder(this.document);

  final MuseTextComparisonDocument document;

  String get _title => '${p.basename(document.file.path)} · Diff';

  @override
  EdgeInsets get contentPadding => EdgeInsets.zero;

  @override
  String get viewName => _title;

  @override
  Widget get leftBarItem => _DiffTitle(title: _title);

  @override
  Widget tabBarItem(String pluginId, [bool shortForm = false]) =>
      _DiffTitle(title: _title);

  @override
  List<NavigationItem> get navigationItems => [this];

  @override
  Widget buildWidget({
    required PluginContext context,
    required bool shrinkWrap,
    Map<String, dynamic>? data,
  }) =>
      RepaintBoundary(
        key: const ValueKey('diff-host-workbench'),
        child: MuseTextDiffViewer(document: document),
      );
}

final class _DiffTitle extends StatelessWidget {
  const _DiffTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.difference_outlined, size: 16),
          const SizedBox(width: 7),
          Flexible(
            child: Text(title, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
}
