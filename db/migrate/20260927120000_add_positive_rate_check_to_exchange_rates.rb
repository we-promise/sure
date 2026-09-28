# An exchange rate multiplies an amount into another currency, so a zero,
# negative or NaN rate misstates every balance converted with it: a stored zero
# CHF->CNY rate showed CHF accounts as worth nothing (we-promise/sure#1187).
#
# Such rows are provider glitches, not history worth keeping. Deleting them
# leaves gaps that the next sync refetches (ExchangeRate::Importer only skips a
# pair when every date in the range is present), and lookups fall back to the
# nearest earlier rate in the meantime.
#
# NaN is excluded explicitly because PostgreSQL sorts it above every number, so
# `rate > 0` alone accepts it. Infinity only exists for numeric on PostgreSQL
# 14+, and `rate > 0` accepts it too, so it's excluded via a text comparison
# instead of a numeric 'Infinity' literal: casting to numeric requires 14+,
# but casting to text is safe everywhere, since a rate can only render as the
# string "Infinity" on servers that support storing it in the first place.
class AddPositiveRateCheckToExchangeRates < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DELETE FROM exchange_rates
      WHERE NOT (rate > 0 AND rate <> 'NaN'::numeric AND rate::text <> 'Infinity')
    SQL

    add_check_constraint :exchange_rates,
      "rate > 0 AND rate <> 'NaN'::numeric AND rate::text <> 'Infinity'",
      name: "chk_exchange_rates_rate_positive"
  end

  # The deleted rows were unusable and are not restored.
  def down
    remove_check_constraint :exchange_rates, name: "chk_exchange_rates_rate_positive"
  end
end
