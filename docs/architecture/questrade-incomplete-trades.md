# Questrade incomplete trade prices

Status: implemented with behavioral tests written but unrun. Questrade remains
disabled for native activation. This handles one partial-response case; it does
not establish complete provider parity or authorize a cutover.

The legacy activity processor rescues individual trade failures. A missing price
fails the Trade presence validation before the associated commission is imported.
The native normalizer retained that missing price, but the shared ledger writer
rejected it inside the transaction for the entire page. One incomplete trade
therefore prevented independent, valid cash activities from being saved.

The [adapter](../../app/models/provider/account_data/questrade.rb) now keeps an
unpriced trade and its commission together in encrypted response evidence and
omits both from the page's financial records. It emits counted `missing_trade_price`
and `unresolved_trade_history` warnings. It does not infer unit price from net cash,
modify an existing trade, or treat the missing row as a deletion.

Valid rows still use the ordinary captured source binding and ledger writer.
The page cursor carries an unresolved flag through all later date windows, so a
successful final HTTP response cannot falsely complete the original history scope.
The first affected page also persists a retry cursor pointing to the original
start and end. Later executions reread that window even if their default initial
history would now start later. Previous completed coverage and its batch reference
remain unchanged. A final unresolved page reports `IncompletePage`, captured by
the shared diagnostics with family, connection and account-provider context.

The same execution replays its captured partial response. A later execution can
fetch a corrected price; only a complete pass clears retry progress and advances
coverage. Trade identity excludes the price and commission fields, preserving the
identifier when the provider supplies the missing price without changing the other
identity fields (including net amount). Previously imported
independent entries keep their UUIDs. Resolving this old window does not claim
coverage through the later execution's current date; a subsequent scan obtains
the intervening history.

No SourceRecord is created for the unpriced trade or its commission until there is
a publishable normalized record. Their full input remains in the retained batch.
Unsupported activity kinds retain their separate evidence-only warning behavior.
Malformed values other than a missing price still fail validation.

The [adapter tests](../../test/models/provider/account_data/questrade_test.rb)
cover partial rows, commission coupling, later windows, cursor validation and
recovery. The [shared-runtime tests](../../test/models/provider/account_data/questrade_incomplete_trades_test.rb)
cover actual financial publication, same-execution replay, durable history retry,
preserved UUIDs/evidence and unchanged previously completed coverage. Ruby and
Bundler are unavailable in this workspace, so these tests have not executed.

[Legacy activity identifier compatibility](questrade-activity-identities.md) now
has implementation and unrun migration tests. Remaining Questrade work includes
identifier ambiguity, cached balance and holding fallbacks, coordination with
every consumer of the rotating grant, history and lifecycle acceptance, and
execution of the complete migration checks.
