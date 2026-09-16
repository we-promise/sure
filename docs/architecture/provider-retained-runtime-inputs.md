# Retained inputs for native provider construction

The shared `RetainedRow` reader and registered runtime collectors now connect verified
migration archives to native adapter construction. Code and behavioral tests are
written; tests have not run. This is input transfer, not provider activation or
proof of complete upstream history.

## Admission and bounded reads

[`RetainedRow`](../../app/models/provider/account_data/retained_row.rb) accepts a
verified quiesced copy with its original copy-run UUID, manifest version, fenced
verification audit and verified source mappings. Ordinary shadow copies cannot
seed runtime history. A genuinely new connection has an explicit absent input;
a copied connection with missing evidence raises instead of becoming empty history.

The reader verifies typed archive checksums, source identity, table, declared
columns and family/parent ownership. Reads are limited to 32 MiB and 1,024 chunks
per row. Results and provenance are immutable. Account collectors additionally
check the original copied account binding and current financial identity; the
reader alone does not authorize applying a retained row to a financial account.

[`RuntimeContext`](../../app/models/provider/account_data/runtime_context.rb)
registers reviewed collector classes explicitly. Each collector declares a frozen
factory input. The full input joins the existing capture fingerprint; compact
source descriptors join the live request fingerprint. This lets request and
publication checks detect changed mappings, configuration or account binding
without decrypting all historical payloads before every HTTP request. Normal
native checkpoint progress does not replace or mutate the migration evidence.

## Implemented consumers

| Consumer | Retained input | Bounds and remaining work |
| --- | --- | --- |
| [Trading 212 instrument catalog](../../app/models/provider/account_data/trading212/instrument_catalog.rb) | The item archive's instrument list, including explicit absent versus retained-empty states. The factory supplies cached names when fresh catalog retrieval fails. A successful fresh response replaces only the adapter's in-memory catalog. | At most 100,000 distinct ticker identities plus the archive byte bound; malformed identities fail. Persisting a later fresh fallback catalog, financial/history parity and activation remain separate. |
| [Wise account history](provider-wise-retained-history.md) | Provable legacy-transfer cutoff and history flags, with source profile and original account binding. Applied native statement postings can promote a later factory's frozen history policy. | At most 500 accounts, 32 MiB cumulative archives and 50,000 raw rows. Runtime acceptance, profile-wide fallback authorization, explicit promotion reset and transfer linking remain gates. |
| [Monobank history](monobank-retained-history.md) | Exact copied boundary columns and oldest retained hold, keyed by ExternalAccount UUID, namespace and original account binding. | At most 1,000 accounts, 32 MiB cumulative archives and 100,000 rows per account. Expiry policy, full history/lifecycle acceptance and cutover remain gates. |
| [Trade Republic portfolio](trade-republic-native-port.md) | Exact archived remote-account ownership routes discovery and timeline fanout to the copied `portfolio`/`cash` identities. Prior quotes retain their original observation time and archive provenance. | At most 1,000 accounts, 32 MiB cumulative archives and 10,000 ISIN quote identities. Timeline-cache processing, financial relocation, complete holdings and lifecycle acceptance remain gates. |
| [SimpleFIN classifier hint](simplefin-retained-classifier-hint.md) | A typed cache observation captured into the quiesced account archive, including original expiry or explicit absence. The classifier snapshot consumes it only when native encrypted state is absent. | A 4 KiB hint per account and 1,000-account inventory bound. Older archives need reconciliation; cache absence only describes capture time. Native hint expiry and financial-account binding remain authoritative. |
| [Plaid deployment binding](provider-plaid-deployment-binding.md) | The quiesced item's region, environment, copy-run identity and keyed fingerprints of its token/application. Same-run retries reuse the original document. Factory capture verifies archive provenance; live request checks pin the current application and projected binding. | A 4 KiB document with no plaintext application secrets. Older unbound copies require explicit reconciliation. Binding tests remain unrun; upstream token validity, cached-change dispositions and cursor acceptance are separate gates. |

Trading 212 tests exercise actual registry construction and request capture, failed
and successful catalog refreshes, explicit absence, malformed catalogs and source
drift. Shared reader tests cover ownership, quiesced-only admission, immutable
archives, descriptor-only checks, missing mappings and corrupt/oversized archives.
Wise and Monobank have separate collector, request and replay regressions. Plaid
adds repeated item-copy, shadow-to-quiesced transition, archive binding and
configuration-drift regressions. Its loaded legacy SDK configuration is checked
during copying and preactivation verification; native requests use the pinned
current application without depending on a retired legacy SDK object.

The collectors preserve original archives and financial UUIDs. They do not create
native coverage from `last_synced_at`, call legacy processors, select a posting
source or bypass credential/source-policy admission. See the full
[input inventory](provider-native-input-audit.md) and
[implementation status](provider-implementation-status.md) for remaining work.
