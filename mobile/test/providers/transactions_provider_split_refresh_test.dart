import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/offline_transaction.dart';
import 'package:sure_mobile/providers/transactions_provider.dart';
import 'package:sure_mobile/services/connectivity_service.dart';
import 'package:sure_mobile/services/offline_storage_service.dart';
import 'package:sure_mobile/services/sync_service.dart';

/// Local cache keyed by server id; only what the split refresh touches.
class _FakeStorage implements OfflineStorageService {
  final Set<String> ids = {};
  final Set<String> failingDeletes = {};

  @override
  Future<List<OfflineTransaction>> getTransactions({String? accountId}) async =>
      [
        for (final id in ids)
          OfflineTransaction(
            id: id,
            localId: 'local_$id',
            accountId: 'acct',
            name: id,
            date: '2026-06-01',
            amount: r'$1.00',
            currency: 'USD',
            nature: 'expense',
            syncStatus: SyncStatus.synced,
          ),
      ];

  @override
  Future<void> deleteTransactionByServerId(String serverId) async {
    if (failingDeletes.contains(serverId)) {
      throw StateError('disk error');
    }
    ids.remove(serverId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Upserts whatever the "server" returns; each call can be held open.
class _FakeSync implements SyncService {
  _FakeSync(this.storage);

  final _FakeStorage storage;
  Set<String> serverIds = {};
  bool succeed = true;
  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  final List<Completer<void>> gates = [];

  @override
  Future<SyncResult> syncFromServer({
    required String accessToken,
    String? accountId,
  }) async {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    // What the server returns is read when the request starts.
    final snapshot = Set<String>.of(serverIds);
    if (gates.isNotEmpty) await gates.removeAt(0).future;
    inFlight--;
    if (!succeed) return SyncResult(success: false, error: 'offline');
    storage.ids.addAll(snapshot);
    return SyncResult(success: true, syncedCount: snapshot.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Online extends ChangeNotifier implements ConnectivityService {
  @override
  bool get isOnline => true;

  @override
  bool get isOffline => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeStorage storage;
  late _FakeSync sync;
  late TransactionsProvider provider;

  setUp(() {
    storage = _FakeStorage();
    sync = _FakeSync(storage);
    provider = TransactionsProvider(offlineStorage: storage, syncService: sync)
      ..setConnectivityService(_Online());
  });

  test('a sync that started before the split change cannot resurrect '
      'destroyed children', () async {
    storage.ids.addAll({'parent', 'old_child_1', 'old_child_2'});
    sync.serverIds = {'parent', 'old_child_1', 'old_child_2'};

    // An earlier refresh fetched generation A and is still running.
    final gate = Completer<void>();
    sync.gates.add(gate);
    final earlier = provider.fetchTransactions(
      accessToken: 't',
      accountId: 'acct',
      forceSync: true,
    );
    await Future<void>.delayed(Duration.zero);

    // The split is replaced on the server: A's children are gone.
    sync.serverIds = {'parent', 'new_child_1', 'new_child_2'};
    final refresh = provider.refreshAfterSplitChange(
      accessToken: 't',
      accountId: 'acct',
      removedChildIds: const ['old_child_1', 'old_child_2'],
    );

    gate.complete(); // the stale response lands after the deletion
    await earlier;
    await refresh;

    expect(storage.ids, {'parent', 'new_child_1', 'new_child_2'});
  });

  test('post-split refreshes run one at a time', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    sync.gates.addAll([first, second]);

    final a = provider.refreshAfterSplitChange(
      accessToken: 't',
      accountId: 'acct',
      removedChildIds: const ['c1'],
    );
    final b = provider.refreshAfterSplitChange(
      accessToken: 't',
      accountId: 'acct',
      removedChildIds: const ['c2'],
    );
    await Future<void>.delayed(Duration.zero);
    expect(sync.calls, 1);

    first.complete();
    await a;
    second.complete();
    await b;

    expect(sync.calls, 2);
    expect(sync.maxInFlight, 1);
  });

  test('one failed child delete does not keep the others cached', () async {
    storage.ids.addAll({'c1', 'c2', 'c3'});
    storage.failingDeletes.add('c1');

    await provider.refreshAfterSplitChange(
      accessToken: 't',
      accountId: 'acct',
      removedChildIds: const ['c1', 'c2', 'c3'],
    );

    expect(storage.ids, {'c1'});

    // Retried after the next sync once the storage recovers.
    storage.failingDeletes.clear();
    await provider.fetchTransactions(
      accessToken: 't',
      accountId: 'acct',
      forceSync: true,
    );
    expect(storage.ids, isEmpty);
  });

  test('a refresh that could not sync makes the next load sync', () async {
    storage.ids.add('existing'); // non-empty cache: a plain load skips sync
    sync.succeed = false;
    await provider.refreshAfterSplitChange(
      accessToken: 't',
      accountId: 'acct',
      removedChildIds: const ['c1'],
    );
    expect(sync.calls, 1);

    sync.succeed = true;
    await provider.fetchTransactions(accessToken: 't', accountId: 'acct');
    expect(sync.calls, 2);

    // Once it has synced, plain loads go back to the cache.
    await provider.fetchTransactions(accessToken: 't', accountId: 'acct');
    expect(sync.calls, 2);
  });
}
