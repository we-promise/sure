# Questrade activity identifier compatibility

Status: implemented with tests authored but unrun. Questrade remains gated for
native activation; no migration or cutover has been executed.

Questrade's legacy activities have no upstream transaction ID. The legacy
[activity processor](../../app/models/questrade_account/activities_processor.rb)
hashes the joined transaction timestamp, action, symbol ID, quantity, net amount
and description, then prefixes that digest for trades, commissions, cash or
journals. Its JSON reader decodes decimal numbers as Ruby Float values. The native
reader uses BigDecimal to preserve monetary precision.

Formatting those exact decimals with `to_s("F")` changed some digests: small
quantities use scientific notation in the legacy Float representation, and longer
decimal values had been rounded by the old parser. A fresh native observation could
therefore create a second posting instead of selecting the original financial UUID.

The [normalizer](../../app/models/provider/account_data/questrade/activity_normalization.rb)
now reproduces the legacy number formatting **only while computing an identifier**.
Native decimal JSON values use the equivalent finite Float string for that hash.
Integer and string inputs retain their own original representations. Native Float
monetary inputs remain invalid; quantities, prices, amounts and fees still come
from the exact BigDecimal inputs, without a Float arithmetic step. Overflow and
nonzero underflow in the identifier representation refuse normalization.

Existing legacy typed inputs are hashed before monetary conversion, using their
original Ruby representation. The copied archives are unchanged. Native publication
then uses the ordinary signed bootstrap mapping and shared source-authority checks;
it does not need a second alias table or a financial match by amount and date.
Entry and entryable UUIDs, existing external IDs and original identity evidence
remain in place, and normal protection of user-edited fields continues to apply.

This preserves the existing identifier convention, including its limitations.
Changing any hashed field or its JSON type can still change the identifier.
When colliding legacy identifiers produce different normalized records in one
page, the existing page collision check refuses them. It cannot distinguish
separate events that normalize identically, or prove identity across separate
pages solely from this hash. Historical Float caches cannot recover precision
that the old parser already discarded. Broader ambiguity and history acceptance
remain migration requirements.

[Normalizer tests](../../test/models/provider/account_data/questrade_test.rb)
compare the old and exact JSON readers across small quantities, long decimals,
integer/string distinctions, bounds and collisions. The
[migration regression tests](../../test/models/provider/account_data/questrade_legacy_identities_test.rb)
run the actual legacy activity processor, quiesced row copier, signed identity
bootstrap and native writer, covering trades, commissions, cash, journals, replay
and subsequent user edits. Ruby/Bundler are unavailable here, so neither suite
has been executed.
