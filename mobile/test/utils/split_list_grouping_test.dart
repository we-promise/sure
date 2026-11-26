import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/utils/split_list_grouping.dart';

void main() {
  List<SplitListEntry<String>> group(
    List<String> ids, {
    Map<String, List<String>> splits = const {},
  }) {
    final parentOf = <String, String>{
      for (final entry in splits.entries)
        for (final child in entry.value) child: entry.key,
    };
    return groupSplitEntries<String>(
      ids,
      idOf: (id) => id,
      childIdsOf: (id) => splits[id],
      parentIdOf: (id) => parentOf[id],
    );
  }

  test('passes unknown transactions through in order', () {
    final entries = group(['a', 'b', 'c']);
    expect(entries.map((e) => e.item), ['a', 'b', 'c']);
    expect(entries.every((e) => e.role == SplitRole.none), isTrue);
  });

  test('places children directly under their parent in split order', () {
    // The API returns parent and children as separate rows in any order.
    final entries = group(
      ['c2', 'x', 'p', 'c1'],
      splits: {
        'p': ['c1', 'c2'],
      },
    );

    expect(entries.map((e) => e.item), ['x', 'p', 'c1', 'c2']);
    expect(entries[1].role, SplitRole.parent);
    expect(entries[2].role, SplitRole.child);
    expect(entries[2].grouped, isTrue);
    expect(entries[3].grouped, isTrue);
  });

  test('keeps a child whose parent is not listed, marked as a child', () {
    final entries = group(
      ['c1', 'y'],
      splits: {
        'p': ['c1', 'c2'],
      },
    );

    expect(entries.map((e) => e.item), ['c1', 'y']);
    expect(entries.first.role, SplitRole.child);
    expect(entries.first.grouped, isFalse);
  });
}
