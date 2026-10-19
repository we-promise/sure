/// Where a transaction sits in a split, for list rendering.
enum SplitRole {
  /// Not part of any split the app knows about.
  none,

  /// A split parent (rendered dimmed with a "Split" badge, like the web).
  parent,

  /// A split child.
  child,
}

class SplitListEntry<T> {
  final T item;
  final SplitRole role;

  /// True when a child is rendered directly under its parent.
  final bool grouped;

  const SplitListEntry(this.item, this.role, {this.grouped = false});
}

/// Reorders [items] so each known split parent is followed by its children,
/// mirroring the web's grouped split view (`group_split_entries`). Children
/// whose parent is not in [items] stay where they are, marked as children.
/// Anything the lookups do not know about passes through unchanged.
List<SplitListEntry<T>> groupSplitEntries<T>(
  List<T> items, {
  required String? Function(T item) idOf,
  required List<String>? Function(String id) childIdsOf,
  required String? Function(String id) parentIdOf,
}) {
  final byId = <String, T>{};
  for (final item in items) {
    final id = idOf(item);
    if (id != null) byId[id] = item;
  }

  final result = <SplitListEntry<T>>[];
  final placed = <String>{};

  for (final item in items) {
    final id = idOf(item);
    if (id == null) {
      result.add(SplitListEntry(item, SplitRole.none));
      continue;
    }
    if (placed.contains(id)) continue;

    final childIds = childIdsOf(id);
    if (childIds != null) {
      placed.add(id);
      result.add(SplitListEntry(item, SplitRole.parent));
      for (final childId in childIds) {
        final child = byId[childId];
        if (child == null || placed.contains(childId)) continue;
        placed.add(childId);
        result.add(SplitListEntry(child, SplitRole.child, grouped: true));
      }
      continue;
    }

    final parentId = parentIdOf(id);
    if (parentId != null && byId.containsKey(parentId)) {
      // Rendered under its parent when the parent comes up.
      continue;
    }

    placed.add(id);
    result.add(
      SplitListEntry(
        item,
        parentId != null ? SplitRole.child : SplitRole.none,
      ),
    );
  }

  return result;
}
