# Prices the importer carried forward before carried_forward existed are
# stored false. The ones that can be proven are the provisional rows: the
# importer marks a row provisional only when it carried the price forward.
# Older carried rows cannot be told from a quote that did not move (a pegged
# fund, a crypto weekend, a no-trade day), so they are left as they are;
# clear_cache rebuilds a security's prices.
#
# Batched outside a transaction so a large table is not locked in one
# statement. Rows already marked are skipped, so it can run more than once.
# The outer update repeats the predicate so a row a refresh made real after
# the subquery read it is skipped.
class BackfillCarriedForwardOnSecurityPrices < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    loop do
      updated = exec_update(<<~SQL)
        UPDATE security_prices
        SET carried_forward = true
        WHERE id IN (
          SELECT id FROM security_prices
          WHERE provisional = true AND carried_forward = false
          LIMIT #{batch_size}
        )
        AND provisional = true AND carried_forward = false
      SQL
      break if updated.zero?
    end
  end

  # The column itself is removed by rolling back the migration that added it.
  def down
  end

  private
    def batch_size
      10_000
    end
end
