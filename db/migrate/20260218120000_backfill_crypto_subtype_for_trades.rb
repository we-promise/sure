# frozen_string_literal: true

class BackfillCryptoSubtypeForTrades < ActiveRecord::Migration[7.2]
  def up
    # Crypto accounts created via the UI before the controller permitted :subtype
    # had subtype NULL, so supports_trades? was false and the Trades API returned 422.
    # Backfill to "exchange" only for manual (unlinked) crypto accounts so they can use
    # the Trades API. Skip accounts linked to a provider (e.g. CoinStats wallet) which
    # intentionally leave subtype NULL and must remain wallet/sync-only.
    # Uses raw SQL to avoid coupling to the Crypto model (see Rails migration guidelines).
    say_with_time "Backfilling crypto subtype for manual accounts only" do
      execute <<-SQL.squish
        UPDATE cryptos
        SET subtype = 'exchange'
        WHERE subtype IS NULL
          AND id IN (
            SELECT a.accountable_id
            FROM accounts a
            WHERE a.accountable_type = 'Crypto'
              AND NOT EXISTS (SELECT 1 FROM account_providers ap WHERE ap.account_id = a.id)
          )
      SQL
    end
  end

  def down
    # No-op: we cannot distinguish backfilled records from user-chosen "exchange",
    # so reverting would incorrectly clear legitimately set subtypes.
  end
end
