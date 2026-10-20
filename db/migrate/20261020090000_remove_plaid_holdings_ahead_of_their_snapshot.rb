# The Plaid holdings processor used to date each row by its own
# `institution_price_as_of`, or today when that was missing or unreadable. It
# now writes every holding of a sync on one snapshot date: the newest price
# date in the payload that is not after today, else today
# (`PlaidAccount#holdings_snapshot_date`).
#
# A row the old processor left later than that date (a holding priced ahead of
# today, or an undated one written on the day of a sync that came after the
# newest price date) stays the account's newest provider date. Every reader of
# current holdings takes the provider rows on that one date, so it would show
# only the stale row, at its old quantity, and hide the whole new snapshot
# until the price dates caught up -- for good, for a row priced far ahead.
# Plaid does not delete holdings at sync (`PlaidAdapter#can_delete_holdings?`
# is false), so nothing else would remove it.
#
# Removed: rows owned by a Plaid account provider and dated after the snapshot
# date of that Plaid account's stored payload. That is exactly the set the
# processor can no longer write and the readers would otherwise pick. Rows of
# other providers, and rows with no provider (calculated or manual), are left
# alone. Running it again removes nothing more.
class RemovePlaidHoldingsAheadOfTheirSnapshot < ActiveRecord::Migration[8.1]
  # The processor's rule, copied rather than called, so the migration keeps
  # meaning what it meant when it was written.
  def self.snapshot_date(payload, today: Date.current)
    holdings = payload.is_a?(Hash) ? Array(payload["holdings"]) : []
    dates = holdings.filter_map do |holding|
      value = holding.is_a?(Hash) ? holding["institution_price_as_of"] : nil
      next if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    dates.reject { |date| date > today }.max || today
  end

  def up
    providers = select_rows(<<~SQL)
      SELECT account_providers.id, plaid_accounts.raw_holdings_payload
      FROM account_providers
      JOIN plaid_accounts ON plaid_accounts.id = account_providers.provider_id
      WHERE account_providers.provider_type = 'PlaidAccount'
    SQL

    providers.each do |account_provider_id, raw_payload|
      payload = raw_payload.is_a?(String) ? JSON.parse(raw_payload) : raw_payload
      cutoff = self.class.snapshot_date(payload)

      execute ActiveRecord::Base.sanitize_sql_array([
        "DELETE FROM holdings WHERE account_provider_id = ? AND date > ?", account_provider_id, cutoff
      ])
    end
  end

  # The removed rows were stale copies of positions the next Plaid sync writes
  # again on its snapshot date. Putting them back would hide that snapshot
  # again, and their old quantities are not kept anywhere to restore.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
