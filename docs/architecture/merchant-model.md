# Merchant model

## Design decision: one merchant type

Supporting two merchant types has added branching across provider sync, transaction assignment, settings, recurring transactions, and import/export. This change deliberately simplifies that structure: every merchant the UI presents or persists is a family merchant, whether a family member created it or a provider first supplied its details. There is no separate Provider Merchant segment in the UI or a separate provider-merchant record type in the resulting data model.

During provider sync, provider merchant data may be an intermediate input while Sure looks up or creates the matching family merchant. That intermediate provider data is not a lasting merchant record: once the family merchant is found or created and transaction references are handed off, the old provider merchant is deleted to finish the consolidation.

Provider imports reuse a merchant when the family's merchant has the same name and website. Otherwise, they create a family merchant with the available name, website, and logo. Provider IDs are no longer stored as a separate merchant identity. Older Sure exports that contain `ProviderMerchant` rows remain importable; those legacy rows are mapped into the family's merchant collection and are not recreated as provider merchant records.

Existing shared provider merchants are migrated once per family that references them through a transaction, recurring transaction, or prior family assignment. Matching family merchants are reused, references are reassigned, and the old shared rows and family-assignment table are removed.

## Maintainer review before merge

This is a cross-cutting simplification motivated by the complexity of supporting two merchant ownership types across sync, assignment, settings, recurring transactions, and import/export. Before merging, a maintainer with experience in how merchants currently work in Sure must review the migration and provider-sync behavior, especially how existing family edits and unlink/reassignment behavior carry forward. This pass should confirm that the temporary provider-to-family handoff preserves expected transaction associations and that no lasting Provider Merchant segment remains in the UI or data model.
