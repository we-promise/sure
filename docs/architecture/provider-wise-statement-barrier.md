# Wise profile statement barrier

`Wise::StatementBarrier` is implemented in the shared Syncer path, before account
streams and only after complete discovery. Wise remains disabled for native
activation. The code and behavioral tests have not been executed in this
environment.

The legacy importer authorizes transfer fallback only when every attempted
STANDARD balance statement fails. A successful empty response vetoes fallback.
The native barrier captures the first requested statement window for every active
STANDARD balance in the profile, including unlinked balances. Any successful
probe, even empty or entirely suppressed by retained overlap policy, vetoes
fallback for the whole logical Sync. SAVINGS/JAR balances do not count as
statement attempts.

Only explicit `access_forbidden` and `not_found` responses count as eligible
denials. Authentication, rate-limit, transport and malformed-response failures
stop the barrier without authorizing fallback. Earlier successful captures remain
available. This is deliberately more conservative than the legacy broad rescue:
a later-window failure can never reverse an observed successful first window.
No incomplete or unprobed inventory can authorize fallback.

Before statement HTTP, the runtime atomically stores an encrypted, typed connection
manifest and a routed manifest batch for every original external account. The
manifest pins the logical Sync, profile, inventory, canonical account records,
original windows/configuration/checkpoints, publication bindings and request
grant. Routed batches retain the original financial UUID, AccountProvider and
selected policy through the existing `source_binding`; unlinked accounts retain
explicit unbound ownership. These and the subsequent probe batches use separate
Wise scopes in the transactions stream. They remain captured, do not enter the
writer, and never become transaction checkpoints.

The barrier revalidates the original request grant, complete inventory, current
account/link/policy bindings and window configuration on continuation. Only
checkpoint changes produced by applied account batches of the same Sync are
accepted. The adapter consumes the exact staged successful response, so ordinary
account ingestion does not repeat the first statement request. Denied accounts
continue to transfers only after all probes deny access and their frozen retained
policy does not already establish statement history. A denied account without
that authority reports an incomplete stream; successful siblings can publish.

Fallback pages explicitly report `history_complete: false` and do not claim
pending-absence authority. Even after transfers and activities finish, the shared
checkpoint retains its prior `covered_through`. For an initial fallback with no
prior boundary, its original coverage start remains the next Sync's default
statement start instead of aging forward with the 365-day window. Explicit user
start-date selections still take precedence. This preserves a retry boundary;
transfer fallback does not prove full statement coverage.

Work is bounded to 100 external accounts, 16 new probes per invocation, 4 MiB of
decoded typed payload per batch and 32 MiB of cumulative reads/captures. Stored
encrypted byte sizes are checked before payload materialization. Reaching the
request budget raises `DeferredPage`, which the actual job schedules against the
same Sync. Other failures retain captured proof but follow the existing job error
semantics: ordinary transport failures terminalize the Sync. Direct Syncer replay
coverage establishes protocol reuse, not automatic retry of a terminal failed
job. No new retry/reset/abandonment command is introduced here.

The existing [statement-history promotion](provider-wise-retained-history.md)
still occurs only when the ordinary writer commits a real authoritative statement
posting. Probe capture cannot promote it. Same-Sync replay keeps the original
factory clock and policy even after a sibling posts a statement. Captures must
remain retained; administrative removal is not a supported authorization reset.

Tests exercise real Registry/Syncer construction, successful-empty and unlinked
vetoes, all-denied fallback, preserved coverage/start boundaries, same-Sync replay
after publication, current input drift, malformed/missing captures, bounded job
continuation and provider I/O outside transactions. The admitted inventory also
supports [confirmed interbalance finalization](provider-wise-interbalance-transfers.md)
after account publication. Coverage acceptance, unapplied legacy-cache and
ambiguous topology disposition, lifecycle/cutover and an explicit promotion reset
remain separate activation requirements.
