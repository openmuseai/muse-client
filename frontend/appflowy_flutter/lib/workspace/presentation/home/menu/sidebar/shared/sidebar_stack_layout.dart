/// Layout policy for stacked sidebar spaces (Project, Personal, and later ones).
///
/// Spaces are laid out top-to-bottom at their content height. When the stacked
/// content no longer fits, every space except the active one collapses to its
/// header and the active space fills the remaining height.
class SidebarStackLayoutDecision {
  const SidebarStackLayoutDecision({
    required this.expandedIds,
    this.fillingId,
  });

  final Set<String> expandedIds;

  /// When set, that pane is wrapped in [Expanded] and should scroll.
  final String? fillingId;
}

SidebarStackLayoutDecision resolveSidebarStackLayout({
  required List<String> paneIds,
  required Set<String> expandedIds,
  required String? activeId,
  required Map<String, double> bodyHeights,
  required double availableHeight,
  double headerHeight = 32,
  double dividerHeight = 17,
}) {
  if (paneIds.isEmpty || !availableHeight.isFinite || availableHeight <= 0) {
    return SidebarStackLayoutDecision(
      expandedIds: Set<String>.from(expandedIds),
    );
  }

  final expanded = <String>{
    for (final id in paneIds)
      if (expandedIds.contains(id)) id,
  };
  final chrome = paneIds.length * headerHeight +
      (paneIds.isEmpty ? 0 : (paneIds.length - 1) * dividerHeight);
  var content = 0.0;
  var unmeasured = false;
  for (final id in expanded) {
    if (!bodyHeights.containsKey(id)) {
      unmeasured = true;
    }
    content += bodyHeights[id] ?? 0;
  }

  if (!unmeasured && chrome + content <= availableHeight + 0.5) {
    return SidebarStackLayoutDecision(expandedIds: expanded);
  }

  if (expanded.length <= 1) {
    final keep = expanded.isEmpty ? null : expanded.first;
    return SidebarStackLayoutDecision(
      expandedIds: expanded,
      fillingId: keep,
    );
  }

  final keep = activeId != null && expanded.contains(activeId)
      ? activeId
      : unmeasured
          ? expanded.first
          : expanded.reduce(
              (a, b) => (bodyHeights[a] ?? 0) >= (bodyHeights[b] ?? 0) ? a : b,
            );

  if (unmeasured) {
    return SidebarStackLayoutDecision(
      expandedIds: expanded,
      fillingId: keep,
    );
  }

  return SidebarStackLayoutDecision(
    expandedIds: {keep},
    fillingId: keep,
  );
}
