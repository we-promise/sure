# Gems and Bullion

Gems and Bullion is a manual asset accountable for physical items. It is kept
separate from `Investment`: it has no securities, holdings, trades, or account
statements. Receipts and invoices are purchase proof and remain attached to the
individual item; exports intentionally exclude attachment payloads.

Each item has a category and a material. Bullion supports gold (`XAU`), silver
(`XAG`), platinum (`XPT`), and palladium (`XPD`), with weight and percentage
purity. Current values use the matching spot-price API quote unless the item
has a manual value. Gemstones and stones support diamond, ruby, sapphire,
emerald, and other; they use carats and require a manual or appraised value.

The account currency is fixed once items exist. The account balance is the sum
of item values, and a refresh records the value through Sure's reconciliation
history. Provider calls occur outside account locks; daily quotes are cached by
material symbol and account currency in `exchange_rates`.

The internal accountable model is `Valuable`; user-facing labels always say
“Gems and Bullion”. The forward migration renames the original unmerged
physical-gold tables and transforms its karat values into percentage purity.
