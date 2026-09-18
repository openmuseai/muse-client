import 'package:appflowy/generated/flowy_svgs.g.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/workspace/application/tabs/tabs_bloc.dart';
import 'package:appflowy/workspace/presentation/home/home_sizes.dart';
import 'package:appflowy/workspace/presentation/home/home_stack.dart';
import 'package:appflowy/startup/plugin/plugin.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:flowy_infra_ui/flowy_infra_ui.dart';
import 'package:flowy_infra_ui/style_widget/hover.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

class FlowyTab extends StatefulWidget {
  const FlowyTab({
    super.key,
    required this.pageManager,
    required this.isCurrent,
    required this.onTap,
    required this.isAllPinned,
  });

  final PageManager pageManager;
  final bool isCurrent;
  final VoidCallback onTap;

  /// Signifies whether all tabs are pinned
  ///
  final bool isAllPinned;

  @override
  State<FlowyTab> createState() => _FlowyTabState();
}

class _FlowyTabState extends State<FlowyTab> {
  final controller = PopoverController();

  @override
  Widget build(BuildContext context) {
    final pinned = widget.pageManager.isPinned;
    final current = widget.isCurrent;
    return ConstrainedBox(
      constraints: pinned
          ? const BoxConstraints.tightFor(width: 54)
          : current
              ? const BoxConstraints(minWidth: 128)
              : const BoxConstraints(minWidth: 88, maxWidth: 168),
      child: _wrapInTooltip(
        widget.pageManager.plugin.widgetBuilder.viewName,
        child: FlowyHover(
          resetHoverOnRebuild: false,
          style: HoverStyle(
            borderRadius: BorderRadius.zero,
            backgroundColor: current
                ? Theme.of(context).colorScheme.surface
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            hoverColor: current ? Theme.of(context).colorScheme.surface : null,
          ),
          builder: (context, isHovering) => AppFlowyPopover(
            controller: controller,
            offset: const Offset(4, 4),
            triggerActions: PopoverTriggerFlags.secondaryClick,
            showAtCursor: true,
            popupBuilder: (_) => BlocProvider.value(
              value: context.read<TabsBloc>(),
              child: TabMenu(
                controller: controller,
                pageId: widget.pageManager.plugin.id,
                plugin: widget.pageManager.plugin,
                isPinned: pinned,
                isAllPinned: widget.isAllPinned,
              ),
            ),
            child: ChangeNotifierProvider.value(
              value: widget.pageManager.notifier,
              child: Consumer<PageNotifier>(
                builder: (context, value, _) => Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: current ? 14.0 : 10.0,
                  ),
                  child: Listener(
                    onPointerDown: (event) {
                      if (event.buttons == kPrimaryButton) {
                        widget.onTap();
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) {},
                      child: SizedBox(
                        height: HomeSizes.tabBarHeight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (current)
                              widget.pageManager.notifier.tabBarWidget(
                                widget.pageManager.plugin.id,
                                pinned,
                              )
                            else
                              Flexible(
                                child: widget.pageManager.notifier.tabBarWidget(
                                  widget.pageManager.plugin.id,
                                  pinned,
                                ),
                              ),
                            if (widget.pageManager.plugin
                                is PluginTabMenuContributor)
                              Visibility(
                                visible: isHovering || current,
                                child: SizedBox(
                                  width: 24,
                                  height: 26,
                                  child: FlowyIconButton(
                                    tooltipText: 'Tab actions',
                                    onPressed: controller.show,
                                    icon:
                                        const Icon(Icons.more_horiz, size: 17),
                                  ),
                                ),
                              ),
                            if (!pinned) ...[
                              Visibility(
                                visible: isHovering || current,
                                child: SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: FlowyIconButton(
                                    onPressed: () => _closeTab(context),
                                    icon: const FlowySvg(
                                      FlowySvgs.close_s,
                                      size: Size.square(22),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _closeTab(BuildContext context) => context
      .read<TabsBloc>()
      .add(TabsEvent.closeTab(widget.pageManager.plugin.id));

  Widget _wrapInTooltip(String? viewName, {required Widget child}) {
    if (viewName != null) {
      return FlowyTooltip(
        message: viewName,
        child: child,
      );
    }

    return child;
  }
}

@visibleForTesting
class TabMenu extends StatelessWidget {
  const TabMenu({
    super.key,
    required this.controller,
    required this.pageId,
    required this.plugin,
    required this.isPinned,
    required this.isAllPinned,
  });

  final PopoverController controller;
  final String pageId;
  final Plugin plugin;
  final bool isPinned;
  final bool isAllPinned;

  @override
  Widget build(BuildContext context) {
    return SeparatedColumn(
      separatorBuilder: () => const VSpace(4),
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: isPinned ? 0.5 : 1,
          child: _wrapInTooltip(
            shouldWrap: isPinned,
            message: LocaleKeys.tabMenu_closeDisabledHint.tr(),
            child: FlowyButton(
              text: FlowyText.regular(LocaleKeys.tabMenu_close.tr()),
              onTap: () => _closeTab(context),
              disable: isPinned,
            ),
          ),
        ),
        Opacity(
          opacity: isAllPinned ? 0.5 : 1,
          child: _wrapInTooltip(
            shouldWrap: true,
            message: isAllPinned
                ? LocaleKeys.tabMenu_closeOthersDisabledHint.tr()
                : LocaleKeys.tabMenu_closeOthersHint.tr(),
            child: FlowyButton(
              text: FlowyText.regular(
                LocaleKeys.tabMenu_closeOthers.tr(),
              ),
              onTap: () => _closeOtherTabs(context),
              disable: isAllPinned,
            ),
          ),
        ),
        if (plugin case final PluginTabMenuContributor contributor) ...[
          const Divider(height: 0.5),
          ..._pluginActions(context, contributor),
        ],
        const Divider(height: 0.5),
        FlowyButton(
          text: FlowyText.regular(
            isPinned
                ? LocaleKeys.tabMenu_unpinTab.tr()
                : LocaleKeys.tabMenu_pinTab.tr(),
          ),
          onTap: () => _togglePin(context),
        ),
      ],
    );
  }

  List<Widget> _pluginActions(
    BuildContext context,
    PluginTabMenuContributor contributor,
  ) {
    final actions = contributor.tabMenuActions(context);
    final widgets = <Widget>[];
    int? previousGroup;
    for (final action in actions) {
      if (previousGroup != null && previousGroup != action.group) {
        widgets.add(const Divider(height: 0.5));
      }
      previousGroup = action.group;
      widgets.add(
        Opacity(
          opacity: action.enabled ? 1 : 0.45,
          child: action.submenuBuilder == null
              ? FlowyButton(
                  leftIcon:
                      action.icon == null ? null : Icon(action.icon, size: 16),
                  text: FlowyText.regular(action.label),
                  disable: !action.enabled,
                  onTap: () async {
                    controller.close();
                    await action.invoke(context);
                  },
                )
              : AppFlowyPopover(
                  triggerActions:
                      PopoverTriggerFlags.hover | PopoverTriggerFlags.click,
                  offset: const Offset(6, 0),
                  constraints: const BoxConstraints(
                    minWidth: 240,
                    maxWidth: 320,
                    maxHeight: 420,
                  ),
                  popupBuilder: (ctx) => action.submenuBuilder!(
                    ctx,
                    controller.close,
                  ),
                  child: FlowyButton(
                    leftIcon: action.icon == null
                        ? null
                        : Icon(action.icon, size: 16),
                    rightIcon: const Icon(Icons.chevron_right, size: 16),
                    text: FlowyText.regular(action.label),
                    disable: !action.enabled,
                    onTap: () {},
                  ),
                ),
        ),
      );
    }
    return widgets;
  }

  Widget _wrapInTooltip({
    required bool shouldWrap,
    String? message,
    required Widget child,
  }) {
    if (shouldWrap) {
      return FlowyTooltip(
        message: message,
        child: child,
      );
    }

    return child;
  }

  void _closeTab(BuildContext context) {
    context.read<TabsBloc>().add(TabsEvent.closeTab(pageId));
    controller.close();
  }

  void _closeOtherTabs(BuildContext context) {
    context.read<TabsBloc>().add(TabsEvent.closeOtherTabs(pageId));
    controller.close();
  }

  void _togglePin(BuildContext context) {
    context.read<TabsBloc>().add(TabsEvent.togglePin(pageId));
    controller.close();
  }
}
