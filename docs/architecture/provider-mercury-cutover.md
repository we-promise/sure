# Mercury preparation and ownership handoff

Status: code and behavioral tests are written, but have not run. Mercury's
`native_ready?` remains false. No database migration, live copy or cutover has
been executed in this workspace.

The shared `MigrationCutover` command now has explicit history contracts for Up,
Mercury and Brex. It uses each provider's existing typed migration manifest to resolve
the exact legacy item. Adding a history contract does not bypass the Registry's
native-readiness gate or turn other adapter definitions into executable cutovers.

`MigrationSourceSelection` supplies the common cash-account preparation step.
It creates missing transactions/balances policies only when one provider link
owns the financial account and there is no direct legacy Plaid/SimpleFIN claim.
Existing explicit policies survive unchanged, including a different balance
source. Several links require explicit choices before financial identity
publication. The original Up selection entry point remains compatible.

Mercury preparation performs the ordinary quiesced copy, original financial
identity publication and logo capture/verification. Final cutover repeats those
proofs while holding the exclusive legacy permit and the original account,
connection, link and financial row locks. It then runs Mercury's own cached-row
and [first-history verifier](mercury-cutover-history.md). A copied transaction ID alone does not establish that
the latest cached financial version was applied.

The verifier's account-specific dates are installed as
`mercury_initial_history_start` only after copy verification. They do not become
completed coverage. Ownership, writer epochs, those dates, the original
preparation receipt and one pending native Sync commit together. Dispatch occurs
after the transaction and permit release; a queue failure retries that exact
Sync. The first Sync has no global date override that could widen its siblings.

The [cutover regression suite](../../test/models/provider/account_data/mercury_migration_cutover_test.rb)
uses the actual old Mercury entry processor, row copier, preparation coordinator,
history verifier and native writer. It covers original financial and proof UUIDs,
post-bootstrap user edits, source selection, the production readiness refusal,
changed copied data, transaction rollback and queue recovery. Up's existing
cutover suite remains the regression coverage for the shared extraction.

This is an explicit operator handoff path behind a disabled readiness gate.
Mercury's complete lifecycle, retained-cache discrepancies, rollback after native
publication and runtime/concurrency acceptance remain rollout requirements. Do
not infer readiness from a completed preparation report or from the existence of
the `provider_data:cutover` task. All authored tests require execution in the
project's Ruby/PostgreSQL environment before activation.
