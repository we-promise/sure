# Brex lifecycle admission

The Brex legacy browser commands now participate in migration ownership
admission. This is implemented code with authored, unrun tests; it does not
activate native Brex or implement native account setup or disconnection.

`BrexItem::Lifecycle` resolves the current item and active family administrator
again before mutation. Existing-account linking and disconnection also require
current account ownership or full-control sharing permission. The command locks
financial accounts before the item, actor and source/link rows, using short
`NOWAIT` transactions. Account creation, source publication and links roll back
together when a publication callback fails.

Discovery, linking and setup retain a shared legacy lifecycle permit through the
operation. HTTP runs outside database transactions. Discovery caches are keyed
by the item, family, credentials, endpoint and history configuration; a response
whose original context changed cannot populate the cache or issue a picker.
New-account and existing-account submission fetch a fresh bounded inventory.
Brex setup continues refreshing its source snapshots and preserves its ordinary
per-account validation-failure behavior through individual savepoints. Ownership
and busy denials propagate rather than becoming partial success.

The three picker forms carry an expiring signed `BrexItem::Selection`. Its keyed
fingerprint excludes plaintext credentials, and its original item, family, flow
and optional financial-account target are checked before transport and again at
publication. The lifecycle methods enforce the flow and target themselves;
decoding a valid selection for one command does not authorize another command.
The existing account-type and subtype validation remains in the form flow.

Credential/settings changes and destructive disconnect use an exclusive legacy
permit. Disconnect validates the original complete source/link inventory before
one atomic detach. It refuses copied dual links and any retained source policy,
which need their own retention-aware disposition. It preserves financial entries
and balances and detaches only holdings belonging to the selected financial
accounts. Deletion is marked in the same transaction; `DestroyJob` is dispatched
after commit and after the exclusive permit is released. Direct `destroy_later`
also rechecks the original legacy owner and refuses still-linked accounts.
This introduces no durable deletion-job recovery protocol.

`BrexItem::SyncRequest` captures the ownership route once and checks it again
under admission. A legacy owner queues its original item; an active or retired
native owner requires the exact family/provider/control/connection mapping and
queues that connection. Transitional, missing or changed routes refuse instead
of falling back to another writer. Native edit links lead to the shared native
configuration route, and settings-panel refreshes exclude native-owned legacy
forms. Old settings, linking, setup and deletion submissions cannot mutate the
retired legacy item.

Focused tests cover actual session permits, credential changes during discovery,
stale and cross-target selections, permission revocation, callback rollback,
retained-policy refusal, deletion dispatch after permit release and native/legacy
manual-sync routing. Existing transactional controller/flow tests replace only
the physical permit and their fake transport admission; the new lifecycle and
sync-request suites use real commits. Ruby is unavailable in the authoring
environment, so none of these tests or runtime cutover checks have run.

See [Brex direct publication and retained history](brex-cutover-history.md) and
[Brex cutover](provider-brex-cutover.md) for the separate publication, history and
activation boundaries.
